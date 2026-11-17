#!/usr/bin/env python3
"""Daily backup status email for leslie-fileserver.

Runs by itself from cron, so it still reports when daily.sh did not run.
It only reads: it never starts, stops or changes a backup or a container.

Usage:
    backup_status_email.py            send the email
    backup_status_email.py --print    print the report, send nothing
    backup_status_email.py --after-run [--trigger scheduled|manual]
                                      called by daily.sh when it ends: report the
                                      run that just finished (not "still running")

Settings come from .env.mail in the same folder (mode 600):
    MAIL_USER=<gmail address that sends the mail>
    MAIL_APP_PASSWORD=<16 character Google app password>
    MAIL_TO=lesliecaminade@gmail.com
"""
import json
import os
import re
import shutil
import smtplib
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from email.message import EmailMessage

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = "/home/leslie/.local/log"
DAILY_LOG = os.path.join(LOG_DIR, "daily_backup.log")
B2_LAST = os.path.join(LOG_DIR, "backup_to_backblaze.last")
LAPTOP_LAST = os.path.join(LOG_DIR, "backup_to_laptop.last")
STATE_FILE = os.path.join(LOG_DIR, "daily_backup.containers")
B2_REPO = "b2:Homelab2002349994:fileserver"
SNAPRAID_CONTENT = "/home/leslie/snapraid/snapraid.content"
DISKS = ["/mnt/hdd-stripe", "/mnt/hdd-red", "/mnt/hdd-black", "/mnt/ssd-black", "/mnt/hdd-grooved", "/"]
IMMICH_PING = "http://localhost:2283/api/server/ping"
H = 3600

OK, WARN, FAIL = 0, 1, 2
LABEL = {OK: "OK", WARN: "WARNING", FAIL: "FAILED"}
findings = []  # (level, text)
sections = []  # (title, [lines])


IN_PROGRESS = False
AFTER_RUN = "--after-run" in sys.argv
TRIGGER = sys.argv[sys.argv.index("--trigger") + 1] if "--trigger" in sys.argv else ""


def add(level, text, soft=False):
    """soft=True: a problem that is normal while daily.sh runs (containers stopped)."""
    if soft and IN_PROGRESS:
        findings.append((OK, "[while daily.sh runs] " + text))
    else:
        findings.append((level, text))


def age_text(seconds):
    if seconds < 0:
        seconds = 0
    if seconds < 90 * 60:
        return f"{int(seconds // 60)} minutes ago"
    if seconds < 48 * H:
        return f"{seconds / H:.1f} hours ago"
    return f"{seconds / 86400:.1f} days ago"


