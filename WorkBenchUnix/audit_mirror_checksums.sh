#!/bin/bash
# audit_mirror_checksums.sh — content audit of an Immich mirror.
#
#   audit_mirror_checksums.sh fleetnas|macmini [--fix]
#
# Created: 2026-08-28. Renamed from audit_fleetnas_checksums.sh when the Mac
# Mini needed the same treatment: the two destinations differ in four
# variables, and the interesting logic — rsync's itemise flags and which side
# to trust — is fiddly enough that having one copy of it matters more than
# matching the per-destination style of the backup scripts.
#
# WHY
#   Between roughly 2026-06 and 2026-08-25, WBU ran four mismatched DIMMs that
#   corrupted data in flight (see OFFSITE_BACKUP.md, "The RAM fault"). Both
#   mirrors ran throughout with --delete. rsync compares SIZE and MTIME, not
#   content, so a corrupted byte propagated silently and the nightly
#   verification still reported "0 differences".
#
#   Confirmed on 2026-08-28: one file of 140,752 differed between WBU and
#   FleetNAS with identical size and mtime. Immich's ingest checksum matched
#   WBU, so FleetNAS held the damaged copy. No ordinary sync would ever have
#   repaired it.
#
# SAFETY
#   Dry run unless --fix is given. Nothing at the destination is written,
#   moved or deleted without it.

set -u

TARGET="${1:-}"
FIX=0
[ "${2:-}" = "--fix" ] && FIX=1
# Explicit variable, NOT $(... || echo -n): `echo -n` means "no trailing
# newline" and prints nothing, so that idiom would silently DROP the dry-run
# flag and let the audit modify the destination.
DRYRUN="-n"
[ "$FIX" -eq 1 ] && DRYRUN=""

SRC="/mnt/immich-data/immich/images/"

case "$TARGET" in
    fleetnas)
        DEST_HOST="dhm@192.168.178.123"
        SSH_KEY="/home/dhm/.ssh/id_ed25519_fleetnas"
        # UGOS ships a patched rsync whose server side rejects absolute paths,
        # so the destination stays relative — matching
        # backup_immich_images_to_fleetnas.sh. The real filesystem path is
        # /volume1/immich/images, which is what you need for a manual sha1sum
        # over ssh; the ssh login dir is /home/dhm, not /volume1.
        DEST="$DEST_HOST:immich/images/"
        REMOTE_PATH="/volume1/immich/images"
        # That sync uses --no-perms; the audit must match or every file
        # reports a permission difference and drowns the real signal.
        PERM_OPT="--no-perms"
        CADENCE="daily 05:20"
        ;;
    macmini)
        DEST_HOST="dennishmathes@mathes-mac-mini"
        SSH_KEY="/home/dhm/.ssh/id_ed25519_macmini"
        REMOTE_PATH="/Volumes/Expansion/Immich/backup/images"
        DEST="$DEST_HOST:$REMOTE_PATH/"
        # backup_immich_images_to_macmini.sh uses a plain `rsync -aq --delete`
        # with no --no-perms, so permissions are already in sync and the audit
        # must NOT pass it either.
        PERM_OPT=""
        # Weekly, so expect files added since Friday to show as missing at the
        # destination. Those are not corruption — only the content-mismatch
        # count is.
        CADENCE="weekly, Fri 05:05"
        ;;
    *)
        echo "usage: $(basename "$0") fleetnas|macmini [--fix]"
        exit 2
        ;;
esac

SSH_OPTS="ssh -i $SSH_KEY -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

TS=$(date -u +%Y%m%d_%H%M%SZ)
LOG_DIR="/home/dhm/.cache/mirror-audit"
LOG="$LOG_DIR/${TARGET}_audit_$TS.log"
DIFFS="$LOG_DIR/${TARGET}_diffs_$TS.txt"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

log "=== $TARGET content audit (checksum) ==="
log "source: $SRC"
log "dest:   $DEST   (sync cadence: $CADENCE)"

[ -d "$SRC" ] || { log "FAILED: $SRC missing"; exit 1; }
[ -r "$SSH_KEY" ] || { log "FAILED: cannot read $SSH_KEY"; exit 1; }
mountpoint -q /mnt/immich-data || { log "FAILED: /mnt/immich-data not mounted"; exit 1; }

