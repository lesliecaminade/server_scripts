echo "Backup to laptop started"

export RESTIC_PASSWORD_FILE="/home/leslie/.config/restic/password"
restic -r sftp:leslie@leslie-ideapad-slim-5-light-14abr8:/home/leslie/backups/leslie-fileserver/restic backup\
 /etc /home/leslie\
 /var/lib/docker/volumes/paperless-ngx_pgdata /mnt/hdd-stripe/hdd-black/paperless\
 /mnt/hdd-stripe/hdd-red/torrents\
 --exclude-caches -e "*/.cache/*"
restic -r sftp:leslie@leslie-ideapad-slim-5-light-14abr8:/home/leslie/backups/leslie-fileserver/restic forget\
 --keep-last 10 --keep-daily 10 --keep-weekly 10 --keep-monthly 10 --keep-yearly 10\
 --prune
