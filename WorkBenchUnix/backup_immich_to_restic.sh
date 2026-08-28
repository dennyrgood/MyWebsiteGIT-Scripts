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

# After the local backup is verified, wait for Syncthing to push the new packs
# to s3g and for s3g to confirm it holds them.
#
# The wait is progress-aware rather than a flat timeout. A flat value cannot be
# right for both cases: the nightly delta settles in seconds, while importing a
# few thousand photos legitimately takes half an hour on a 2.4 MiB/s link. So
# it keeps waiting as long as the outstanding byte count is FALLING, and gives
# up early once it stops moving -- at which point more waiting achieves
# nothing. OFFSITE_WAIT_SECS is only a backstop against pathological slowness.
OFFSITE_WAIT_SECS=7200      # hard cap: 2h, and only reachable while still progressing
OFFSITE_STALL_POLLS=8       # give up after this many consecutive polls with no progress (8 x 15s = 2 min)
OFFSITE_DEVICE="2U2VAWO-KDK4BX5-2W37CAZ-FA7R7BK-TTM3X4H-74YNQCQ-5JEV6RN-OHE2PQB"
OFFSITE_NAME="s3g"
ST_FOLDER="immich-restic"
ST_CONFIG="/home/dhm/.local/state/syncthing/config.xml"

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

# ------------------------------------------------- off-site confirmation -----
# A verified LOCAL repo is only half the claim. This waits for the packs just
# written to actually reach Gran Canaria before the run reports success.
#
# Nothing needs to run on s3g for this. Syncthing computes completion from what
# the REMOTE reports holding, and the remote builds that by hashing what it
# wrote -- so "0 outstanding, 0 errors" is a statement about s3g's disk, not
# merely about what wbu transmitted.
#
# Errors FAIL the run: that is the 2026-08-26 bug, where unreadable files were
# silently excluded from the completion figure and the copy was quietly
# unrestorable. Bytes still outstanding do NOT fail it -- the backup itself is
# good, a large import legitimately takes longer than this window, and
# syncthing_offsite_status.sh owns that judgement with its backlog-age limit.
OFFSITE_STATUS="not checked"

