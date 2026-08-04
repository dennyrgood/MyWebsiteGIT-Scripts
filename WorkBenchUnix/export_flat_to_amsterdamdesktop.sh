#!/bin/bash
# Created: 2026-06-29 UTC — pushes Immich export_flat from WBU to AmsterdamDesktop, then verifies.
# Runs ON WorkBenchUnix. One-way push (WBU is source, not pull). Flat-mirror, not versioned.
#
# Verification: AmsterdamDesktop's SSH server drops into plain Windows cmd.exe. Bulk
# enumeration via `dir /s /b` has been confirmed unreliable here too (same kind of false-
# positive gap seen on Mac Mini — proven via individual exact-path checks on export_multi,
# 2026-06-29 — 0 genuinely missing despite bulk scans flagging ~300 files). This script does
# a cheap bulk scan to flag candidates, then individually re-verifies ONLY the flagged subset
# via Windows `if exist` before reporting anything as genuinely missing. NTFS is case-
# insensitive for lookups, so no -iname-style fallback is needed here.
#
# Genuinely-missing files are reported but do NOT abort the run — this script always exits 0.
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

DEST_HOST="drden@amsterdamdesktop"
SSH_KEY="/home/dhm/.ssh/id_ed25519_amsterdamdesktop"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"

SRC="/mnt/immich-data/immich/export_flat/"
DEST="$DEST_HOST:/cygdrive/f/Media/Immich/export_flat/"
DEST_WIN_PATH="F:\\Media\\Immich\\export_flat"

LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/amsterdamdesktop_export_flat_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-ams-flat"

mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting export_flat sync: WBU -> AmsterdamDesktop ==="

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

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "dir /s /b /a-d \"$DEST_WIN_PATH\"" \
    | tr -d '\r' \
    | sed "s|.*\\\\||" \
    | sort > "$WORK_DIR/dest_basenames.txt"
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
> "$REAL_MISSING_FILE"
CHECKED=0

while IFS= read -r relpath; do
    CHECKED=$((CHECKED + 1))
    win_relpath=$(echo "$relpath" | tr '/' '\\')
    win_full_path="${DEST_WIN_PATH}\\${win_relpath}"

    set +e
    result=$(ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "if exist \"$win_full_path\" (echo FOUND) else (echo NOTFOUND)" | tr -d '\r')
    set -e

    if [ "$result" != "FOUND" ]; then
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

log "=== Export sync to AmsterdamDesktop (export_flat) complete ==="

# --- Cron placeholder — NOT ACTIVE, comment-only quick-reference ---
# 0 7 * * * /home/dhm/repos/scripts/WorkBenchUnix/export_flat_to_amsterdamdesktop.sh >> /home/dhm/.cache/export-sync/cron.log 2>&1
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
