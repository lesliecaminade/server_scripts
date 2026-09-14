#!/bin/bash
set -euo pipefail

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

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/backup_to_laptop.log"
LAST_SUCCESS_FILE="$LOG_DIR/backup_to_laptop.last"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

check_last_run() {
    local interval_seconds=86400
    if [[ -f "$LAST_SUCCESS_FILE" ]]; then
        local last_ts now_ts elapsed
        last_ts=$(stat -c %Y "$LAST_SUCCESS_FILE")
        now_ts=$(date +%s)
        elapsed=$((now_ts - last_ts))
        if (( elapsed < interval_seconds )); then
            local hours=$((elapsed / 3600))
            local minutes=$(((elapsed % 3600) / 60))
            log "Skipping backup because last successful run was ${hours}h${minutes}m ago"
            exit 0
        fi
    fi
}

unlock_stale_locks() {
    local repo="$1"
    local max_age_seconds=86400
    local now_ts lock_id lock_time lock_ts age
    now_ts=$(date +%s)
    for lock_id in $(restic -r "$repo" list locks 2>/dev/null); do
        lock_time=$(restic -r "$repo" cat lock "$lock_id" 2>/dev/null | grep -o '"time": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        [[ -z "$lock_time" ]] && continue
        lock_ts=$(date -d "$lock_time" +%s 2>/dev/null) || continue
        age=$((now_ts - lock_ts))
        if (( age > max_age_seconds )); then
            log "Restic lock $lock_id is $((age / 3600))h old, running unlock"
            restic -r "$repo" unlock --remove-all
            break
        fi
    done
}

check_last_run
log "Backup to laptop started"

unlock_stale_locks "$REPO"

restic -r "$REPO" backup \
    /etc \
    /home/leslie \
    /var/lib/docker/volumes/paperless-ngx_pgdata \
    /mnt/hdd-stripe/hdd-black/paperless \
    /mnt/hdd-stripe/hdd-red/torrents \
    --exclude-caches \
    -e "*/.cache/*"

restic -r "$REPO" forget \
    --keep-last 10 \
    --keep-daily 10 \
    --keep-weekly 10 \
    --keep-monthly 10 \
    --keep-yearly 10 \
    --prune

echo "$(date +%s)" > "$LAST_SUCCESS_FILE"
log "Backup to laptop completed successfully"
