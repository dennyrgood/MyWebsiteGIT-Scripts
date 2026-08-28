#!/bin/bash
# verify_immich_source_integrity.sh — verify every Immich original on disk
# against the SHA-1 Immich recorded when it ingested the file.
# Created: 2026-08-28.
#
# WHY THIS IS THE LAYER THAT WAS MISSING
#   restic verifies its own repo, Syncthing verifies what it transfers, and
#   audit_mirror_checksums.sh verifies the rsync mirrors. Every one of those
#   compares a copy against WBU's current file. None can tell you WBU's file
#   is still what it was.
#
#   That matters because restic faithfully backs up whatever it reads. If an
#   original rots on this disk, restic stores the rotten version, verifies it
#   perfectly, replicates it to Gran Canaria, and every check reports green.
#   Immich's database holds the only independent record of the original bytes.
#
# COST
#   Reads and hashes ~85 GiB from NVMe. A few minutes. Cheap enough to run
#   weekly; there is no reason to sample.

set -u

DB_CONTAINER="immich_postgres"
# Immich stores container-internal paths. This prefix maps to the host mount,
# and must match UPLOAD_LOCATION in docker-compose.yml — same mapping
# export_archive.py documents.
CONTAINER_PREFIX="/data/upload/"
HOST_PREFIX="/mnt/immich-data/immich/images/upload/"

TS=$(date -u +%Y%m%d_%H%M%SZ)
LOG_DIR="/home/dhm/.cache/immich-integrity"
LOG="$LOG_DIR/source_integrity_$TS.log"
SUMS="$LOG_DIR/expected_$TS.sha1"
FAILED="$LOG_DIR/failed_$TS.txt"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

MARKER="IMMICH SOURCE INTEGRITY OK"

die() { log "PROBLEM: $*"; log "=== source integrity check ended WITHOUT success ==="; exit 1; }

log "=== Verifying Immich originals against the database ==="

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || die "$DB_CONTAINER is not running"
mountpoint -q /mnt/immich-data || die "/mnt/immich-data is not mounted"

# Soft-deleted assets are deliberately INCLUDED: their files are still on disk
# and still get backed up, so they can still rot. Immich's checksum column is
# bytea; encode() gives the hex sha1sum expects.
log "reading checksums from Immich..."
docker exec "$DB_CONTAINER" psql -U postgres -d immich -t -A -F'|' -c \
    "select encode(checksum,'hex'), \"originalPath\" from asset where checksum is not null;" \
    > "$SUMS.raw" 2>>"$LOG" || die "could not query the database"

TOTAL=$(wc -l < "$SUMS.raw")
[ "$TOTAL" -gt 0 ] || die "database returned no rows"
log "assets with a recorded checksum: $TOTAL"

# Build a file in `sha1sum -c` format. Doing the verification with sha1sum
# itself, rather than a shell loop, means one streaming process instead of
# 70k forks.
awk -F'|' -v cp="$CONTAINER_PREFIX" -v hp="$HOST_PREFIX" '
    index($2, cp) == 1 { print $1 "  " hp substr($2, length(cp) + 1) }
' "$SUMS.raw" > "$SUMS"
MAPPED=$(wc -l < "$SUMS")
log "paths mapped to host filesystem: $MAPPED"
if [ "$MAPPED" -ne "$TOTAL" ]; then
    log "NOTE: $((TOTAL - MAPPED)) asset(s) had a path outside $CONTAINER_PREFIX and were skipped"
fi

log "hashing... (reads ~85 GiB)"
START=$(date +%s)
# --quiet prints only failures. Exit is non-zero if ANY line fails, including
# missing files, so the counts below distinguish the two cases rather than
# treating every failure as corruption.
nice -n 10 ionice -c2 -n7 sha1sum -c --quiet "$SUMS" > "$FAILED" 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
log "hashed in $((ELAPSED / 60))m $((ELAPSED % 60))s"

MISMATCH=$(grep -c ': FAILED$' "$FAILED" 2>/dev/null || true)
MISSING=$(grep -c 'No such file or directory' "$FAILED" 2>/dev/null || true)

log "--- results ---"
log "checked                  : $MAPPED"
log "CONTENT MISMATCHES       : $MISMATCH   <- corruption of the original"
log "missing from disk        : $MISSING"

if [ "$MISSING" -gt 0 ]; then
    # Immich rows can outlive their files — a deletion partially applied, or a
    # file removed outside Immich. Worth seeing, not corruption.
    log "note: missing files are DB rows without a file on disk, not damage:"
    grep 'No such file' "$FAILED" | head -5 | sed 's/^/    /' | tee -a "$LOG"
fi

if [ "$MISMATCH" -gt 0 ]; then
    log ""
    log "These files differ from what Immich recorded at ingest:"
    grep ': FAILED$' "$FAILED" | head -20 | sed 's/^/    /' | tee -a "$LOG"
    log ""
    log "The file on THIS disk is wrong. Recover it from restic, which holds"
    log "every version since 2026-08-25:"
    log "    sudo restic-wbu restore <snapshot> --include <path> --target /tmp/recover"
    log "Check older snapshots until one restores a copy whose sha1sum matches"
    log "the database — that is the last good version."
    die "$MISMATCH original(s) no longer match their recorded checksum"
fi

rm -f "$SUMS.raw"
log "$MARKER ($MAPPED files, $MISSING missing, 0 corrupt)"
