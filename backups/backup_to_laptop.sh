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
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

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

log "Backup to laptop completed successfully"
