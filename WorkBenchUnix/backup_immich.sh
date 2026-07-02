#!/bin/bash
# Created: 2026-06-23 — immich backup script (pg_dumpall + rsync mirror)
# Edited: 2026-06-26 — switched image backup from flat mirror to --link-dest dated trees (retains history)
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
IMAGE_BASE="$TARGET_MOUNT/immich/images-history"
IMAGE_DEST="$IMAGE_BASE/$DATESTAMP"
LATEST_LINK="$IMAGE_BASE/latest"
mkdir -p "$DUMP_DIR"
mkdir -p "$IMAGE_BASE"

echo "[$DATESTAMP] Starting pg_dumpall..."
docker exec immich_postgres pg_dumpall -U postgres > "$DUMP_DIR/immich-dump_$DATESTAMP.sql"
echo "[$DATESTAMP] pg_dumpall complete."

# Retention: keep last 14 dumps, delete older
ls -1t "$DUMP_DIR"/immich-dump_*.sql | tail -n +15 | xargs -r rm --

echo "[$DATESTAMP] Starting image rsync (versioned)..."
if [ -d "$LATEST_LINK" ]; then
    rsync -a --delete --link-dest="$LATEST_LINK" /mnt/immich-data/immich/images/ "$IMAGE_DEST/"
else
    rsync -a --delete /mnt/immich-data/immich/images/ "$IMAGE_DEST/"
fi
rm -f "$LATEST_LINK"
ln -s "$IMAGE_DEST" "$LATEST_LINK"
echo "[$DATESTAMP] Image rsync complete."

# Retention for image snapshots — match the 14-dump retention already in place
ls -1dt "$IMAGE_BASE"/20* | tail -n +15 | xargs -r rm -rf --

echo "[$DATESTAMP] Backup to $TARGET_MOUNT finished."
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
