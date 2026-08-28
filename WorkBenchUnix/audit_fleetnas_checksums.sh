#!/bin/bash
# audit_fleetnas_checksums.sh — one-off content audit of the FleetNAS mirror.
# Created: 2026-08-28.
#
# WHY
#   Between roughly 2026-06 and 2026-08-25, WBU ran four mismatched DIMMs that
#   were corrupting data in flight (see OFFSITE_BACKUP.md, "The RAM fault").
#   Throughout that period backup_immich_images_to_fleetnas.sh mirrored the
#   library nightly with --delete. rsync compares SIZE and MTIME, not content,
#   so a corrupted byte would have propagated to FleetNAS silently and the
#   nightly verification pass would still have reported "0 differences".
#
#   This re-runs that verification with --checksum, which forces both ends to
#   read and hash every file. It is the only way to tell a good mirror from a
#   mirror that faithfully copied damage.
#
# SAFETY
#   Dry run only (-n). Nothing on FleetNAS is written, moved or deleted. The
#   --delete flag is present solely so the report matches what the real sync
#   would consider; in dry-run mode it only prints.
#
# COST
#   Reads ~85 GiB on WBU and ~85 GiB on FleetNAS. Expect hours, disk-bound at
#   the NAS end rather than network-bound. Run it when nothing else needs
#   either machine.
#
# WHAT IT CANNOT TELL YOU
#   Whether a photo was already corrupt before it ever reached WBU. This
#   compares the two copies; it does not know what the camera wrote.

set -u

SRC="/mnt/immich-data/immich/images/"
DEST_HOST="dhm@192.168.178.123"
# UGOS ships a patched rsync whose server side rejects absolute paths, so the
# destination must stay relative — same as backup_immich_images_to_fleetnas.sh.
DEST="$DEST_HOST:immich/images/"
SSH_KEY="/home/dhm/.ssh/id_ed25519_fleetnas"
SSH_OPTS="ssh -i $SSH_KEY -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

TS=$(date -u +%Y%m%d_%H%M%SZ)
LOG_DIR="/home/dhm/.cache/fleetnas-audit"
LOG="$LOG_DIR/checksum_audit_$TS.log"
DIFFS="$LOG_DIR/checksum_diffs_$TS.txt"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

log "=== FleetNAS content audit (checksum, dry run) ==="
log "source: $SRC"
log "dest:   $DEST"

[ -d "$SRC" ] || { log "FAILED: $SRC missing"; exit 1; }
[ -r "$SSH_KEY" ] || { log "FAILED: cannot read $SSH_KEY"; exit 1; }
mountpoint -q /mnt/immich-data || { log "FAILED: /mnt/immich-data not mounted"; exit 1; }

log "This reads ~85 GiB at BOTH ends and will take hours. Starting..."
START=$(date +%s)

# -a archive, -i itemise, -n dry run, -c compare by checksum not size+mtime.
# --no-perms must match the sync script, or every file reports a permission
# difference and drowns the real signal.
nice -n 10 ionice -c2 -n7 \
    rsync -ain --no-perms --delete -c \
        -e "$SSH_OPTS" --out-format='%i|%n' \
        "$SRC" "$DEST" 2>>"$LOG" > "$DIFFS"
RC=$?

ELAPSED=$(( $(date +%s) - START ))
log "rsync exit=$RC, elapsed $((ELAPSED / 60))m"

if [ "$RC" -ne 0 ]; then
    log "FAILED: rsync error $RC — see $LOG"
    exit 1
fi

TOTAL=$(wc -l < "$DIFFS")
# In itemised output the third character is 'c' when the CHECKSUM differs.
# That is the finding this audit exists for: same size, same mtime, different
# content — exactly the shape memory corruption leaves behind.
CONTENT=$(grep -c '^>f..c' "$DIFFS" 2>/dev/null || echo 0)
MISSING=$(grep -c '^>f+++++++++' "$DIFFS" 2>/dev/null || echo 0)
DELETES=$(grep -c '^\*deleting' "$DIFFS" 2>/dev/null || echo 0)

log "--- results ---"
log "total itemised differences : $TOTAL"
log "CONTENT MISMATCHES         : $CONTENT   <- the ones that matter"
log "missing on FleetNAS        : $MISSING"
log "extra on FleetNAS          : $DELETES"

if [ "$CONTENT" -eq 0 ] && [ "$TOTAL" -eq 0 ]; then
    log "RESULT: FleetNAS matches WBU byte-for-byte. No corruption propagated."
elif [ "$CONTENT" -eq 0 ]; then
    log "RESULT: no content mismatches. The $TOTAL difference(s) are additions or"
    log "        deletions since the last sync — normal if Immich has been active."
else
    log "RESULT: $CONTENT FILE(S) DIFFER IN CONTENT between WBU and FleetNAS."
    log "        Same size and mtime, different bytes. Investigate before re-syncing:"
    log "        a plain sync would overwrite one copy with the other, and rsync"
    log "        cannot tell you which side is the good one."
    log "        The restic repo is the tiebreaker — it verified clean, so WBU's"
    log "        current content is trustworthy and FleetNAS should be corrected."
    grep '^>f..c' "$DIFFS" | head -20 | tee -a "$LOG"
fi

log "full itemised output: $DIFFS"
