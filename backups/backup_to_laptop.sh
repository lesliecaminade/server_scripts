#!/bin/bash
set -Eeuo pipefail

# Load shared configuration from a separate, gitignored file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env.b2" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env.b2"
else
    echo "Missing credentials file: $SCRIPT_DIR/.env.b2" >&2
    exit 1
fi

LAPTOP_USER="leslie"
LAPTOP_HOST="leslie-ideapad-slim-5-light-14abr8"
LAPTOP_REPO_PATH="/home/leslie/backups/leslie-fileserver/restic"
REPO="sftp:${LAPTOP_USER}@${LAPTOP_HOST}:${LAPTOP_REPO_PATH}"

BACKUP_PATHS=(
    /etc
    /home/leslie
    /var/lib/docker/volumes/paperless-ngx_pgdata
    /mnt/hdd-stripe/hdd-black/paperless
    /mnt/hdd-stripe/hdd-red/torrents
)

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/backup_to_laptop.log"
LAST_SUCCESS_FILE="$LOG_DIR/backup_to_laptop.last"
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
    log "ERROR: '$BASH_COMMAND' failed with exit code $exit_code (line $1), aborting backup"
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
        log "ERROR: $name failed with exit code $exit_code after $(format_duration $((SECONDS - start))), aborting backup"
        exit "$exit_code"
    }
    log "Finished: $name in $(format_duration $((SECONDS - start)))"
}

check_last_run() {
    local interval_seconds=86400
    if [[ -f "$LAST_SUCCESS_FILE" ]]; then
        local last_ts now_ts elapsed
        last_ts=$(stat -c %Y "$LAST_SUCCESS_FILE")
        now_ts=$(date +%s)
        elapsed=$((now_ts - last_ts))
        local hours=$((elapsed / 3600))
        local minutes=$(((elapsed % 3600) / 60))
        if (( elapsed < interval_seconds )); then
            log "Skipping backup because last successful run was ${hours}h${minutes}m ago"
            exit 0
        fi
        log "Last successful run was ${hours}h${minutes}m ago, proceeding"
    else
        log "No previous successful run recorded, proceeding"
    fi
}

unlock_stale_locks() {
    local repo="$1"
    local max_age_seconds=86400
    local now_ts lock_id lock_time lock_ts age
    local lock_count=0
    now_ts=$(date +%s)
    for lock_id in $(restic -r "$repo" list locks 2>/dev/null || true); do
        lock_count=$((lock_count + 1))
        lock_time=$(restic -r "$repo" cat lock "$lock_id" 2>/dev/null | grep -o '"time": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
        if [[ -z "$lock_time" ]]; then
            log "Could not read creation time of restic lock $lock_id, leaving it"
            continue
        fi
        if ! lock_ts=$(date -d "$lock_time" +%s 2>/dev/null); then
            log "Could not parse time '$lock_time' of restic lock $lock_id, leaving it"
            continue
        fi
        age=$((now_ts - lock_ts))
        if (( age > max_age_seconds )); then
            log "Restic lock $lock_id is $((age / 3600))h old, running unlock"
            restic -r "$repo" unlock --remove-all
            return
        fi
        log "Restic lock $lock_id is $((age / 3600))h old, leaving it"
    done
    log "Found $lock_count restic lock(s), none older than $((max_age_seconds / 3600))h"
}

SCRIPT_START=$SECONDS
check_last_run
log "Backup to laptop started"
log "Repository: $REPO"
log "Paths to back up:"
for path in "${BACKUP_PATHS[@]}"; do
    log "  $path"
done

run_step "check for stale restic locks" unlock_stale_locks "$REPO"

run_step "restic backup" restic -r "$REPO" backup \
    "${BACKUP_PATHS[@]}" \
    --exclude-caches \
    -e "*/.cache/*"

run_step "restic forget --prune" restic -r "$REPO" forget \
    --keep-last 10 \
    --keep-daily 10 \
    --keep-weekly 10 \
    --keep-monthly 10 \
    --keep-yearly 10 \
    --prune

echo "$(date +%s)" > "$LAST_SUCCESS_FILE"
log "Backup to laptop completed successfully in $(format_duration $((SECONDS - SCRIPT_START)))"
