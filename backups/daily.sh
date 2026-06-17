#!/bin/bash
set -x

echo "===== Backup script started at $(date '+%Y-%m-%d %H:%M:%S') ====="

running_containers=$(docker ps -q)

docker stop $running_containers
docker start pihole
snapraid sync
snapraid scrub

sh /home/leslie/scripts/backups/backup_to_laptop.sh || echo "Laptop backup failed at $(date '+%Y-%m-%d %H:%M:%S')"
sh /home/leslie/scripts/backups/backup_to_backblaze.sh || echo "Backblaze backup failed at $(date '+%Y-%m-%d %H:%M:%S')"

docker start $running_containers

echo "===== Backup script finished at $(date '+%Y-%m-%d %H:%M:%S') ====="
