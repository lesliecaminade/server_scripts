#!/bin/bash
set -euo pipefail

# Load Backblaze B2 credentials from a separate, gitignored file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env.b2" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env.b2"
else
    echo "Missing credentials file: $SCRIPT_DIR/.env.b2" >&2
    exit 1
fi

B2_BUCKET="Homelab2002349994"
B2_REPO_PATH="fileserver"
REPO="b2:${B2_BUCKET}:${B2_REPO_PATH}"

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/backup_to_backblaze.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

log "Backup to Backblaze started"

restic -r "$REPO" backup \
    /etc \
    /home/leslie \
    /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/upload \
    /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/backups \
    /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/library \
    /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/profile \
    /var/lib/docker/volumes/paperless-ngx_pgdata \
    /mnt/hdd-stripe/hdd-black/paperless \
    /mnt/hdd-stripe/hdd-red/torrents \
    /mnt/hdd-stripe/hdd-black/Music \
    --exclude-caches \
    -e "*/.cache/*"

restic -r "$REPO" forget \
    --keep-last 10 \
    --keep-daily 10 \
    --keep-weekly 10 \
    --keep-monthly 10 \
    --keep-yearly 10 \
    --prune

restic -r "$REPO" check

log "Backup to Backblaze completed successfully"

