echo "Backup to Backblaze started"

export B2_ACCOUNT_ID="5db9965a2660"
export B2_ACCOUNT_KEY="0059081b4af5c3bbc7bdccf6ec21dbd8a8f027ac0e"
export RESTIC_PASSWORD_FILE="/home/leslie/.config/restic/password"
restic -r b2:Homelab2002349994:fileserver backup\
 /etc /home/leslie\
 /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/upload\
 /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/backups\
 /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/library\
 /mnt/hdd-stripe/hdd-black/Photos/immich_library/upload/profile\
 /var/lib/docker/volumes/paperless-ngx_pgdata /mnt/hdd-stripe/hdd-black/paperless\
 /mnt/hdd-stripe/hdd-red/torrents\
 /mnt/hdd-stripe/hdd-black/Music\
 --exclude-caches -e "*/.cache/*"
restic -r b2:Homelab2002349994:fileserver forget\
 --keep-last 10 --keep-daily 10 --keep-weekly 10 --keep-monthly 10 --keep-yearly 10\
 --prune
restic -r b2:Homelab2002349994:fileserver check

