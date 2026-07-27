#!/bin/bash
# Created: 2026-06-29 UTC — pushes Immich export_flat from WBU to Mac Mini, then verifies.
# Runs ON WorkBenchUnix. One-way push (WBU is source, not pull). Flat-mirror, not versioned.
#
# Verification: bulk `find`-based enumeration on this destination has been confirmed
# unreliable (proven via individual exact-path checks on export_multi, 2026-06-29 — 0
# genuinely missing despite bulk scans consistently flagging ~300 files). This script does a
# cheap bulk scan to flag candidates, then individually re-verifies ONLY the flagged subset
# by exact path before reporting anything as genuinely missing.
#
# Genuinely-missing files are reported but do NOT abort the run — this script always exits 0
# so cron/manual runs don't treat a flagged-but-unconfirmed mismatch as a hard failure.
#
# Edited: 2026-06-30 UTC — rsync's own exit code was previously left unguarded against
# set -e, so a partial-transfer exit (e.g. code 23, from unreadable source files on a
# failing source drive) silently killed the script before verification ever ran, with
# no log output explaining why. Now the rsync exit code is captured and logged instead
# of being allowed to kill the script — verification proceeds regardless, since it is
# the actual mechanism for determining real scope of any problem.
#
# Edited: 2026-07-22 UTC — added ConnectTimeout/ServerAlive to every ssh/rsync call, same
# fix applied to restore_from_wbu.sh and the Mac Mini backup scripts this week after a
# ~2hr Immich outage caused by a bare ssh call hanging indefinitely on a transient SSH
# blip. This script is manual-only (not cron-scheduled), so a hang here just freezes your
# terminal rather than silently stalling unattended — lower stakes, but same cheap fix.

set -e
DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
SRC="/mnt/immich-data/immich/export_flat/"
DEST_BASE_PATH="/Volumes/Expansion/Immich/export_flat"
DEST="$DEST_HOST:$DEST_BASE_PATH/"
LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/macmini_export_flat_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-flat"
mkdir -p "$LOG_DIR" "$WORK_DIR"
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}
log "=== Starting export_flat sync: WBU -> Mac Mini ==="
log "Syncing export_flat..."
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
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "find '$DEST_BASE_PATH' -type f -exec basename {} \;" | sort > "$WORK_DIR/dest_basenames.txt"
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
CHECKED=0
while IFS= read -r relpath; do
    CHECKED=$((CHECKED + 1))
    dest_path="$DEST_BASE_PATH/$relpath"
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
    log "Verification complete — 0 genuinely missing ($FLAGGED_COUNT flagged by bulk scan, all false positives on recheck)."
fi
log "=== Export sync to Mac Mini (export_flat) complete ==="
# --- Cron placeholder — NOT ACTIVE, comment-only quick-reference ---
# 0 7 * * * /srv/immich/scripts/export_flat_to_macmini.sh >> /home/dhm/.cache/export-sync/cron.log 2>&1
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
