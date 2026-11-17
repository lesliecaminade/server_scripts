#!/usr/bin/env bash
# Monthly Google Drive backup using rclone.
#
# - Google Docs/Sheets/Slides/Drawings are exported to .docx/.xlsx/.pptx/.svg
#   (set EXPORT_FORMATS to change, e.g. "pdf,xlsx,docx,pptx").
# - <DEST>/<remote>/current   = mirror of Drive as of the last run
# - <DEST>/<remote>/archive/YYYY-MM-DD_HHMMSS = files that were changed or
#   deleted in Drive since the previous run (so nothing is lost, and disk use
#   stays small instead of a full copy every month).
# - Archives older than KEEP_MONTHS are pruned.
#
# Usage:  gdrive-backup.sh [-n] [remote ...]
#   -n   dry run (shows what would change, writes nothing)
# Env overrides: DEST, REMOTES, EXPORT_FORMATS, KEEP_MONTHS, LOG_DIR
#
# Cron (1st of each month, 03:00):
#   0 3 1 * * /home/leslie/scripts/gdrive-backup.sh

set -euo pipefail

DEST="${DEST:-$HOME/Backups/GoogleDrive}"
REMOTES_DEFAULT="google-drive-lesliecaminade"
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx,svg}"
KEEP_MONTHS="${KEEP_MONTHS:-12}"
LOG_DIR="${LOG_DIR:-$DEST/logs}"

DRY=()
while getopts "n" opt; do
  case $opt in n) DRY=(--dry-run) ;; *) echo "usage: $0 [-n] [remote ...]" >&2; exit 2 ;; esac
done
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then REMOTES=("$@"); else read -r -a REMOTES <<<"${REMOTES:-$REMOTES_DEFAULT}"; fi

command -v rclone >/dev/null || { echo "rclone not installed" >&2; exit 1; }
mkdir -p "$DEST" "$LOG_DIR"

# Prevent overlapping runs (cron + manual)
exec 9>"$DEST/.lock"
flock -n 9 || { echo "Another backup is already running" >&2; exit 1; }

STAMP="$(date +%Y-%m-%d_%H%M%S)"
LOG="$LOG_DIR/backup_$STAMP.log"
status=0

for remote in "${REMOTES[@]}"; do
  remote="${remote%:}"
  base="$DEST/$remote"
  mkdir -p "$base/current" "$base/archive"
  echo "[$(date -Is)] Backing up $remote: -> $base/current" | tee -a "$LOG"

  if rclone sync "$remote:" "$base/current" \
      --backup-dir "$base/archive/$STAMP" \
      --drive-export-formats "$EXPORT_FORMATS" \
      --drive-skip-shortcuts \
      --drive-acknowledge-abuse=false \
      --transfers 4 --checkers 8 \
      --retries 3 --low-level-retries 10 \
      --log-file "$LOG" --log-level INFO --stats 1m --stats-one-line \
      "${DRY[@]}"; then
    echo "[$(date -Is)] OK $remote" | tee -a "$LOG"
  else
    echo "[$(date -Is)] FAILED $remote (see $LOG)" | tee -a "$LOG" >&2
    status=1
  fi

  # Prune old archives and empty dirs
  if [ ${#DRY[@]} -eq 0 ]; then
    find "$base/archive" -mindepth 1 -maxdepth 1 -type d -mtime +$((KEEP_MONTHS * 31)) -exec rm -rf {} + || true
    find "$base/archive" -mindepth 1 -maxdepth 1 -type d -empty -delete || true
  fi
done

# Keep ~24 logs
ls -1t "$LOG_DIR"/backup_*.log 2>/dev/null | tail -n +25 | xargs -r rm -f
exit $status
