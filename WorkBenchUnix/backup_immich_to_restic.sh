#!/bin/bash
# backup_immich_to_restic.sh — nightly restic snapshot of the Immich library
# into the local repo on /mnt/immich-backup, which Syncthing then replicates
# off-site to s3g (Gran Canaria).
#
# Created: 2026-08-25.
#
# WHY THIS EXISTS
#   FleetNAS and Mac Mini already hold mirrors of the library, but they are
#   `rsync --delete` mirrors: a bad deletion or a corrupted file propagates to
#   them within 24h and the previous good state is gone. This adds the one
#   thing a mirror cannot give — point-in-time rollback — plus integrity
#   checking of what was actually stored.
#
# WHAT IS NOT BACKED UP, AND WHY
#   thumbs/ (20G) and encoded-video/ (1.9G) are derived data. Immich rebuilds
#   both from the originals. Backing them up would add ~22G to the repo and,
#   more to the point, ~22G to the initial over-the-wire seed to Gran Canaria
#   and to every prune-driven re-replication after that.
#   backups/ (8.4G) is Immich's own DB dump. postgres-dumps-latest/ already
#   holds a pg_dumpall of the whole cluster, which is strictly more complete,
#   so including both just stores the database twice.
#   Cost of these exclusions: after a full restore, Immich regenerates
#   thumbnails and transcodes for ~280k assets. That takes hours, runs
#   unattended, and touches nothing irreplaceable. Set BACKUP_DERIVED=yes
#   below to include them anyway.
#
# WHY PRUNE IS NOT NIGHTLY
#   `forget` only deletes small snapshot metadata files — cheap, and nearly
#   invisible to Syncthing. `prune` rewrites pack files, which means Syncthing
#   must re-transfer every repacked pack to Gran Canaria. On a slow link that
#   is the dominant cost of the whole design, so prune runs monthly, not
#   nightly. Space allows it: ~244G of volume for a repo expected around 90G.

set -u

# Explicit: restic packs must be readable by the syncthing daemon (runs as dhm).
# Inheriting cron's umask would silently create unreadable packs.
umask 022

# ---------------------------------------------------------------- config ----
REPO="/mnt/immich-backup/restic"
REPO_MOUNT="/mnt/immich-backup"
SRC_MOUNT="/mnt/immich-data"
export RESTIC_PASSWORD_FILE="/root/.restic-passphrase"

SRC_IMAGES="/mnt/immich-data/immich/images"
SRC_DUMPS="/mnt/immich-data/immich/postgres-dumps-latest"

BACKUP_DERIVED="no"          # yes = also back up thumbs/, encoded-video/, backups/

KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=24

PRUNE_DAY="01"               # day-of-month to run prune; empty disables prune
READ_DATA_SUBSET="1/30"      # deep-verify this fraction nightly -> full repo/month

LOG="/var/log/immich-restic.log"
LOCK="/var/lock/immich-restic.lock"

SUCCESS_MARKER="RESTIC BACKUP VERIFIED OK"
# -----------------------------------------------------------------------------

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

die() {
    log "FAILED: $*"
    log "=== restic run ended WITHOUT success ==="
    exit 1
}

exec 9>"$LOCK" || { echo "cannot open lock $LOCK"; exit 1; }
if ! flock -n 9; then
    # Not an error worth alarming about on its own, but it must not report
    # success: the initial seed takes hours and can still be running.
    log "SKIPPED: another run still holds $LOCK"
    log "=== restic run ended WITHOUT success ==="
    exit 1
fi

log "=== Starting restic backup of Immich -> $REPO ==="

