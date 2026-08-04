#!/bin/bash
# Created: 2026-06-29 UTC — pushes the live Immich image library from WBU to Mac Mini,
# then verifies. Runs ON WorkBenchUnix. One-way push. Layer 1.5 — second-hardware copy
# of WBU's live data, distinct from the export_flat/export_multi mirror already on this
# same destination drive.
#
# Edited: 2026-06-30 UTC — switched source from backup-c (images-history/latest/) to
# win-d (images/) directly. Trigger: backup-c's drive was found failing (SMART extended
# self-test failure, growing pending sectors — see Immich-Backup-Strategy-Present-and-
# Future.md, "Drive Health Incident"). win-d's image tree is structurally identical to
# backup-c's (confirmed directly, same dated session) and win-d's own NVMe SMART data
# came back fully healthy. This script — like restore_from_wbu.sh and
# dump_immich_db_for_cwhu.sh — no longer depends on any backup-a/b/c drive's health.
#
# Edited: 2026-06-30 UTC — rsync's own exit code was previously left unguarded against
# set -e. First real run against backup-c hit this directly: a few unreadable source
# files (failing drive) caused rsync to exit 23, killing the script silently before
# verification ever ran. Now the rsync exit code is captured and logged instead of being
# allowed to kill the script — verification proceeds regardless, since it is the actual
# mechanism for determining real scope of any problem.
#
# Edited: 2026-07-22 UTC — added ConnectTimeout/ServerAlive to every ssh/rsync call.
# Root-caused a ~2hr Immich outage on CWHU the same week: a sibling script's bare ssh
# call (no timeout) hung indefinitely on a transient SSH blip to a remote host, leaving
# a destructive operation half-done with no recovery for hours (see restore_from_wbu.sh's
# 2026-07-22 comment). This script's per-file verification loop makes many individual ssh
# calls to the destination, so it's the most exposed of the two — one hung connection
# during a multi-hour verification pass would otherwise stall indefinitely.
set -e

SRC="/mnt/immich-data/immich/images/"
DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_PATH="/Volumes/Expansion/Immich/backup/images"
DEST="$DEST_HOST:$DEST_PATH/"

LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/macmini_images_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-images"
mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting live image sync: WBU win-d -> Mac Mini ==="

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing images..."
set +e
rsync -aq --delete -e "$SSH_OPTS" "$SRC" "$DEST" >/dev/null 2>>"$LOG_FILE"
RSYNC_EXIT=$?
set -e
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "WARNING: rsync exited with code $RSYNC_EXIT (non-zero, partial transfer or error). See $LOG_FILE for rsync's stderr. Continuing to verification to determine actual scope."
fi

log "Sync complete. Starting verification (bulk scan + individual recheck of flagged files)..."

find "$SRC" -type f -printf '%P\n' | sort > "$WORK_DIR/src_relpaths.txt"
SRC_COUNT=$(wc -l < "$WORK_DIR/src_relpaths.txt")
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "find '$DEST_PATH' -type f -exec basename {} \;" | sort > "$WORK_DIR/dest_basenames.txt"
DEST_COUNT=$(wc -l < "$WORK_DIR/dest_basenames.txt")

FLAGGED_FILE="$WORK_DIR/flagged.txt"
> "$FLAGGED_FILE"
while IFS= read -r relpath; do
    bn=$(basename "$relpath")
    if ! grep -qxF "$bn" "$WORK_DIR/dest_basenames.txt"; then
        echo "$relpath" >> "$FLAGGED_FILE"
    fi
done < "$WORK_DIR/src_relpaths.txt"
FLAGGED_COUNT=$(wc -l < "$FLAGGED_FILE")
log "Bulk scan: source $SRC_COUNT files, destination $DEST_COUNT files, $FLAGGED_COUNT flagged for individual recheck."

REAL_MISSING_FILE="$WORK_DIR/real_missing.txt"
ERROR_FILE="$WORK_DIR/errors.txt"
> "$REAL_MISSING_FILE"
> "$ERROR_FILE"
while IFS= read -r relpath; do
    dest_path="$DEST_PATH/$relpath"
    remote_quoted_path=$(printf '%q' "$dest_path")
    set +e
    ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "test -e $remote_quoted_path" 2>>"$ERROR_FILE"
    exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        continue
    fi
    dest_dir=$(dirname "$dest_path")
    bn=$(basename "$relpath")
    remote_quoted_dir=$(printf '%q' "$dest_dir")
    remote_quoted_bn=$(printf '%q' "$bn")
    set +e
    found=$(ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "find $remote_quoted_dir -maxdepth 1 -iname $remote_quoted_bn" 2>>"$ERROR_FILE")
    set -e
    if [ -z "$found" ]; then
        echo "$relpath" >> "$REAL_MISSING_FILE"
    fi
done < "$FLAGGED_FILE"
REAL_MISSING_COUNT=$(wc -l < "$REAL_MISSING_FILE")

if [ "$REAL_MISSING_COUNT" -gt 0 ]; then
    log "WARNING: $REAL_MISSING_COUNT file(s) genuinely missing after individual recheck (of $FLAGGED_COUNT flagged):"
    while IFS= read -r f; do
        log "  GENUINELY MISSING: $f"
    done < "$REAL_MISSING_FILE"
else
    log "Image verification complete — 0 genuinely missing ($FLAGGED_COUNT flagged by bulk scan, all false positives on recheck)."
fi

log "=== Live image sync to Mac Mini complete ==="

# --- Cron placeholder — converted to live weekly cron 2026-06-30, see crontab ---
# 0 7 * * 5 /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_images_to_macmini.sh >> /home/dhm/.cache/export-sync/cron.log 2>&1
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