def run(cmd, timeout=120, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except FileNotFoundError:
        return 127, "command not found"


def load_env(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:]
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


# Failure details ---------------------------------------------------------
RUN_OUT_FILE = os.path.join(LOG_DIR, "daily_backup_last_run.out")
CRON_LOG = "/var/log/daily_backup.log"
NOISE = re.compile(r"stripe/s|MB/s|^\s*\d+%, \d+ MB|wait time|^\s*\|_+|^\s*(d\d+|parity|raid|hash|sched|misc)\s+\d+%\s*\||^\s*$")


def clean_output(text):
    out = []
    for l in text.replace("\r", "\n").splitlines():
        if not NOISE.search(l):
            out.append(l.rstrip()[:300])
    return out


def failure_details(max_lines=30):
    """The output of the last run up to and just after its first failure."""
    lines = None
    try:
        with open(RUN_OUT_FILE, errors="replace") as f:
            lines = clean_output(f.read())
        source = RUN_OUT_FILE
    except OSError:
        pass
    if lines is None:  # older runs: stdout-only cron log
        try:
            with open(CRON_LOG, errors="replace") as f:
                text = f.read()
            i = text.rfind("Daily backup script started")
            lines = clean_output(text[i:] if i >= 0 else text[-200000:])
            source = CRON_LOG + " (stdout only: error messages from stderr were not kept)"
        except OSError:
            return []
    bad = re.compile(r"ERROR|failed with exit code|failed at|stopped after|soft errors|io errors|data errors")
    idx = [i for i, l in enumerate(lines) if bad.search(l) and not re.search(r"\b0 (io|data|soft) errors", l)]
    if not idx:
        return []
    first = idx[0]
    chunk = lines[max(0, first - max_lines):first + 6]
    return [f"Source: {source}", ""] + chunk


# 1. The last daily run ---------------------------------------------------
def check_daily():
    global IN_PROGRESS
    rc, _ = run(["pgrep", "-f", "bash.*daily.sh"], timeout=10)
    IN_PROGRESS = rc == 0 and not AFTER_RUN  # daily.sh itself is still alive when it calls us
    lines = []
    try:
        with open(DAILY_LOG, errors="replace") as f:
            log = f.read().splitlines()
    except OSError:
        add(FAIL, f"Cannot read the daily log {DAILY_LOG}.")
        sections.append(("Daily backup run", ["No log file."]))
        return
    ts = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$")
    starts = [i for i, l in enumerate(log) if "Daily backup script started" in l]
    if not starts:
        add(FAIL, "The daily log has no run.")
        sections.append(("Daily backup run", ["No run in the log."]))
        return
    run_lines = log[starts[-1]:]
    m = ts.match(run_lines[0])
    started = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") if m else None
    age = (datetime.now() - started).total_seconds() if started else 10**9
    lines.append(f"Last start: {started} ({age_text(age)})")
    finished = [l for l in run_lines if "Daily backup script finished" in l]
    errors = [l for l in run_lines if "ERROR" in l or "failed with exit code" in l]
    if finished:
        lines.append("Result: finished")
    elif errors:
        lines.append("Result: stopped with an error")
    elif age < 3 * H:
        lines.append("Result: still running")
    else:
        lines.append("Result: no finish line (the run was cut off)")
    for l in errors[-5:]:
        lines.append("  " + l[:200])
    for name in ("Laptop backup", "Backblaze backup"):
        done = [l for l in run_lines if f"Finished: {name}" in l]
        bad = [l for l in run_lines if name in l and ("failed" in l or "stopped after" in l)]
        lines.append(f"{name}: " + ("ok" if done else ("FAILED" if bad else "not run")))
    if IN_PROGRESS:
        lines.append("daily.sh is running now. Container and SnapRAID problems are normal until it ends.")
    sections.append(("Daily backup run", lines))
    if errors or any("FAILED" in l for l in lines):
        det = failure_details()
        if det:
            sections.append(("Failure details (output before the first error)", det))
    if age > 36 * H and not IN_PROGRESS:
        add(FAIL, f"The daily run last started {age_text(age)}. It should run every day.")
    elif errors and not finished:
        add(FAIL, "The last daily run stopped with an error: " + errors[-1][20:160])
    elif not finished and age >= 3 * H:
        add(FAIL, "The last daily run has no finish line.")
    if errors and finished:
        add(WARN, "The last daily run finished, but a step reported an error.")
    soft = [l for l in run_lines if "WARNING: snapraid" in l and "soft errors" in l]
    for l in soft:
        add(WARN, "SnapRAID: " + l[20:].split(" after ")[0] + " (backups still ran).")


# 2. Backup freshness -----------------------------------------------------
def check_freshness():
    lines = []
    for name, path, fail_h in (("Backblaze (cloud)", B2_LAST, 48), ("Laptop copy", LAPTOP_LAST, 72)):
        try:
            age = time.time() - os.stat(path).st_mtime
        except OSError:
            lines.append(f"{name}: no success marker found")
            add(FAIL if "Backblaze" in name else WARN, f"{name}: no record of a successful backup.")
            continue
        lines.append(f"{name}: last success {age_text(age)}")
        if age > fail_h * H:
            add(FAIL if "Backblaze" in name else WARN, f"{name}: last success was {age_text(age)}.")
    # Check the cloud repository directly (read only).
    env = os.environ.copy()
    env.update(load_env(os.path.join(BASE, ".env.b2")))
    rc, out = run(["restic", "-r", B2_REPO, "snapshots", "--latest", "1", "--json"], timeout=180, env=env)
    if rc == 0:
        try:
            snaps = json.loads(out)
            if snaps:
                t = snaps[-1]["time"][:19]
                snap_age = time.time() - datetime.strptime(t, "%Y-%m-%dT%H:%M:%S").timestamp()
                lines.append(f"Newest snapshot in Backblaze: {t} (about {age_text(snap_age)})")
                if snap_age > 72 * H:
                    add(FAIL, f"The newest cloud snapshot is {age_text(snap_age)}.")
            else:
                lines.append("Backblaze repository has no snapshots")
                add(FAIL, "The Backblaze repository has no snapshots.")
        except (ValueError, KeyError, IndexError):
            lines.append("Could not read the restic answer")
            add(WARN, "Could not read the restic snapshot list.")
    else:
        lines.append("Could not read the Backblaze repository: " + out.strip()[:150])
        add(WARN, "Could not read the Backblaze repository (network or key problem).")
    sections.append(("Backup freshness", lines))


# 2c. Google Drive backup (gdrive-backup.sh, monthly from leslie's crontab) --
GDRIVE_LOG_DIR = "/mnt/hdd-stripe/backups/google-drive/logs"


def gdrive_latest_log():
    try:
        logs = sorted(f for f in os.listdir(GDRIVE_LOG_DIR) if f.startswith("backup_") and f.endswith(".log"))
    except OSError:
        return None
    return os.path.join(GDRIVE_LOG_DIR, logs[-1]) if logs else None


def check_gdrive():
    lines = []
    path = gdrive_latest_log()
    if not path:
        lines.append(f"No log found in {GDRIVE_LOG_DIR}")
        add(FAIL, "Google Drive backup: no run found.")
        sections.append(("Google Drive backup", lines))
        return
    with open(path, errors="replace") as f:
        log = f.read().splitlines()
    age = time.time() - os.stat(path).st_mtime
    ok = [l for l in log if "] OK " in l]
    bad = [l for l in log if "] FAILED " in l]
    lines.append(f"Last run: {os.path.basename(path)[7:-4]} (log updated {age_text(age)})")
    for l in ok:
        lines.append("  OK: " + l.split("] OK ", 1)[1])
    for l in bad:
        lines.append("  FAILED: " + l.split("] FAILED ", 1)[1].split(" (see", 1)[0])
    if not ok and not bad:
        lines.append("  No result line: the run is still going or was cut off")
    if bad:
        add(FAIL, "Google Drive backup: the last run failed.")
    elif not ok and age > 6 * H:
        add(FAIL, "Google Drive backup: the last run has no result line.")
    if age > 40 * 24 * H:
        add(FAIL, f"Google Drive backup: last run was {age_text(age)} (it runs monthly).")
    elif age > 32 * 24 * H:
        add(WARN, f"Google Drive backup: last run was {age_text(age)} (it runs monthly).")
    sections.append(("Google Drive backup", lines))


# Root cause --------------------------------------------------------------
# Each rule: pattern that proves the cause, plain explanation, what to do,
# and a pattern for the evidence lines to quote.
CAUSES = [
    (r"\b([1-9]\d*) soft errors",
     "SnapRAID hit {0} soft error(s): files on the data disks were changed, moved or deleted "
     "while SnapRAID was reading them, or could not be opened. This is NOT disk damage and NOT "
     "something SnapRAID repairs. Something wrote to the data disks during the sync (a service "
     "that daily.sh does not stop, or another backup writing to the array).",
     "Find what writes to the files listed below and stop it during the sync (or exclude that "
     "folder in /etc/snapraid.conf), so the next sync covers them. The backups are not blocked by soft errors.",
     r"(?i)missing|changed|error (opening|reading|accessing)|unexpected|permission denied|warning"),
    (r"\b([1-9]\d*) io errors",
     "SnapRAID hit {0} I/O error(s): a disk failed to read or write. A disk may be failing.",
     "Check the disk with 'smartctl -a' before the next sync.",
     r"(?i)error|disk|/dev/"),
    (r"\b([1-9]\d*) data errors",
     "SnapRAID found {0} data error(s): silent corruption. This IS what SnapRAID repairs.",
     "Run 'snapraid -e fix', then 'snapraid -p new scrub'.",
     r"(?i)error|block|file"),
    (r"(?i)repository is already locked",
     "A restic repository was locked by another restic process (or a stale lock).",
     "Check 'restic list locks'; if the owner is gone, run 'restic unlock'.",
     r"(?i)lock"),
    (r"stopped after the time limit",
     "A backup step was stopped because it ran longer than its time limit.",
     "Check the network or the repository size; raise BACKUP_TIMEOUT if needed.",
     r"time limit"),
    (r"(?i)no space left on device",
     "A disk is full.",
     "Free space on the disk named below.",
     r"(?i)no space"),
    (r"(?i)host key verification failed|connection refused|no route to host|connection timed out|could not resolve",
     "A backup target could not be reached over the network.",
     "Check that the target machine is on and reachable over Tailscale/SSH.",
     r"(?i)host key|refused|no route|timed out|resolve|ssh|sftp"),
    (r"(?i)\b(401|403)\b|unauthorized|invalid (key|credentials)|access denied",
     "A storage service refused the credentials.",
     "Check the keys in .env.b2 (Backblaze) or the rclone login (Google Drive).",
     r"(?i)401|403|unauthori|denied|credential|key"),
]


def root_causes():
    """Explain why the last run failed, from the run output and the Drive log."""
    texts = []
    try:
        with open(RUN_OUT_FILE, errors="replace") as f:
            texts.append(("daily.sh run", clean_output(f.read())))
    except OSError:
        try:
            with open(CRON_LOG, errors="replace") as f:
                t = f.read()
            i = t.rfind("Daily backup script started")
            texts.append(("daily.sh run (stdout only)", clean_output(t[i:] if i >= 0 else t[-200000:])))
        except OSError:
            pass
    g = gdrive_latest_log()
    if g:
        with open(g, errors="replace") as f:
            glines = f.read().splitlines()
        if any("] FAILED " in l for l in glines):
            texts.append(("Google Drive backup", [l for l in glines if " ERROR " in l or "FAILED" in l]))
    out = []
    for source, lines in texts:
        joined = "\n".join(lines)
        for cause, explain, todo, ev in CAUSES:
            m = re.search(cause, joined)
            if not m:
                continue
            out.append(f"* {source}: " + explain.format(*(m.groups() or ("",))))
            out.append(f"  What to do: {todo}")
            evidence = [l for l in lines if re.search(ev, l) and not re.search(r"\b0 (io|data|soft) errors", l)]
            if evidence:
                out.append("  Evidence:")
                out += ["    " + l[:250] for l in evidence[-15:]]
            out.append("")
    return out


# 3. SnapRAID -------------------------------------------------------------
def check_snapraid():
    lines = []
    try:
        age = time.time() - os.stat(SNAPRAID_CONTENT).st_mtime
        lines.append(f"Last sync: {age_text(age)}")
        if age > 5 * 86400:
            add(WARN, f"SnapRAID last synced {age_text(age)}.")
    except OSError:
        lines.append("Content file not found")
        add(WARN, "SnapRAID content file not found.")
    if IN_PROGRESS:
        lines.append("Status skipped: SnapRAID is in use by daily.sh")
        sections.append(("SnapRAID", lines))
        return
    rc, out = run(["snapraid", "status"], timeout=600)
    m = re.search(r"oldest block was scrubbed (\d+) days ago", out)
    if m:
        lines.append(f"Oldest scrubbed block: {m.group(1)} days ago")
        if int(m.group(1)) > 120:
            add(WARN, f"SnapRAID scrub is old: {m.group(1)} days.")
    if "No error detected" in out:
        lines.append("Errors: none")
    elif rc == 0 and out:
        lines.append("Errors: see `snapraid status`")
        add(WARN, "SnapRAID status does not say 'No error detected'.")
    else:
        lines.append("snapraid status failed: " + out.strip()[:120])
        add(WARN, "`snapraid status` failed.")
    sections.append(("SnapRAID", lines))


# 4. Containers and Immich ---------------------------------------------------
def check_containers():
    lines = []
    rc, out = run(["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}"], timeout=60)
    if rc != 0:
        lines.append("docker ps failed: " + out.strip()[:120])
        add(FAIL, "Cannot read the Docker container list.")
        sections.append(("Containers", lines))
        return
    down = []
    total = 0
    for row in out.strip().splitlines():
        name, _, status = row.partition("|")
        total += 1
        if not status.startswith("Up"):
            down.append(f"{name} ({status})")
    lines.append(f"{total - len(down)} of {total} containers are running")
    for d in down:
        lines.append("  Not running: " + d)
    if down:
        add(FAIL, f"{len(down)} container(s) not running: " + ", ".join(d.split(" ")[0] for d in down), soft=True)
    if os.path.exists(STATE_FILE):
        try:
            left = open(STATE_FILE).read().split()
        except OSError:
            left = []
        if left:
            lines.append("Saved list of stopped containers: " + " ".join(left))
    try:
        with urllib.request.urlopen(IMMICH_PING, timeout=10) as r:
            body = r.read().decode()[:60]
        lines.append("Immich answers: " + body.strip())
    except Exception as e:  # noqa: BLE001
        lines.append(f"Immich does not answer: {e}")
        add(FAIL, "Immich does not answer on port 2283.", soft=True)
    sections.append(("Containers and Immich", lines))


# 5. Disk space -------------------------------------------------------------
def check_disks():
    lines = []
    for d in DISKS:
        if not os.path.ismount(d):
            lines.append(f"{d}: not mounted")
            add(FAIL, f"{d} is not mounted.")
            continue
        u = shutil.disk_usage(d)
        pct = u.used / u.total * 100
        lines.append(f"{d}: {pct:.0f}% used, {u.free / 1e9:.0f} GB free")
        if pct >= 97:
            add(FAIL, f"{d} is {pct:.0f}% full.")
        elif pct >= 90:
            add(WARN, f"{d} is {pct:.0f}% full.")
    sections.append(("Disk space", lines))


def build():
    for fn in (check_daily, check_freshness, check_gdrive, check_snapraid, check_containers, check_disks):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            add(WARN, f"The check {fn.__name__} crashed: {e}")
    worst = max([lvl for lvl, _ in findings], default=OK)
    host = socket.gethostname()
    status = "RUNNING" if IN_PROGRESS and worst == OK else LABEL[worst]
    subject = f"[Backup {status}] {host} {datetime.now():%Y-%m-%d}" + (f" ({TRIGGER})" if TRIGGER else "")
    body = [f"Backup status for {host}", f"Report time: {datetime.now():%Y-%m-%d %H:%M}", f"Overall: {status}", ""]
    if findings:
        body.append("Problems:")
        for lvl, text in sorted(findings, key=lambda x: -x[0]):
            body.append(f"  [{LABEL[lvl]}] {text}")
    else:
        body.append("No problems found.")
    if worst > OK:
        try:
            rc_lines = root_causes()
        except Exception as e:  # noqa: BLE001
            rc_lines = [f"Could not work out the root cause: {e}"]
        body += ["", "Root cause", "----------"]
        body += rc_lines or ["No known cause matched. See 'Failure details' below for the raw output."]
    for title, lines in sections:
        body += ["", title, "-" * len(title)] + lines
    return subject, "\n".join(body) + "\n"


def send(subject, body):
    cfg = load_env(os.path.join(BASE, ".env.mail"))
    user, pw, to = cfg.get("MAIL_USER"), cfg.get("MAIL_APP_PASSWORD"), cfg.get("MAIL_TO", "lesliecaminade@gmail.com")
    if not user or not pw:
        print("Missing MAIL_USER or MAIL_APP_PASSWORD in .env.mail", file=sys.stderr)
        return 2
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = user, to, subject
    msg.set_content(body)
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=60) as s:
        s.login(user, pw.replace(" ", ""))
        s.send_message(msg)
    return 0


if __name__ == "__main__":
    subject, body = build()
    if "--print" in sys.argv:
        print("Subject:", subject, "\n")
        print(body)
        sys.exit(0)
    try:
        sys.exit(send(subject, body))
    except Exception as e:  # noqa: BLE001
        with open(os.path.join(LOG_DIR, "backup_status_email.log"), "a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} send failed: {e}\n")
        print("send failed:", e, file=sys.stderr)
        sys.exit(1)
