#!/bin/bash
# Created: 2026-06-27 10:42 UTC — warm-sync job: ChatWorkhorseUnix pulls from WorkBenchUnix
# Edited: 2026-06-27 — fixed completion-marker check: "cluster dump complete", not "dump complete"
# Edited: 2026-06-30 UTC — switched source from WBU's backup-c to WBU's win-d (live data).
# Trigger: backup-c's drive was found failing (SMART extended self-test failure, growing
# pending sectors — see Immich-Backup-Strategy-Present-and-Future.md, "Drive Health
# Incident"). Images now read from win-d/immich/images/ directly (the live source, healthy,
# no dated-folder wrapper needed). DB dump now reads from win-d/immich/postgres-dumps-latest/,
# produced by the new standalone dump_immich_db_for_cwhu.sh (5:30am), independent of any
# backup drive's health. No other logic changed — format, completion marker, and restore
# steps are unchanged since the dump is still pg_dumpall, uncompressed, same as before.
# Runs ON ChatWorkhorseUnix, triggered by CWHU's own cron (6am daily). Destructive by
# design — see runbook v6.6.
# 2026-06-30 UTC: WBU renamed its win-d mount to immich-data; updated remote-facing
# references (ssh/rsync targets) below to match.
# 2026-06-30 UTC: CWHU also renamed its own local win-d mount to immich-data (separate
# mount, separate UUID, on /dev/sdb1 — a VM vdi). LIVE_IMAGES, DUMP_STAGING, and the
# local Postgres wipe path below updated to match. Both machines now use immich-data
# consistently; no win-d mounts remain on either host.
set -e
WBU_HOST="workbenchunix"   # Tailscale name
WBU_USER="dhm"
LIVE_IMAGES="/mnt/immich-data/immich/images"
DUMP_STAGING="/mnt/immich-data/immich/restore-dump"
DUMP_STAGING_FILE="$DUMP_STAGING/latest-sync-dump.sql"
cd /home/dhm/immich-app
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting warm-sync from WBU's immich-data."
# 1. Stop CWHU's Immich stack first — avoids any race between the live
#    container and the incremental image rsync that's about to run.
echo "Stopping CWHU's Immich stack..."
docker compose down
# 2. Pull the latest Postgres dump from WBU's immich-data into local staging.
#    Cheap and small enough to stage separately before touching anything live.
mkdir -p "$DUMP_STAGING"
LATEST_DUMP=$(ssh "$WBU_USER@$WBU_HOST" "ls -1t /mnt/immich-data/immich/postgres-dumps-latest/immich-dump_*.sql | head -1")
if [ -z "$LATEST_DUMP" ]; then
    echo "ERROR: could not find a dump file on WBU's immich-data. Aborting before touching anything live."
    docker compose up -d
    exit 1
fi
echo "Pulling dump: $LATEST_DUMP"
rsync -avh --checksum "$WBU_USER@$WBU_HOST:$LATEST_DUMP" "$DUMP_STAGING_FILE"
# 3. Verify the staged dump looks complete before doing anything destructive with it.
#    Minimum bar: file exists, non-empty, and ends with the expected pg_dumpall
#    closing marker rather than being truncated mid-transfer.
if [ ! -s "$DUMP_STAGING_FILE" ]; then
    echo "ERROR: staged dump is missing or empty. Aborting before touching anything live."
    docker compose up -d
    exit 1
fi
if ! tail -5 "$DUMP_STAGING_FILE" | grep -q "PostgreSQL database cluster dump complete"; then
    echo "ERROR: staged dump does not end with the expected pg_dumpall completion marker — possible truncation. Aborting before touching anything live."
    docker compose up -d
    exit 1
fi
echo "Staged dump verified complete."
# 4. Incremental image rsync, directly into the live path — this is where
#    "only changes" actually happens, since rsync compares against what's
#    already there. Stack is down, so nothing's reading/writing concurrently.
#    --delete matches immich-data's own behavior: if it's gone on WBU, it's gone here too.
echo "Re-checking UPLOAD_LOCATION ownership before rsync..."
sudo chown -R 1000:1000 "$LIVE_IMAGES"
echo "Syncing images from WBU's immich-data (live)..."
rsync -avh --delete "$WBU_USER@$WBU_HOST:/mnt/immich-data/immich/images/" "$LIVE_IMAGES/"
# 5. Wipe and restore Postgres from the staged, verified dump.
#    find -mindepth 1 -delete, not rm -rf */ — see runbook v5/v6 for why the
#    glob version silently no-ops under sudo.
echo "Wiping CWHU's Postgres data directory..."
sudo find /mnt/immich-data/immich/postgres/ -mindepth 1 -delete
echo "Bringing up Postgres only, to restore into it..."
docker compose up -d database
until docker exec immich_postgres pg_isready -U postgres; do sleep 2; done
echo "Restoring dump..."
cat "$DUMP_STAGING_FILE" | docker exec -i immich_postgres psql -U postgres > /tmp/warm-sync-restore.log 2>&1
if grep -qi error /tmp/warm-sync-restore.log; then
    echo "WARNING: possible errors during restore — check /tmp/warm-sync-restore.log on CWHU."
    echo "(Note: 'role already exists' / 'database already exists' lines are expected and harmless.)"
fi
# 6. Bring the full stack back up.
echo "Bringing up full stack..."
docker compose up -d
rsync -aq --delete /home/dhm/.cache/cwhu-warm-sync/ "$WBU_USER@$WBU_HOST:/home/dhm/.cache/cwhu-warm-sync/"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Warm-sync complete."
