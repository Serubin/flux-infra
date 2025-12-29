
#!/bin/bash
#
# K3s Storage Backup Script
# Copies /opt/k3s/storage to /opt/k3s/backup with timestamps
# Deletes backups older than 36 hours
#
# Usage: Run via cron every hour:
#   0 * * * * /path/to/backup-k3s-storage.sh
#

set -euo pipefail

SOURCE_DIR="/opt/k3s/storage"
BACKUP_DIR="/opt/k3s/backup"
RETENTION_HOURS=36

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp for this backup
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="storage_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

echo "[$(date)] Starting backup of ${SOURCE_DIR}..."

# Create the backup using rsync for efficiency (handles permissions, symlinks, etc.)
if command -v rsync &> /dev/null; then
    rsync -a --delete "${SOURCE_DIR}/" "${BACKUP_PATH}/"
else
    # Fallback to cp if rsync is not available
    cp -a "${SOURCE_DIR}" "${BACKUP_PATH}"
fi

echo "[$(date)] Backup completed: ${BACKUP_PATH}"

# Delete backups older than retention period
echo "[$(date)] Cleaning up backups older than ${RETENTION_HOURS} hours..."

find "$BACKUP_DIR" -maxdepth 1 -type d -name "storage_*" -mmin +$((RETENTION_HOURS * 60)) -exec rm -rf {} \; 2>/dev/null || true

echo "[$(date)] Cleanup completed."
