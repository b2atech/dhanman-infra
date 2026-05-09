#!/bin/bash
set -euo pipefail

STAMP="${1:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DATE=$(date +%F)
BASE_DIR="${BACKUP_ROOT:-/opt/backups}/vault/prod/${BACKUP_DATE}"
WORK_DIR="${BASE_DIR}/${STAMP}"
ARCHIVE="${BASE_DIR}/vault-${STAMP}.tar.gz"
REMOTE="${VAULT_REMOTE:-vault-b2:dhanman-prod-vault-immutable/prod/${BACKUP_DATE}}"
VAULT_CONFIG_DIR="${VAULT_CONFIG_DIR:-/etc/vault.d}"
VAULT_DATA_DIR="${VAULT_DATA_DIR:-/opt/vault/data}"

mkdir -p "$WORK_DIR"

vault status > "$WORK_DIR/vault-status.txt" 2>&1 || true
cp -a "$VAULT_CONFIG_DIR" "$WORK_DIR/etc-vault.d" 2>/dev/null || true

tar -czf "$ARCHIVE" "$VAULT_DATA_DIR" "$WORK_DIR"
rclone copy "$ARCHIVE" "$REMOTE"

echo "Vault backup complete."
