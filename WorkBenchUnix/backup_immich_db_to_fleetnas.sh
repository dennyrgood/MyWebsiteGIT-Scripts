#!/bin/bash
# Created: 2026-07-31 UTC — pushes the latest Postgres dump from WBU to FleetNAS, then
# prunes the destination to the newest KEEP dumps. Runs ON WorkBenchUnix. One-way push,
# daily. Companion to backup_immich_images_to_fleetnas.sh: images without a matching DB
# dump restore nothing, so the pair is the actual unit of recovery.
#
# Source is postgres-dumps-latest/, written by dump_immich_db_for_cwhu.sh at 3:30am —
# the same drive-independent dump CWHU's warm-sync pulls. Nothing here depends on any
# backup-a/b/c drive's health (all three are disabled; backup-c was USB-bridge/rcu-stall
# corruption, not media failure).
#
# Improvement over backup_immich_db_to_macmini.sh: that script verifies only rsync's
# exit code before pruning the destination. Exit 0 means "bytes moved", not "the dump is
# a valid dump" — a truncated pg_dumpall (source ran out of disk, or Postgres was killed
# mid-dump) transfers perfectly and then triggers a prune that deletes the last good one.
# So this script checks the pg_dumpall completion marker TWICE: on the local file before
# sending, and on the landed remote copy before pruning. restore_from_wbu.sh already does
# the remote-side version of this check for exactly the same reason — it is the only cheap
# signal that distinguishes a complete dump from a plausible-looking fragment.
set -e

WBU_DUMP_DIR="/mnt/immich-data/immich/postgres-dumps-latest"
# LAN address for now — switch to the Tailscale name once Tailscale is installed on
# the NAS (see FleetNAS State of the Union, Pending -> Tailscale).
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="/home/dhm/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"

# Two spellings of the same directory — see the long comment in
# backup_immich_images_to_fleetnas.sh for the full reasoning. Short version: UGOS's
# patched rsync rejects absolute paths and addresses destinations by share name
# ("immich/postgres-dumps/"), while plain ssh commands still need the real path.
DEST_RSYNC="$DEST_HOST:immich/postgres-dumps/"
DEST_PATH="/volume1/immich/postgres-dumps"

# Matches the 2 that dump_immich_db_for_cwhu.sh retains at source, so the NAS mirrors
# the live dump window rather than accumulating. Deeper history comes from FleetNAS's
# Btrfs snapshots, not from piling up .sql files here — dumps are ~2.3GB each and
# growing (1.23GB -> 2.25GB across 2026-07-30/31, expected: ML process updated).
KEEP=2

# pg_dumpall's closing line. Its absence means truncation, wherever it's missing.
DUMP_MARKER="PostgreSQL database cluster dump complete"

LOG_DIR="/home/dhm/.cache/fleetnas-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/fleetnas_db_${TS}.log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting postgres dump sync: WBU immich-data -> FleetNAS ==="

# Explicit if-check rather than a bare `LATEST_DUMP=$(...)`: under set -e a failed
# command substitution exits immediately, skipping straight past the error message
# that explains what happened. Same trap that hid the 2026-07-22 CWHU failure.
if ! LATEST_DUMP=$(ls -1t "$WBU_DUMP_DIR"/immich-dump_*.sql 2>/dev/null | head -1); then
    log "ERROR: could not list dumps in $WBU_DUMP_DIR. Aborting before touching FleetNAS."
    exit 1
fi
if [ -z "$LATEST_DUMP" ]; then
    log "ERROR: no postgres dump found in $WBU_DUMP_DIR. Aborting before touching FleetNAS."
    exit 1
fi
LATEST_DUMP_NAME=$(basename "$LATEST_DUMP")
log "Latest dump: $LATEST_DUMP_NAME ($(du -h "$LATEST_DUMP" | cut -f1))"

# 1. Verify the LOCAL dump before spending bandwidth on it. A truncated dump at source
#    is worth catching here, loudly, rather than faithfully mirroring it to the NAS.
if [ ! -s "$LATEST_DUMP" ]; then
    log "ERROR: local dump is empty. Aborting — check dump_immich_db_for_cwhu.sh (3:30am)."
    exit 1
fi
if ! tail -5 "$LATEST_DUMP" | grep -q "$DUMP_MARKER"; then
    log "ERROR: local dump does not end with the pg_dumpall completion marker — it is truncated."
    log "Aborting before pushing. FleetNAS keeps its previous good dump. Check WBU disk space and the 3:30am dump job."
    exit 1
fi
log "Local dump verified complete."

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing dump to FleetNAS..."
set +e
rsync -aq -e "$SSH_OPTS" "$LATEST_DUMP" "$DEST_RSYNC" >/dev/null 2>>"$LOG_FILE"
RSYNC_EXIT=$?
set -e
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "ERROR: rsync exited with code $RSYNC_EXIT — transfer failed or incomplete. Aborting before pruning, so FleetNAS keeps its previous good dump."
    exit 1
fi
log "Sync complete."

# 2. Verify the LANDED copy. Catches corruption in transit — the 2026-07-23 CWHU
#    outage was exactly this: a WBU-side I/O problem corrupting the SSH transport
#    mid-transfer ("message authentication code incorrect").
log "Verifying landed dump on FleetNAS..."
if ! ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" \
        "tail -5 '$DEST_PATH/$LATEST_DUMP_NAME' | grep -q '$DUMP_MARKER'"; then
    log "ERROR: the dump on FleetNAS does not end with the completion marker — truncated or corrupted in transit."
    log "Aborting before pruning, so the previous good dump on FleetNAS is not deleted. The bad file is left in place for inspection: $DEST_PATH/$LATEST_DUMP_NAME"
    exit 1
fi
log "Landed dump verified complete."

# 3. Only now is it safe to delete anything.
log "Pruning FleetNAS — keeping newest $KEEP dump(s)..."
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" \
    "ls -1t '$DEST_PATH'/immich-dump_*.sql 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --"

REMAINING=$(ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" \
    "find '$DEST_PATH' -maxdepth 1 -type f -name 'immich-dump_*.sql'" | wc -l)
# "up to $KEEP", not "$KEEP" — before this job has run $KEEP times there are
# legitimately fewer, and a flat "expected: 2" reads like a failure on day one.
log "Prune complete. $REMAINING dump file(s) remain on FleetNAS (expected: up to $KEEP)."

log "=== Postgres dump sync to FleetNAS complete ==="
