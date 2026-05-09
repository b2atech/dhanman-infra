#!/bin/bash
set -euo pipefail

STAMP="${1:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DATE=$(date +%F)
OUTDIR="${BACKUP_ROOT:-/opt/backups}/minio/prod/${BACKUP_DATE}"
DATADIR="${MINIO_DATA_DIR:-/opt/minio/data}"
REMOTE="${FILES_REMOTE:-files-b2:dhanman-prod-files-immutable/prod/minio/${BACKUP_DATE}}"

if [[ ! -d "$DATADIR" ]]; then
  echo "MinIO data path not found: $DATADIR"
  exit 0
fi

mkdir -p "$OUTDIR/data"

echo "Starting filesystem backup into $OUTDIR"
rsync -a --delete "$DATADIR/" "$OUTDIR/data/"
rclone copy "$OUTDIR/data" "$REMOTE"

echo "Filesystem backup complete."
