#!/bin/bash
# 2026-08-04 UTC: rescued from /srv/immich/scripts/, where it was the ONLY copy.
#                 Renamed .py -> .sh: it was always a bash script (see shebang), and
#                 the .py extension was actively misleading.
# Created: 2026-06-28 UTC — standalone verification script for export_multi on Mac Mini.
# Does NOT sync anything — read-only check. Bulk-flags possibly-missing files via `find`
# comparison (known unreliable on this destination's FSKit/ExFAT mount), then re-verifies
# each flagged file individually by exact full path before reporting it as genuinely missing.
#
# Edited: 2026-06-29 UTC — fixed ssh-inside-while-read-loop stdin bug (added -n to both ssh
#                          calls; without it, the loop silently stopped after 1 iteration).
# Edited: 2026-06-29 UTC — fixed paths containing a literal single-quote (e.g. "Amy's First
#                          Home") breaking naive single-quote command construction. Switched
#                          to printf %q-style quoting.
# Edited: 2026-06-29 UTC — removed the cleanup trap; working files persist in a fixed,
#                          known location for inspection after the script exits.
# Edited: 2026-06-29 UTC — reduced per-file noise: only prints a line when an individual
#                          check actually fails (or finds it via the case-insensitive
#                          fallback), instead of printing every file checked. Progress is
#                          now shown as a periodic counter instead.
#
# RESULT (2026-06-29): confirmed export_multi on Mac Mini is complete — 0 genuinely missing
# after individually re-checking all 286 files flagged by the unreliable bulk scan. The bulk
# enumeration discrepancy (98384 vs 98702) is a known, reproducible false-positive on this
# destination's FSKit/ExFAT mount — not real data loss. Don't trust find|wc -l counts alone
# on this destination; always individually re-verify flagged files before concluding loss.

set -e

DEST_HOST="dennishmathes@mathes-mac-mini"
SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"

SRC_BASE="/mnt/immich-data/immich/export_multi"
DEST_BASE="/Volumes/Expansion/Immich/export_multi"

WORK_DIR="/home/dhm/.cache/export-sync/verify-work"
mkdir -p "$WORK_DIR"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Building source file list..."
find "$SRC_BASE" -type f -printf '%P\n' | sort > "$WORK_DIR/src_relpaths.txt"
SRC_COUNT=$(wc -l < "$WORK_DIR/src_relpaths.txt")
echo "Source has $SRC_COUNT files."

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Building destination basename list (bulk scan, known unreliable)..."
ssh -n -i "$SSH_KEY" "$DEST_HOST" "find '$DEST_BASE' -type f -exec basename {} \;" | sort > "$WORK_DIR/dest_basenames.txt"
DEST_COUNT=$(wc -l < "$WORK_DIR/dest_basenames.txt")
echo "Destination bulk scan reports $DEST_COUNT files."

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Flagging candidates not seen in bulk destination scan..."
FLAGGED_FILE="$WORK_DIR/flagged.txt"
> "$FLAGGED_FILE"
while IFS= read -r relpath; do
    bn=$(basename "$relpath")
    if ! grep -qxF "$bn" "$WORK_DIR/dest_basenames.txt"; then
        echo "$relpath" >> "$FLAGGED_FILE"
    fi
done < "$WORK_DIR/src_relpaths.txt"

FLAGGED_COUNT=$(wc -l < "$FLAGGED_FILE")
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Bulk scan flagged $FLAGGED_COUNT file(s). Re-verifying each individually by exact path..."

REAL_MISSING_FILE="$WORK_DIR/real_missing.txt"
ERROR_FILE="$WORK_DIR/errors.txt"
> "$REAL_MISSING_FILE"
> "$ERROR_FILE"
CHECKED=0

while IFS= read -r relpath; do
    CHECKED=$((CHECKED + 1))

    # Periodic progress counter every 25 files, instead of a line per file.
    if (( CHECKED % 25 == 0 )); then
        echo "  ...checked $CHECKED/$FLAGGED_COUNT"
    fi

    dest_path="$DEST_BASE/$relpath"
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
        echo "  [$CHECKED/$FLAGGED_COUNT] GENUINELY MISSING: $relpath"
    fi
done < "$FLAGGED_FILE"

echo ""
echo "=== Verification complete ==="
echo "Source files: $SRC_COUNT"
echo "Destination bulk-scan count: $DEST_COUNT"
echo "Flagged by bulk scan: $FLAGGED_COUNT"
echo "Individually re-checked: $CHECKED"
REAL_MISSING_COUNT=$(wc -l < "$REAL_MISSING_FILE")
echo "Genuinely missing after individual re-check: $REAL_MISSING_COUNT"
echo ""
echo "Working files preserved in: $WORK_DIR"

if [ "$REAL_MISSING_COUNT" -gt 0 ]; then
    echo ""
    echo "=== GENUINELY MISSING FILES ==="
    cat "$REAL_MISSING_FILE"
else
    echo "No genuinely missing files. All flagged files were false positives from the bulk scan."
fi
# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
