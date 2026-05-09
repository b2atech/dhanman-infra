#!/bin/bash
set -euo pipefail

STAMP="${1:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DATE=$(date +%F)
BASE_DIR="${BACKUP_ROOT:-/opt/backups}/configs/prod/${BACKUP_DATE}"
ARCHIVE="${BASE_DIR}/configs-${STAMP}.tar.gz"
REMOTE="${CONFIGS_REMOTE:-configs-b2:dhanman-prod-configs-immutable/prod/${BACKUP_DATE}}"

mkdir -p "$BASE_DIR"

tar -czf "$ARCHIVE" \
  /etc/nginx \
  /etc/postgresql \
  /etc/systemd/system \
  /etc/vault.d \
  /opt/scripts \
  /etc/minio-backup.env \
  2>/dev/null || true

rclone copy "$ARCHIVE" "$REMOTE"

echo "Config backup complete."
