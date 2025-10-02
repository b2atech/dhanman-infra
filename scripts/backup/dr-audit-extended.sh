#!/bin/bash
# Disaster Recovery Extended Audit Script
# Collects server setup details into a timestamped folder and uploads to Backblaze B2

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="$HOME/dr-audit-$TIMESTAMP"
LATEST_LINK="$HOME/dr-audit-latest"

mkdir -p "$OUTDIR"
echo "🔹 Saving extended audit results to $OUTDIR"

# 1. OS & Kernel
lsb_release -a > "$OUTDIR/os-release.txt" 2>&1
uname -a > "$OUTDIR/kernel.txt" 2>&1

# 2. Installed Packages
dpkg --get-selections | grep -v deinstall > "$OUTDIR/installed-packages.txt"

# 3. Enabled & Running Services
systemctl list-unit-files --type=service | grep enabled > "$OUTDIR/enabled-services.txt"
systemctl list-units --type=service --state=running > "$OUTDIR/running-services.txt"

# 4. Nginx
if command -v nginx >/dev/null 2>&1; then
  mkdir -p "$OUTDIR/nginx"
  cp -r /etc/nginx/sites-available "$OUTDIR/nginx/" 2>/dev/null
  cp -r /etc/nginx/sites-enabled "$OUTDIR/nginx/" 2>/dev/null
  nginx -T > "$OUTDIR/nginx/full-config-dump.txt" 2>&1
fi

# 5. PostgreSQL Databases
if command -v psql >/dev/null 2>&1; then
  sudo -u postgres psql -c "\l" > "$OUTDIR/postgres-databases.txt" 2>&1
  psql --version > "$OUTDIR/postgres-version.txt" 2>&1
fi

# 6. Docker
if command -v docker >/dev/null 2>&1; then
  docker ps -a > "$OUTDIR/docker-containers.txt" 2>&1
  docker images > "$OUTDIR/docker-images.txt" 2>&1
  docker network ls > "$OUTDIR/docker-networks.txt" 2>&1
  docker volume ls > "$OUTDIR/docker-volumes.txt" 2>&1
  docker inspect $(docker ps -aq) > "$OUTDIR/docker-inspect.json" 2>/dev/null
fi

# 7. Cron Jobs
crontab -l > "$OUTDIR/crontab-root.txt" 2>&1
sudo ls /etc/cron.d/ > "$OUTDIR/cron.d-list.txt" 2>&1

# 8. SSL Certificates (Certbot)
if command -v certbot >/dev/null 2>&1; then
  sudo certbot certificates > "$OUTDIR/certbot-certs.txt" 2>&1
fi

# 9. System Users
cut -d: -f1 /etc/passwd > "$OUTDIR/users.txt"

# 10. Network Listening Ports
ss -tulnp > "$OUTDIR/listening-ports.txt" 2>&1

# 11. Disk Usage
df -h > "$OUTDIR/disk-usage.txt" 2>&1

# 12. App Directories
ls -l /var/www > "$OUTDIR/var-www.txt" 2>&1
ls -l /var/www/prod > "$OUTDIR/var-www-prod.txt" 2>&1
ls -l /var/www/qa > "$OUTDIR/var-www-qa.txt" 2>&1

# 13. Promtail/Grafana Configs
mkdir -p "$OUTDIR/promtail" "$OUTDIR/grafana"
cp -r /etc/promtail/* "$OUTDIR/promtail/" 2>/dev/null
cp -r /etc/grafana/* "$OUTDIR/grafana/" 2>/dev/null

# Compress everything
tar -czf "$OUTDIR.tar.gz" -C "$(dirname $OUTDIR)" "$(basename $OUTDIR)"

# Update "latest" symlink
ln -sfn "$OUTDIR" "$LATEST_LINK"

# 14. Upload snapshot to Backblaze B2
if command -v rclone >/dev/null 2>&1; then
  rclone copy "$OUTDIR.tar.gz" backblaze:dhanman-dr-snapshots
  echo "☁️  Uploaded snapshot to Backblaze B2"
else
  echo "⚠️ rclone not found, skipping upload to Backblaze"
fi

# 15. Local retention (cleanup old files >7 days)
find $HOME -maxdepth 1 -type d -name "dr-audit-20*" -mtime +7 -exec rm -rf {} \;
find $HOME -maxdepth 1 -type f -name "dr-audit-20*.tar.gz" -mtime +7 -exec rm -f {} \;

echo "🧹 Cleaned up local snapshots older than 7 days"
echo "✅ Extended audit complete."
echo "   Snapshot: $OUTDIR.tar.gz"
echo "   Latest symlink: $LATEST_LINK"
