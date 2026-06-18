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

check_last_run
log "Backup to laptop started"

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