if [ -r "$ST_CONFIG" ] && systemctl is-active --quiet syncthing@dhm; then
    ST_KEY=$(grep -oPm1 '(?<=<apikey>)[^<]+' "$ST_CONFIG" 2>/dev/null || true)
    if grep -q '<gui[^>]*tls="true"' "$ST_CONFIG"; then
        ST_URL="https://127.0.0.1:8384"; ST_CURL=(-sf -k)
    else
        ST_URL="http://127.0.0.1:8384";  ST_CURL=(-sf)
    fi

    if [ -n "${ST_KEY:-}" ]; then
        log "--- confirming the new packs reached $OFFSITE_NAME ---"

        # Force a rescan FIRST. The folder has fsWatcherDelayS=10, so seconds
        # after restic writes a new snapshot and index, Syncthing has not yet
        # noticed them -- and needBytes would read 0 because the files are
        # unknown, not because they were delivered. Without this the check
        # confirms a state that predates the backup it is meant to verify.
        curl "${ST_CURL[@]}" --max-time 20 -X POST -H "X-API-Key: $ST_KEY" \
            "$ST_URL/rest/db/scan?folder=$ST_FOLDER" -o /dev/null 2>/dev/null \
            || log "WARNING: could not trigger a rescan; falling back to the watcher"

        WAITED=0
        SETTLED=0
        STALL=0
        PREV_NEED=-1
        while :; do
            ST_JSON=$(curl "${ST_CURL[@]}" --max-time 15 -H "X-API-Key: $ST_KEY" \
                "$ST_URL/rest/db/status?folder=$ST_FOLDER" 2>/dev/null) || ST_JSON=""
            OUT=$(printf '%s' "$ST_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('state','unknown'))
print(int(d.get('errors',0)))
" 2>/dev/null) || OUT=""

            CMP=$(curl "${ST_CURL[@]}" --max-time 15 -H "X-API-Key: $ST_KEY" \
                "$ST_URL/rest/db/completion?folder=$ST_FOLDER&device=$OFFSITE_DEVICE" 2>/dev/null \
                | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(int(d.get('needBytes',0)))
print(round(d.get('completion',0),2))
" 2>/dev/null) || CMP=""

            if [ -z "$OUT" ] || [ -z "$CMP" ]; then
                OFFSITE_STATUS="unverified (syncthing API unreadable)"
                log "WARNING: could not query Syncthing — off-site state unconfirmed"
                break
            fi

            FSTATE=$(echo "$OUT" | sed -n 1p)
            ERRS=$(echo "$OUT" | sed -n 2p)
            REMOTE_NEED=$(echo "$CMP" | sed -n 1p)
            PCT_S=$(echo "$CMP" | sed -n 2p)

            [ "$ERRS" -eq 0 ] || die "off-site folder reports $ERRS error(s) — s3g copy is INCOMPLETE despite any completion figure"

            # Require the folder idle AND the remote needing nothing, on two
            # consecutive polls. A single reading taken between the rescan
            # finishing and the transfer starting is indistinguishable from
            # genuinely being up to date.
            if [ "$FSTATE" = "idle" ] && [ "$REMOTE_NEED" -eq 0 ]; then
                SETTLED=$((SETTLED + 1))
                if [ "$SETTLED" -ge 2 ]; then
                    OFFSITE_STATUS="confirmed at $OFFSITE_NAME (100%, 0 errors, ${WAITED}s)"
                    log "off-site copy confirmed: $OFFSITE_NAME holds every pack, 0 errors (waited ${WAITED}s)"
                    break
                fi
            else
                SETTLED=0
            fi

            # Progress tracking: falling byte count resets the stall counter.
            if [ "$PREV_NEED" -ge 0 ] && [ "$REMOTE_NEED" -ge "$PREV_NEED" ]; then
                STALL=$((STALL + 1))
            else
                STALL=0
            fi
            PREV_NEED="$REMOTE_NEED"

            NEED_GB=$(awk -v b="$REMOTE_NEED" 'BEGIN{printf "%.2f", b/1073741824}')

            if [ "$REMOTE_NEED" -gt 0 ] && [ "$STALL" -ge "$OFFSITE_STALL_POLLS" ]; then
                OFFSITE_STATUS="STALLED (${PCT_S}%, ${NEED_GB}GiB outstanding)"
                log "off-site transfer is not progressing: ${PCT_S}%, ${NEED_GB}GiB outstanding after ${WAITED}s — no movement for $((STALL * 15))s"
                log "backup itself is good; syncthing_offsite_status.sh will judge this against the backlog limit"
                break
            fi

            if [ "$WAITED" -ge "$OFFSITE_WAIT_SECS" ]; then
                OFFSITE_STATUS="still syncing (${PCT_S}%, ${NEED_GB}GiB outstanding)"
                log "off-site still catching up at the ${OFFSITE_WAIT_SECS}s cap: ${PCT_S}%, ${NEED_GB}GiB outstanding (not a failure)"
                break
            fi
            sleep 15
            WAITED=$((WAITED + 15))
        done
    fi
else
    log "WARNING: syncthing not running or config unreadable — off-site state unconfirmed"
    OFFSITE_STATUS="unverified (syncthing not running)"
fi

# ----------------------------------------------------------------- report ---
SNAP_COUNT=$(restic -r "$REPO" snapshots --tag immich --json 2>/dev/null | grep -o '"time"' | wc -l)
REPO_SIZE=$(du -sh "$REPO" 2>/dev/null | awk '{print $1}')

log "snapshots retained: $SNAP_COUNT   repo size on disk: $REPO_SIZE   off-site: $OFFSITE_STATUS"
log "$SUCCESS_MARKER"
exit 0
