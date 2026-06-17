#!/bin/bash
set -euo pipefail

LOG_DIR="/home/leslie/.local/log"
LOG_FILE="$LOG_DIR/daily_backup.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

BACKUP_DIR="/home/leslie/scripts/backups"

log "===== Daily backup script started ====="

running_containers=$(docker ps -q)

if [[ -n "$running_containers" ]]; then
    docker stop $running_containers
fi

docker start pihole
snapraid sync
snapraid scrub

sh "$BACKUP_DIR/backup_to_laptop.sh" || log "Laptop backup failed"
sh "$BACKUP_DIR/backup_to_backblaze.sh" || log "Backblaze backup failed"

if [[ -n "$running_containers" ]]; then
    docker start $running_containers
fi

log "===== Daily backup script finished ====="
