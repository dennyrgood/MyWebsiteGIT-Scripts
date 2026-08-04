#!/bin/bash
# 2026-08-04 UTC: rescued from /srv/immich/scripts/, where it was the ONLY copy.
#                 NOTE its SRC is /mnt/backup-c, which was retired 2026-07-22 after
#                 repeated failures. Kept for reference rather than use — repoint SRC
#                 before running it against anything.
# Created: 2026-06-30 UTC — standalone verification-only check, extracted from
# backup_immich_images_to_macmini.sh, to assess a partial/aborted rsync run
# without re-running the transfer itself.
set -e

SRC="/mnt/backup-c/immich/images-history/latest/"
DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
DEST_PATH="/Volumes/Expansion/Immich/backup/images"

LOG_DIR="/home/dhm/.cache/export-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/macmini_images_verifyonly_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-images"
mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Verification-only check (no rsync) of backup-c images mirror on Mac Mini ==="

find "$SRC" -type f -printf '%P\n' | sort > "$WORK_DIR/src_relpaths.txt"
SRC_COUNT=$(wc -l < "$WORK_DIR/src_relpaths.txt")
ssh -n -i "$SSH_KEY" "$DEST_HOST" "find '$DEST_PATH' -type f -exec basename {} \;" | sort > "$WORK_DIR/dest_basenames.txt"
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

log "=== Verification-only check complete ==="
