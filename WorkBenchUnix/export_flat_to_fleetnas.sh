#!/bin/bash
# Created: 2026-08-03 UTC — pushes Immich export_flat from WBU to FleetNAS (UGREEN
# DXP6800 Pro, RAID 5 / Btrfs), then verifies. Runs ON WorkBenchUnix. One-way push.
#
# The FleetNAS counterpart to export_flat_to_macmini.sh. Structure is borrowed from
# backup_immich_images_to_fleetnas.sh, NOT from the Mac Mini twin, for two reasons:
#
#   1. The Mac Mini script verifies with a bulk scan followed by a per-file `ssh test -e`
#      recheck of every flagged path. That loop exists to work around a specific,
#      reproducible FSKit/ExFAT bug on the Mac Mini's Expansion drive, where bulk
#      enumeration silently omits files that are genuinely present (286 flagged, 0 really
#      missing, 2026-06-29). FleetNAS is Btrfs and has no such bug, so importing that
#      workaround would be carrying a fix for a problem this destination does not have —
#      at the cost of one SSH round-trip per flagged file. It also matched on *basename
#      anywhere in the destination tree*, so a file in the wrong directory counted as
#      present. The `rsync -ain` dry run used here is path-exact and single-connection.
#
#   2. UGOS's patched rsync needs the share-name destination form, which the Mac Mini
#      script has no notion of. See the DEST_RSYNC comment below.
#
# --no-perms is load-bearing, not tidiness — see the comment at the sync call.
set -e

SRC="/mnt/immich-data/immich/export_flat/"
# LAN address for now. Once Tailscale is installed on the NAS, switch this to the
# Tailscale name so the push survives the NAS moving networks.
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="/home/dhm/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"

# TWO different ways to name the same directory on FleetNAS — do not merge them.
# DEST_RSYNC: UGOS ships a patched rsync whose server side rejects absolute paths
# ("invalid path: '/volume1/...'"). It addresses destinations by SHARE NAME with no
# /volume1 prefix. Requires Control Panel -> File Services -> "Enable backup rsync
# service". DEST_PATH: plain ssh commands (mkdir below) are NOT affected by the patch
# and need the real absolute path. Full reasoning in
# backup_immich_images_to_fleetnas.sh.
DEST_RSYNC="$DEST_HOST:immich/export_flat/"
DEST_PATH="/volume1/immich/export_flat"
DEST="$DEST_RSYNC"

# export_flat is regenerated wholesale by export_archive.py (~11hr, manual-only), so a
# large deletion count here usually means a regeneration changed the layout rather than
# a genuine purge. Either way it wants a human to look before --delete replays it onto
# the backup.
MAX_DELETE=500
IOWAIT_THRESHOLD=20

LOG_DIR="/home/dhm/.cache/fleetnas-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/fleetnas_export_flat_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-export-flat"
mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting export_flat sync: WBU -> FleetNAS ==="

# 0. Preflight: is WBU healthy enough to be trusted as a source right now? Checked
#    before anything touches the NAS, so a bad run costs only this run. On 2026-07-23
#    WBU's own I/O distress (RCU stalls) corrupted data mid-transfer, and this push runs
#    --delete against the backup-of-record.
read -r _ a1 b1 c1 i1 w1 _ < /proc/stat
sleep 1
read -r _ a2 b2 c2 i2 w2 _ < /proc/stat
DT=$(( (a2+b2+c2+i2+w2) - (a1+b1+c1+i1+w1) ))
DIOWAIT=$((w2 - w1))
IOWAIT_PCT=$(( DT > 0 ? DIOWAIT * 100 / DT : 0 ))
# grep -c exits 1 when the count is zero, which set -e would treat as fatal.
DSTATE=$(ps -eo stat= | grep -c "^D" || true)
log "WBU health: iowait=${IOWAIT_PCT}% D-state-procs=${DSTATE}"
# Gated on both signals: a healthy nightly backup can sit in D-state without high
# iowait, so requiring both avoids the false positives wbu-health-monitor.sh hit.
if [ "$IOWAIT_PCT" -gt "$IOWAIT_THRESHOLD" ] && [ "$DSTATE" -gt 0 ]; then
    log "WBU looks like it's in I/O distress — skipping this sync. FleetNAS is untouched."
    exit 0
fi

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing export_flat (--delete, --max-delete=$MAX_DELETE)..."
set +e
# --no-perms: the UGREEN share forces mode 777 on everything it stores, so the source's
# 644 can never be represented there. Without this, the verification pass below flags
# EVERY file as drift with itemize ".f...p....." — no transfer needed, permissions only.
# Measured on the images backup 2026-08-03: 283,460 of 283,460 files falsely reported as
# drift on a transfer that was byte-perfect. Must stay in sync with the --no-perms on the
# verification rsync.
rsync -aq --no-perms --delete --max-delete="$MAX_DELETE" -e "$SSH_OPTS" "$SRC" "$DEST" >/dev/null 2>>"$LOG_FILE"
RSYNC_EXIT=$?
set -e
# Exit 25 is specifically --max-delete tripping. Call that out, because unlike a
# transport error it means the sync was refused on purpose and needs a human decision.
if [ "$RSYNC_EXIT" -eq 25 ]; then
    log "ABORTED: rsync hit --max-delete=$MAX_DELETE — the source has more deletions pending than expected."
    log "Nothing was deleted on FleetNAS. Confirm the deletions are intentional (a fresh export_archive.py run can legitimately reshuffle many files), then rerun by hand with a raised --max-delete."
    exit 1
fi
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "WARNING: rsync exited with code $RSYNC_EXIT (partial transfer or error). See $LOG_FILE for rsync's stderr. Continuing to verification to determine actual scope."
fi

log "Sync complete. Verifying with a second dry-run pass..."

DRIFT_FILE="$WORK_DIR/drift.txt"
# A clean sync leaves nothing to do on a rerun. Whatever this prints is real remaining
# difference: new/changed files (>f...), or pending deletions (*deleting). Unchanged
# directories still itemize as ".d..t......" — those are noise, so drop them.
# --no-perms must match the sync rsync above, or this check can never pass.
set +e
rsync -ain --no-perms --delete -e "$SSH_OPTS" --out-format='%i|%n' "$SRC" "$DEST" 2>>"$LOG_FILE" \
    | grep -v '^\.d' > "$DRIFT_FILE"
set -e
DRIFT_COUNT=$(wc -l < "$DRIFT_FILE")

if [ "$DRIFT_COUNT" -gt 0 ]; then
    log "WARNING: $DRIFT_COUNT path(s) still differ between WBU and FleetNAS after the sync:"
    head -50 "$DRIFT_FILE" | while IFS= read -r f; do
        log "  DRIFT: $f"
    done
    if [ "$DRIFT_COUNT" -gt 50 ]; then
        log "  ... $((DRIFT_COUNT - 50)) more — see $DRIFT_FILE"
    fi
else
    log "export_flat verification complete — FleetNAS matches WBU exactly (0 differences)."
fi

SRC_COUNT=$(find "$SRC" -type f | wc -l)
log "Source file count: $SRC_COUNT"

log "=== export_flat sync to FleetNAS complete ==="

# --- Cron placeholder — NOT ACTIVE, comment-only quick-reference ---
# Manual-only by design, matching export_flat_to_macmini.sh: export_flat only changes
# when export_archive.py is re-run by hand (~11hr), so there is nothing for a nightly
# job to pick up most nights.
# /home/dhm/repos/scripts/WorkBenchUnix/export_flat_to_fleetnas.sh >> /home/dhm/.cache/fleetnas-sync/cron.log 2>&1
