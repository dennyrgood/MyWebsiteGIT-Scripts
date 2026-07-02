#!/bin/bash
# Created: 2026-06-29 UTC — pushes Immich export_multi from WBU to Mac Mini, then verifies.
# Runs ON WorkBenchUnix. One-way push (WBU is source, not pull). Flat-mirror, not versioned.
#
# Verification note: this destination's FSKit/ExFAT mount has a confirmed, reproducible bug
# where bulk directory enumeration (`find -type f`, `ls -1`) silently omits a subset of real,
# present files — proven via individual exact-path checks on 2026-06-29 (286 flagged by bulk
# scan, 0 genuinely missing after individual re-check). Because of this, a simple file-count
# comparison is NOT trustworthy on this destination. This script instead: (1) does a cheap
# bulk scan to flag candidates, then (2) individually re-verifies ONLY the flagged subset by
# exact path before reporting anything as genuinely missing. This keeps the check fast for
# the common case (most files aren't flagged) while remaining accurate for the flagged ones.
#
# Genuinely-missing files are reported but do NOT abort the run or other scheduled jobs —
# this script always exits 0 so cron doesn't treat a partial transfer as a hard failure.
# Check the log for "GENUINELY MISSING" lines if you need to know whether anything real
# is actually missing.
#
# Edited: 2026-06-30 UTC — rsync's own exit code was previously left unguarded against
# set -e, so a partial-transfer exit (e.g. code 23, from unreadable source files on a
# failing source drive) silently killed the script before verification ever ran, with
# no log output explaining why. Now the rsync exit code is captured and logged instead
# of being allowed to kill the script — verification proceeds regardless, since it is
# the actual mechanism for determining real scope of any problem.

set -e

DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
SSH_OPTS="ssh -i $SSH_KEY"

SRC="/mnt/immich-data/immich/export_multi/"
DEST_BASE_PATH="/Volumes/Expansion/Immich/export_multi"
DEST="$DEST_HOST:$DEST_BASE_PATH/"

LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/macmini_export_multi_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-multi"

mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting export_multi sync: WBU -> Mac Mini ==="

log "Syncing export_multi..."
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

ssh -n -i "$SSH_KEY" "$DEST_HOST" "find '$DEST_BASE_PATH' -type f -exec basename {} \;" | sort > "$WORK_DIR/dest_basenames.txt"
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
    ssh -n -i "$SSH_KEY" "$DEST_HOST" "test -e $remote_quoted_path" 2>>"$ERROR_FILE"
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
    found=$(ssh -n -i "$SSH_KEY" "$DEST_HOST" "find $remote_quoted_dir -maxdepth 1 -iname $remote_quoted_bn" 2>>"$ERROR_FILE")
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

log "=== Export sync to Mac Mini (export_multi) complete ==="

# --- Cron placeholder — NOT ACTIVE, schedule not yet decided ---
# 0 7 * * * /srv/immich/scripts/export_multi_to_macmini.sh >> /home/dhm/.cache/export-sync/cron.log 2>&1
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