# The destination directory must exist and be non-empty. An unmounted external
# drive presents as an empty directory, and rsync would cheerfully report every
# file as missing — or with --fix, re-send 85 GiB onto the boot disk.
REMOTE_N=$(ssh -n -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$DEST_HOST" \
    "ls -1 '$REMOTE_PATH' 2>/dev/null | head -5 | wc -l" 2>/dev/null || echo 0)
if [ "${REMOTE_N:-0}" -lt 1 ]; then
    log "FAILED: $REMOTE_PATH on $DEST_HOST is missing or empty."
    log "        If it is an external drive, it is probably not mounted. Refusing to continue."
    exit 1
fi
log "remote path present and non-empty"

if [ "$FIX" -eq 1 ]; then
    log "MODE: --fix — mismatched files WILL be re-sent from WBU"
else
    log "MODE: dry run — nothing at the destination will be changed"
fi
# Measured 8 minutes for ~85 GiB to FleetNAS on 2026-08-28. The Mac Mini holds
# the full images/ tree including thumbs, so expect longer.
log "Reads the whole tree at BOTH ends. Starting..."
START=$(date +%s)

nice -n 10 ionice -c2 -n7 \
    rsync -ai $DRYRUN $PERM_OPT --delete -c \
        -e "$SSH_OPTS" --out-format='%i|%n' \
        "$SRC" "$DEST" 2>>"$LOG" > "$DIFFS"
RC=$?

ELAPSED=$(( $(date +%s) - START ))
log "rsync exit=$RC, elapsed $((ELAPSED / 60))m"
[ "$RC" -eq 0 ] || { log "FAILED: rsync error $RC — see $LOG"; exit 1; }

# rsync itemised output is "YXcstpoguax": Y is the direction ('<' for a push
# like this one), X the file type, then POSITIONAL flags with the CHECKSUM at
# index 2. A content mismatch on a pushed regular file is "<fc........" — same
# size, same mtime, different bytes, exactly the shape memory corruption
# leaves. An earlier version matched '^>f..c', wrong on both the direction
# character and the offset, and reported 0 while a real mismatch sat in the
# output.
#
# `|| true`, not `|| echo 0`: grep -c already PRINTS 0 when it matches nothing
# and also exits 1, so the fallback appended a second line and every numeric
# test afterwards failed with "integer expression expected".
TOTAL=$(wc -l < "$DIFFS")
CONTENT=$(grep -c '^[<>]fc' "$DIFFS" 2>/dev/null || true)
MISSING=$(grep -c '^[<>]f+++++++++' "$DIFFS" 2>/dev/null || true)
DELETES=$(grep -c '^\*deleting' "$DIFFS" 2>/dev/null || true)

log "--- results ---"
log "total itemised differences : $TOTAL"
log "CONTENT MISMATCHES         : $CONTENT   <- the ones that matter"
log "missing at destination     : $MISSING"
log "extra at destination       : $DELETES"

# Success marker for nightly_summary.sh. Emitted only when CONTENT is zero:
# additions and deletions since the last sync are expected, corruption is not.
SUCCESS_MARKER="MIRROR AUDIT OK"

if [ "$CONTENT" -eq 0 ] && [ "$TOTAL" -eq 0 ]; then
    log "RESULT: $TARGET matches WBU byte-for-byte. No corruption propagated."
    log "$SUCCESS_MARKER ($TARGET, 0 mismatches, 0 differences)"
elif [ "$CONTENT" -eq 0 ]; then
    log "RESULT: no content mismatches. The $TOTAL difference(s) are additions or"
    log "        deletions since the last sync — expected given a $CADENCE cadence."
    log "$SUCCESS_MARKER ($TARGET, 0 mismatches, $TOTAL benign differences)"
else
    log "RESULT: $CONTENT FILE(S) DIFFER IN CONTENT between WBU and $TARGET."
    log "        Same size and mtime, different bytes."
    grep '^[<>]fc' "$DIFFS" | head -20 | tee -a "$LOG"
    log ""
    log "        Which copy is right? rsync cannot tell you, and a plain sync"
    log "        would overwrite one side arbitrarily. Immich records a SHA-1"
    log "        per asset at ingest and is the authority:"
    log "          docker exec immich_postgres psql -U postgres -d immich -t -A \\"
    log "            -c \"select encode(checksum,'hex') from asset"
    log "                 where \\\"originalPath\\\" like '%<uuid>%';\""
    log "        Compare with sha1sum of each copy. On 2026-08-28 that showed"
    log "        WBU correct and the mirror damaged, which is the expected"
    log "        direction: corruption happened in WBU's memory in transit,"
    log "        not on disk. Repair with: $0 $TARGET --fix"
    log "full itemised output: $DIFFS"
    # Non-zero so cron and the nightly summary both treat this as a failure.
    # The success marker is deliberately not emitted on this path.
    exit 1
fi

log "full itemised output: $DIFFS"
