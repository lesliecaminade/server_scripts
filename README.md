# Server Scripts

A collection of automation and maintenance scripts for the homelab server.

## Repository Layout

```
server_scripts/
├── backups/
│   ├── backup_to_backblaze.sh   # Off-site backup to Backblaze B2 via restic
│   ├── backup_to_laptop.sh      # Local-network backup to laptop via SFTP/restic
│   └── daily.sh                 # Wrapper that runs the backup scripts
├── .env.b2                      # Backblaze B2 credentials (gitignored)
│   (backups/.env.mail           # Gmail settings used by backup_status_email.py (gitignored))
└── README.md                    # This file
```

## Backups

Backups are managed with [restic](https://restic.net/).

### Scripts

- `backups/backup_to_backblaze.sh` — backs up selected directories to a Backblaze B2 bucket, then runs `forget --prune` and `check`.
- `backups/backup_to_laptop.sh` — backs up selected directories to a restic repository on a laptop over SFTP, then runs `forget --prune`.
- `backups/daily.sh` — convenience wrapper that can invoke the backup scripts.

### 24-Hour Guard

Both `backup_to_backblaze.sh` and `backups/backup_to_laptop.sh` now track their last successful run in `~/.local/log/backup_to_*.last`. If a script is invoked again within 24 hours of the previous successful run, it exits immediately and logs a skip message.

This prevents overlapping or redundant backups when the scripts are triggered multiple times per day (e.g., by cron, systemd timers, or manual runs).

### Logging

Every script prints timestamped progress to the terminal and appends the same lines to its log in `~/.local/log/` (`daily_backup.log`, `backup_to_backblaze.log`, `backup_to_laptop.log`). Each run reports the repository, the paths being backed up, any restic locks it finds, when each step starts and finishes with its duration, and the step and exit code if something fails. restic's own output is printed to the terminal at its default verbosity but is not written to the log files.

### Credentials

Backblaze B2 credentials are loaded from `backups/.env.b2`, which is gitignored. The file must define the environment variables that restic expects, for example:

```bash
export B2_ACCOUNT_ID=your_account_id
export B2_ACCOUNT_KEY=your_account_key
export RESTIC_PASSWORD=your_restic_password
```

### Retention Policy

Both scripts keep:

- last 10 snapshots
- daily snapshots for the last 10 days
- weekly snapshots for the last 10 weeks
- monthly snapshots for the last 10 months
- yearly snapshots for the last 10 years

## Laptop-Side Backup (laptop to this server)

The laptop (`leslie-ideapad-slim-5-light-14abr8`) backs itself up to this server's restic repository at `/mnt/hdd-stripe/backups/leslie-ideapad-slim-5-light-14abr8/restic` over SFTP. The script lives on the laptop at `~/scripts/backup_to_server.sh` (not in this repo) and runs hourly from the laptop's cron. It backs up `~/Drive` and `~/scripts`.

### Behaviour

- **24-hour guard:** the script skips if the newest snapshot for the laptop (any path set) is under 24 hours old. An earlier version only checked the first snapshot group and so never skipped.
- **Server check:** if this server is unreachable over SSH, it logs and exits quietly.

### Restic Lock Protection

1. **Single-run guard:** a local `flock` stops two copies of the script overlapping.
2. **Lock retry:** restic commands use `--retry-lock 10m` instead of failing on a brief lock.
3. **Stale-lock cleanup:** before each run it runs `restic unlock` (no `--remove-all`), which removes only locks restic judges stale. A NOTICE email is sent if any are removed. A stale exclusive lock from 2026-10-23 had blocked the hourly job until it was cleared.
4. **Graceful prune limit:** `forget --prune` runs under `timeout --signal=INT 2h` so restic can release its exclusive lock cleanly.

### Result Emails

leslie-fileserver sends the result emails, not the laptop. After each real backup the laptop only pipes the result (last 40 lines of restic output) over SSH to `backups/backup_status_email.py --notify` on this server. That script is the only code that holds the Gmail settings and sends backup email. The laptop has no mail password and makes no connection to Gmail.

- **Subject and result:** `[Backup SUCCESS|FAILURE|NOTICE] <laptop hostname> laptop to server <date>`. NOTICE is sent when stale restic locks were removed.
- **Daily status report:** `--notify` also records SUCCESS and FAILURE results in `~/.local/log/laptop_backup.status` on this server. The daily `backup_status_email.py` report (13:00 cron) shows them in its "Laptop to server backup" section, warns after 48 hours with no result and fails after 72 hours.
- **When emails are sent:** only after a real backup run. Skips send nothing. The laptop limits failure emails to one every 6 hours.
- **If this server is unreachable:** the laptop logs "Could not send ... email" and the backup is unaffected.

The laptop's `~/scripts/send_mail.py` is a thin client for `--notify`. `backups/.env.mail` (mode 600, gitignored) holds `MAIL_USER`, `MAIL_APP_PASSWORD` (a Google app password) and `MAIL_TO`. See `backups/.env.mail.example`.

## Usage

Run a backup manually:

```bash
./backups/backup_to_backblaze.sh
./backups/backup_to_laptop.sh
```

Or run the daily wrapper:

```bash
./backups/daily.sh
```

## License

This repository is for personal homelab use.
