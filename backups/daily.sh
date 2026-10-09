#!/bin/bash
set -Eeuo pipefail

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/daily_backup.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

format_duration() {
    local seconds="$1"
    printf '%dh%02dm%02ds' $((seconds / 3600)) $(((seconds % 3600) / 60)) $((seconds % 60))
}

on_error() {
    local exit_code=$?
    log "ERROR: '$BASH_COMMAND' failed with exit code $exit_code (line $1), aborting daily backup"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

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

# Runs a backup script without aborting the daily run if it fails.
run_backup() {
    local name="$1"
    local script="$2"
    local start=$SECONDS
    local exit_code=0
    log "Starting: $name"
    bash "$script" || exit_code=$?
    if (( exit_code == 0 )); then
        log "Finished: $name in $(format_duration $((SECONDS - start)))"
    else
        log "$name failed with exit code $exit_code after $(format_duration $((SECONDS - start)))"
    fi
}

BACKUP_DIR="/home/leslie/scripts/backups"

SCRIPT_START=$SECONDS
log "===== Daily backup script started ====="

running_containers=$(docker ps -q)

if [[ -n "$running_containers" ]]; then
    log "Running containers:"
    docker ps --format '{{.Names}}' | while read -r name; do
        log "  $name"
    done
    run_step "stop running containers" docker stop $running_containers
else
    log "No running containers to stop"
fi

run_step "start pihole" docker start pihole
run_step "snapraid sync" snapraid sync
run_step "snapraid scrub" snapraid scrub

run_backup "Laptop backup" "$BACKUP_DIR/backup_to_laptop.sh"
run_backup "Backblaze backup" "$BACKUP_DIR/backup_to_backblaze.sh"

if [[ -n "$running_containers" ]]; then
    run_step "restart previously running containers" docker start $running_containers
fi

log "===== Daily backup script finished in $(format_duration $((SECONDS - SCRIPT_START))) ====="
