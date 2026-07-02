#!/bin/bash
# Created: 2026-06-30 UTC — generates a fresh pg_dumpall on win-d, independent of
# any backup drive. Exists specifically so CWHU's warm-sync (restore_from_wbu.sh)
# has a dump source that doesn't depend on backup-c (or any other backup USB
# drive)'s health — see Immich-Backup-Strategy-Present-and-Future.md, "Drive
# Health Incident — backup-c (2026-06-30)" for why this was needed.
set -e

DUMP_DIR="/mnt/immich-data/immich/postgres-dumps-latest"
DATESTAMP=$(date +%Y-%m-%d_%H%M)

mkdir -p "$DUMP_DIR"

echo "[$DATESTAMP] Starting pg_dumpall (for CWHU)..."
docker exec immich_postgres pg_dumpall -U postgres > "$DUMP_DIR/immich-dump_$DATESTAMP.sql"
echo "[$DATESTAMP] pg_dumpall complete."

# Keep last 2 — this is a thin, current-only copy for CWHU to pull, not a
# history archive (that's what backup-c/backup-a already do).
ls -1t "$DUMP_DIR"/immich-dump_*.sql | tail -n +3 | xargs -r rm --

echo "[$DATESTAMP] Dump for CWHU complete."
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
