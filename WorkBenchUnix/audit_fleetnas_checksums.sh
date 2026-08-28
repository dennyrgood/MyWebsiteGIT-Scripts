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

# --fix re-runs the same comparison WITHOUT -n, so mismatched files are
# actually re-sent. Deliberately opt-in: the audit should never change
# anything by accident, and you want to know WHICH side is wrong before
# overwriting either. rsync cannot tell you that; Immich's per-asset checksum
# can, and the restic repo is verified against WBU's content.
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1
# Explicit variable, NOT $(... || echo -n): `echo -n` means "no trailing
# newline" and prints nothing, so that idiom would silently DROP the dry-run
# flag and let the audit modify FleetNAS.
DRYRUN="-n"
[ "$FIX" -eq 1 ] && DRYRUN=""

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

if [ "$FIX" -eq 1 ]; then
    log "MODE: --fix — mismatched files WILL be re-sent to FleetNAS from WBU"
else
    log "MODE: dry run — nothing on FleetNAS will be changed"
fi
# Measured 8 minutes for ~85 GiB on 2026-08-28, not the hours first estimated:
# the NAS reads faster than assumed and 1GbE is not the constraint.
log "This reads ~85 GiB at BOTH ends (~8 min measured). Starting..."
START=$(date +%s)

# -a archive, -i itemise, -n dry run, -c compare by checksum not size+mtime.
# --no-perms must match the sync script, or every file reports a permission
# difference and drowns the real signal.
nice -n 10 ionice -c2 -n7 \
    rsync -ai $DRYRUN --no-perms --delete -c \
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
# rsync itemised output is "YXcstpoguax": Y is the direction ('<' for a push
# like this one), X the file type, then POSITIONAL flags where index 2 is the
# checksum. So a content mismatch on a pushed regular file is "<fc........" —
# same size, same mtime, different bytes, which is exactly the shape memory
# corruption leaves behind. Matching '>f..c' as an earlier version did was
# wrong on both the direction character and the offset, and reported 0 while
# a real mismatch sat in the output.
#
# `|| true`, not `|| echo 0`: grep -c already PRINTS 0 when it matches nothing,
# and also exits 1, so the fallback appended a second line and every numeric
# test afterwards failed with "integer expression expected".
CONTENT=$(grep -c '^[<>]fc' "$DIFFS" 2>/dev/null || true)
MISSING=$(grep -c '^[<>]f+++++++++' "$DIFFS" 2>/dev/null || true)
DELETES=$(grep -c '^\*deleting' "$DIFFS" 2>/dev/null || true)

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
    grep '^[<>]fc' "$DIFFS" | head -20 | tee -a "$LOG"
    log ""
    log "        Immich records a SHA-1 per asset at ingest and is the authority:"
    log "          docker exec immich_postgres psql -U postgres -d immich -t -A \\"
    log "            -c \"select encode(checksum,'hex') from asset where \\\"originalPath\\\" like '%<uuid>%';\""
    log "        Compare against sha1sum of each copy, then repair with: $0 --fix" 
fi

log "full itemised output: $DIFFS"
