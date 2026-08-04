#!/bin/bash
# Created: 2026-06-29 UTC — pushes the latest postgres dump from WBU to Mac Mini,
# then prunes the destination to keep only that one dump.
# Runs ON WorkBenchUnix. One-way push. Layer 1.5 — second-hardware copy of WBU's
# DB dump, distinct from the export_flat/export_multi mirror on this same drive.
#
# Edited: 2026-06-30 UTC — switched source from backup-c's postgres-dumps/ to
# win-d's postgres-dumps-latest/ (populated by the new standalone
# dump_immich_db_for_cwhu.sh, 30 5 * * *). Trigger: backup-c's drive was found
# failing — see Immich-Backup-Strategy-Present-and-Future.md, "Drive Health
# Incident". This script no longer depends on any backup-a/b/c drive's health;
# it shares its dump source with CWHU's warm-sync. Naming pattern (immich-dump_*.sql)
# is unchanged, only the source directory.
#
# Edited: 2026-06-30 UTC — rsync's own exit code was previously left unguarded
# against set -e. Unlike the image script, this one does NOT continue into a
# verification phase on a partial-transfer exit, because pruning the destination
# down to a single file is destructive: if the new dump didn't actually land
# cleanly, pruning anyway would delete the last good dump and leave nothing. So a
# non-zero rsync exit here aborts cleanly with a clear log message, rather than
# silently dying (the old behavior) or continuing to prune (which would be
# actively dangerous).
#
# Edited: 2026-07-22 UTC — added ConnectTimeout/ServerAlive to every ssh/rsync call.
# Root-caused a ~2hr Immich outage on CWHU the same week: a sibling script's bare ssh
# call (no timeout) hung indefinitely on a transient SSH blip to a remote host, leaving
# a destructive operation half-done with no recovery for hours (see restore_from_wbu.sh's
# 2026-07-22 comment). This script has the same bare-ssh-to-remote-host shape and runs
# unattended on a weekly cron with no one watching, so it gets the same treatment.
set -e

WBU_DUMP_DIR="/mnt/immich-data/immich/postgres-dumps-latest"
DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_PATH="/Volumes/Expansion/Immich/backup/postgres-dumps"

LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/macmini_db_${TS}.log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting postgres dump sync: WBU win-d -> Mac Mini ==="

LATEST_DUMP=$(ls -1t "$WBU_DUMP_DIR"/immich-dump_*.sql | head -1)
if [ -z "$LATEST_DUMP" ]; then
    log "ERROR: no postgres dump found in $WBU_DUMP_DIR. Aborting."
    exit 1
fi
LATEST_DUMP_NAME=$(basename "$LATEST_DUMP")
log "Latest dump: $LATEST_DUMP_NAME"

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing dump to Mac Mini..."
set +e
rsync -aq -e "$SSH_OPTS" "$LATEST_DUMP" "$DEST_HOST:$DEST_PATH/" >/dev/null 2>>"$LOG_FILE"
RSYNC_EXIT=$?
set -e
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "ERROR: rsync exited with code $RSYNC_EXIT — dump transfer failed or incomplete. Aborting before pruning, so the previous good dump on the destination is not deleted."
    exit 1
fi
log "Sync complete."

log "Pruning destination — keeping only $LATEST_DUMP_NAME..."
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "find '$DEST_PATH' -maxdepth 1 -type f -name 'immich-dump_*.sql' ! -name '$LATEST_DUMP_NAME' -delete"

REMAINING=$(ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "find '$DEST_PATH' -maxdepth 1 -type f -name 'immich-dump_*.sql'" | wc -l)
log "Prune complete. $REMAINING dump file(s) remain at destination (expected: 1)."

log "=== Postgres dump sync to Mac Mini complete ==="

# --- Cron placeholder — converted to live weekly cron 2026-06-30, see crontab ---
# 0 7 * * 5 /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_db_to_macmini.sh >> /home/dhm/.cache/export-sync/cron.log 2>&1
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