# ------------------------------------------------------------- preflight ----
[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v restic >/dev/null || die "restic not on PATH"

# The repo volume must be MOUNTED. If it is not, $REPO_MOUNT is an empty dir on
# the root filesystem and restic would happily build a second repo there and
# fill /. This is the same trap backup_immich.sh guards against for backup-c.
mountpoint -q "$REPO_MOUNT" || die "$REPO_MOUNT is not mounted"
mountpoint -q "$SRC_MOUNT"  || die "$SRC_MOUNT is not mounted"
[ -d "$REPO" ] || die "$REPO does not exist"
[ -r "$RESTIC_PASSWORD_FILE" ] || die "cannot read $RESTIC_PASSWORD_FILE"
[ -d "$SRC_IMAGES" ] || die "$SRC_IMAGES missing"
[ -d "$SRC_DUMPS" ]  || die "$SRC_DUMPS missing"

restic -r "$REPO" cat config >/dev/null 2>&1 || die "cannot open repo (wrong passphrase, or repo damaged)"
log "preflight ok — repo open, both volumes mounted"

AVAIL_GB=$(df -BG --output=avail "$REPO_MOUNT" | tail -1 | tr -dc '0-9')
log "space free on $REPO_MOUNT: ${AVAIL_GB}G"
[ "$AVAIL_GB" -ge 20 ] || die "only ${AVAIL_GB}G free on $REPO_MOUNT — refusing to start"

# --------------------------------------------------------------- excludes ---
EXCLUDES=()
if [ "$BACKUP_DERIVED" != "yes" ]; then
    EXCLUDES+=(--exclude "$SRC_IMAGES/thumbs")
    EXCLUDES+=(--exclude "$SRC_IMAGES/encoded-video")
    EXCLUDES+=(--exclude "$SRC_IMAGES/backups")
    log "excluding derived data: thumbs/, encoded-video/, backups/"
else
    log "BACKUP_DERIVED=yes — including thumbs/, encoded-video/, backups/"
fi

# ----------------------------------------------------------------- backup ---
# nice/ionice so an 85G walk never starves the live Immich containers.
log "--- restic backup ---"
nice -n 10 ionice -c2 -n7 \
    restic -r "$REPO" backup \
        --tag immich \
        --host workbenchunix \
        --exclude-caches \
        "${EXCLUDES[@]}" \
        "$SRC_IMAGES" "$SRC_DUMPS" 2>&1 | tee -a "$LOG"

BACKUP_RC=${PIPESTATUS[0]}
# rc 3 = some files unreadable but the snapshot was still created. On a live
# Immich that usually means a file vanished mid-walk (an upload finishing, a
# transcode being replaced). Worth surfacing, not worth failing the run.
case "$BACKUP_RC" in
    0) log "backup completed cleanly" ;;
    3) log "WARNING: backup rc=3 — some files could not be read; snapshot still created" ;;
    *) die "restic backup failed (rc=$BACKUP_RC)" ;;
esac

# ----------------------------------------------------------------- forget ---
log "--- restic forget (keep daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY) ---"
restic -r "$REPO" forget \
    --tag immich \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "restic forget failed"

# ------------------------------------------------------------------ prune ---
TODAY=$(date +%d)
if [ -n "$PRUNE_DAY" ] && [ "$TODAY" = "$PRUNE_DAY" ]; then
    log "--- restic prune (monthly; rewrites packs, so Syncthing will re-send them) ---"
    nice -n 10 ionice -c2 -n7 restic -r "$REPO" prune 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "restic prune failed"
else
    log "prune skipped (runs on day $PRUNE_DAY of the month; today is $TODAY)"
fi

# ------------------------------------------------------- readable for sync ---
# restic's file mode cannot be relied on. `umask 022` above is set and there are
# no ACLs on the repo, yet the 2026-08-26 cron run produced 0440 root:root files
# that the syncthing daemon (running as dhm, not in group root) could not read.
# Syncthing then reported the folder 100% complete while silently omitting them
# -- errored files are excluded from its completion figure -- and the four it
# skipped were an index, a snapshot and two data packs, which is the difference
# between a stale backup and an unrestorable one.
#
# So normalise explicitly rather than depending on what restic chose. a+rX adds
# read for all and traverse on directories only, never +x on a data file. It is
# a stat+chmod over ~5k entries, well under a second, and safe to repeat.
# ignorePerms=true on the Syncthing folder means this generates no re-sync.
log "--- normalising repo permissions for the syncthing daemon ---"
chmod -R a+rX "$REPO" || die "could not normalise permissions on $REPO"
UNREADABLE=$(find "$REPO" -type f ! -perm -o+r 2>/dev/null | wc -l)
[ "$UNREADABLE" -eq 0 ] || die "$UNREADABLE repo file(s) still not world-readable — syncthing cannot replicate them"
log "all repo files readable"

# ------------------------------------------------------------------ check ---
# Structure check every night, plus a rotating slice of actual pack data
# re-hashed so the whole repo is byte-verified over a month. Reads only, so
# it creates no Syncthing traffic.
log "--- restic check (structure + read-data-subset=$READ_DATA_SUBSET) ---"
nice -n 10 ionice -c2 -n7 \
    restic -r "$REPO" check --read-data-subset="$READ_DATA_SUBSET" 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "restic check FAILED — repo integrity problem, investigate before trusting this backup"

# ----------------------------------------------------------------- report ---
SNAP_COUNT=$(restic -r "$REPO" snapshots --tag immich --json 2>/dev/null | grep -o '"time"' | wc -l)
REPO_SIZE=$(du -sh "$REPO" 2>/dev/null | awk '{print $1}')

log "snapshots retained: $SNAP_COUNT   repo size on disk: $REPO_SIZE"
log "$SUCCESS_MARKER"
exit 0
