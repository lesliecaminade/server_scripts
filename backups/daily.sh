#!/bin/bash
# Daily backup: stop containers, SnapRAID sync and scrub, restic backups, start containers.
#
# Safety: the containers that this script stops always start again, even if a
# step fails, the script gets SIGTERM/SIGINT/SIGHUP, or the server restarts in
# the middle of a run. The names of the stopped containers are kept in
# STATE_FILE until they are running again. The next run starts any container
# that an earlier run left stopped.

# cron starts this file with "sh daily.sh". sh is not bash and rejects the
# "set" options below, so run the script again under bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

# "daily.sh --manual" runs a backup now. Cron runs it without the flag. Both
# send the same summary email when the run ends, whether it worked or not.
TRIGGER=scheduled
for arg in "$@"; do
    [[ "$arg" == "--manual" ]] && TRIGGER=manual
done

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/daily_backup.log"
STATE_FILE="$LOG_DIR/daily_backup.containers"
LOCK_FILE="/var/lock/daily_backup.lock"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-6h}"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

format_duration() {
    local seconds="$1"
    printf '%dh%02dm%02ds' $((seconds / 3600)) $(((seconds % 3600) / 60)) $((seconds % 60))
}

containers_to_restart=()
restart_done=0
restart_failed=0

# Starts every container in containers_to_restart. It never aborts on an
# error, it tries each container up to 3 times, and it runs only once.
restart_containers() {
    (( restart_done == 0 )) || return 0
    restart_done=1
    (( ${#containers_to_restart[@]} > 0 )) || return 0

    set +e
    trap - ERR
    local start=$SECONDS name attempt
    log "Starting: restart previously running containers (${#containers_to_restart[@]})"

    if ! docker start "${containers_to_restart[@]}" >/dev/null 2>&1; then
        log "docker start failed for the whole group, starting each container alone"
        for name in "${containers_to_restart[@]}"; do
            for attempt in 1 2 3; do
                if docker start "$name" >/dev/null 2>&1; then
                    break
                fi
                if (( attempt == 3 )); then
                    log "ERROR: could not start container $name after 3 attempts"
                    restart_failed=1
                else
                    sleep 5
                fi
            done
        done
    fi

    if (( restart_failed == 0 )); then
        rm -f "$STATE_FILE"
        log "Finished: restart previously running containers in $(format_duration $((SECONDS - start)))"
    else
        log "ERROR: some containers are still stopped. Their names stay in $STATE_FILE"
    fi
}

on_exit() {
    local exit_code=$?
    restart_containers
    if (( exit_code == 0 && restart_failed != 0 )); then
        exit_code=1
    fi
    # Containers are running again by now. A mail problem must never change
    # the result of the run or hold it up for long.
    sleep 2  # let the output copy above finish writing
    log "Sending summary email ($TRIGGER run)"
    timeout 180 python3 "$BACKUP_DIR/backup_status_email.py" --after-run --trigger "$TRIGGER" >> "$LOG_FILE" 2>&1 \
        || log "Could not send the summary email."
    exit "$exit_code"
}

on_error() {
    local exit_code=$?
    log "ERROR: '$BASH_COMMAND' failed with exit code $exit_code (line $1), aborting daily backup"
    exit "$exit_code"
}

on_signal() {
    log "Received signal $1, aborting daily backup"
    exit "$2"
}

run_step() {
    local name="$1"
    shift
    local start=$SECONDS
    log "Starting: $name"
    "$@" || {
        local exit_code=$?
        log "ERROR: $name failed with exit code $exit_code after $(format_duration $((SECONDS - start))), aborting daily backup"
        exit "$exit_code"
    }
    log "Finished: $name in $(format_duration $((SECONDS - start)))"
}

# Runs a backup script without aborting the daily run if it fails or hangs.
run_backup() {
    local name="$1"
    local script="$2"
    local start=$SECONDS
    local exit_code=0
    log "Starting: $name (time limit $BACKUP_TIMEOUT)"
    timeout --foreground "$BACKUP_TIMEOUT" bash "$script" || exit_code=$?
    if (( exit_code == 0 )); then
        log "Finished: $name in $(format_duration $((SECONDS - start)))"
    elif (( exit_code == 124 )); then
        log "$name stopped after the time limit of $BACKUP_TIMEOUT"
    else
        log "$name failed with exit code $exit_code after $(format_duration $((SECONDS - start)))"
    fi
}

BACKUP_DIR="/home/leslie/scripts/backups"

# Only one run at a time. A second run would see the containers of the first
# run as stopped and could start them while the first run still backs up.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another daily backup is already running. Exiting."
    exit 0
fi

# Keep the full output of this run (stdout AND stderr of every step) in a file
# that the summary email reads when something fails. Without this, stderr only
# went to cron mail and the real cause of a failure was lost.
RUN_OUT="$LOG_DIR/daily_backup_last_run.out"
: > "$RUN_OUT"
exec > >(tee -a "$RUN_OUT") 2>&1

SCRIPT_START=$SECONDS
log "===== Daily backup script started ====="

mapfile -t running_containers < <(docker ps --format '{{.Names}}')

# Containers that an earlier run stopped and did not start again.
previous_containers=()
if [[ -s "$STATE_FILE" ]]; then
    mapfile -t previous_containers < "$STATE_FILE"
    log "Found containers that an earlier run left stopped: ${previous_containers[*]}"
fi

declare -A seen=()
for name in "${previous_containers[@]}" "${running_containers[@]}"; do
    if [[ -n "$name" && -z "${seen[$name]:-}" ]]; then
        seen[$name]=1
        containers_to_restart+=("$name")
    fi
done

# Save the names before the first container stops, and set the traps before
# anything can fail.
if (( ${#containers_to_restart[@]} > 0 )); then
    printf '%s\n' "${containers_to_restart[@]}" > "$STATE_FILE"
fi
trap on_exit EXIT
trap 'on_error $LINENO' ERR
trap 'on_signal SIGTERM 143' TERM
trap 'on_signal SIGINT 130' INT
trap 'on_signal SIGHUP 129' HUP

if (( ${#running_containers[@]} > 0 )); then
    log "Running containers:"
    for name in "${running_containers[@]}"; do
        log "  $name"
    done
    run_step "stop running containers" docker stop "${running_containers[@]}"
else
    log "No running containers to stop"
fi

run_step "start pihole" docker start pihole
run_step "snapraid sync" snapraid sync
run_step "snapraid scrub" snapraid scrub

run_backup "Laptop backup" "$BACKUP_DIR/backup_to_laptop.sh"
run_backup "Backblaze backup" "$BACKUP_DIR/backup_to_backblaze.sh"

restart_containers

log "===== Daily backup script finished in $(format_duration $((SECONDS - SCRIPT_START))) ====="
