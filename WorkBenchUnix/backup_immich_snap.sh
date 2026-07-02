#!/bin/bash
# Created: 2026-06-23 — immich backup script (pg_dumpall + rsync mirror)
set -e

TARGET_MOUNT="$1"
if [ -z "$TARGET_MOUNT" ]; then
    echo "Usage: backup_immich.sh /mnt/backup-a"
    exit 1
fi

if [ ! -d "$TARGET_MOUNT" ] || ! mountpoint -q "$TARGET_MOUNT"; then
    echo "ERROR: $TARGET_MOUNT is not mounted. Aborting."
    exit 1
fi

DATESTAMP=$(date +%Y-%m-%d_%H%M)
DUMP_DIR="$TARGET_MOUNT/immich/postgres-dumps"
IMAGE_DEST="$TARGET_MOUNT/immich/images"

mkdir -p "$DUMP_DIR"
mkdir -p "$IMAGE_DEST"

echo "[$DATESTAMP] Starting pg_dumpall..."
docker exec immich_postgres pg_dumpall -U postgres > "$DUMP_DIR/immich-dump_$DATESTAMP.sql"
echo "[$DATESTAMP] pg_dumpall complete."

# Retention: keep last 14 dumps, delete older
ls -1t "$DUMP_DIR"/immich-dump_*.sql | tail -n +15 | xargs -r rm --

echo "[$DATESTAMP] Starting image rsync mirror..."
rsync -a --delete /mnt/immich-data/immich/images/ "$IMAGE_DEST/"
echo "[$DATESTAMP] Image rsync complete."

echo "[$DATESTAMP] Backup to $TARGET_MOUNT finished."
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
