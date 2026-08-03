#!/bin/bash
# Created: 2026-07-31 UTC — pushes the live Immich image library from WBU to FleetNAS
# (UGREEN DXP6800 Pro, RAID 5 / Btrfs), then verifies. Runs ON WorkBenchUnix. One-way
# push, daily. FleetNAS is becoming the backup-of-record now that backup-a/b/c are all
# disabled (backup-c: USB-bridge/rcu-stall corruption, not media failure).
#
# Shape borrowed from backup_immich_images_to_macmini.sh (push from WBU to a dumb file
# store), NOT from CWHU's restore_from_wbu.sh. CWHU's script is a *restore*: it tears
# down a live Immich stack, wipes Postgres and replays the dump, because CWHU runs a
# warm standby it has to reconstitute. FleetNAS runs no Immich, so none of that applies.
# A pull would also have to run ON the NAS, where UGOS's overlay filesystem and
# non-user-managed cron make it far harder to maintain than a cron line here.
#
# Two things ARE borrowed from restore_from_wbu.sh, both hard-won:
#   1. Preflight health check (iowait + D-state, same signal/thresholds as
#      wbu-health-monitor.sh). On 2026-07-23 WBU's own I/O distress (RCU stalls)
#      corrupted data mid-transfer. Since this push runs --delete against the
#      backup-of-record, a distressed WBU must not get to touch it — skip the night.
#   2. ConnectTimeout/ServerAlive on every ssh/rsync, so a wedged connection fails in
#      ~25s instead of hanging until someone notices.
#
# Two deliberate improvements over the Mac Mini script:
#   1. --max-delete guard. rsync --delete faithfully propagates mass deletion, whether
#      it came from the user or from a corrupted source tree. Above the threshold the
#      run aborts rather than replaying the damage onto the backup.
#   2. Verification is a second `rsync -ain --delete` dry run instead of the Mac Mini
#      script's per-file ssh loop. That loop matched on *basename anywhere in the
#      destination tree* (so a file in the wrong directory counted as present) and cost
#      one SSH round-trip per flagged file. The dry run is path-exact, notices content
#      drift rather than mere presence, and uses a single connection.
#
# Deletions are still recoverable: FleetNAS takes scheduled Btrfs snapshots of
# /volume1/immich, which this key cannot reach. That, not the push direction, is what
# protects the backup from the source.
set -e

SRC="/mnt/immich-data/immich/images/"
# LAN address for now. Once Tailscale is installed on the NAS (see the FleetNAS
# State of the Union, Pending -> Tailscale), switch this to the Tailscale name so
# the push survives the NAS moving networks.
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="/home/dhm/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"

# TWO different ways to name the same directory on FleetNAS — do not merge them.
#
# DEST_RSYNC: UGOS ships a patched rsync whose server side rejects absolute paths
# outright ("invalid path: '/volume1/immich/images/'", and a UGREEN-added "not
# support path" string in the binary). It addresses destinations by SHARE NAME with
# no /volume1 prefix — so "immich/images/", not "/volume1/immich/images/". The share
# names only resolve once Control Panel -> File Services -> "Enable backup rsync
# service" is on with an authorized account; before that, every path is rejected and
# it looks like the share-name form is broken too. Ref:
# https://www.kevinhooke.com/2025/10/19/rsync-files-to-a-ugreen-nas/
#
# DEST_PATH: plain ssh commands (mkdir/ls/find below) are NOT affected by the patch
# and need the real absolute path.
#
# Worth knowing why it's this way and not the two obvious alternatives: rsync's
# daemon-over-ssh form (host::module) is broken in UGREEN's build — it never sends a
# server greeting — and the plain daemon on port 873 requires a password, which would
# mean storing a NAS credential in a file on WBU and sending 111GB unencrypted. The
# share-name-over-ssh form avoids both: existing key auth, no new secret, encrypted.
DEST_RSYNC="$DEST_HOST:immich/images/"
DEST_PATH="/volume1/immich/images"
DEST="$DEST_RSYNC"

# Immich deletes are a trickle in normal use; hundreds at once means either a big
# manual purge (rerun by hand once you've confirmed it was you) or a damaged source.
MAX_DELETE=500
IOWAIT_THRESHOLD=20

LOG_DIR="/home/dhm/.cache/fleetnas-sync"
TS=$(date -u +\%Y\%m\%d_\%H\%M\%SZ)
LOG_FILE="$LOG_DIR/fleetnas_images_${TS}.log"
WORK_DIR="$LOG_DIR/verify-work-images"
mkdir -p "$LOG_DIR" "$WORK_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting live image sync: WBU immich-data -> FleetNAS ==="

# 0. Preflight: is WBU healthy enough to be trusted as a source tonight? Checked
#    before anything touches the NAS, so a bad night here costs only tonight's sync.
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
    log "WBU looks like it's in I/O distress — skipping tonight's sync. FleetNAS is untouched."
    exit 0
fi

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing images (--delete, --max-delete=$MAX_DELETE)..."
set +e
# --no-perms: the UGREEN share forces mode 777 on everything it stores, so the 644 of
# the source can never be represented there. Measured on the 2026-08-03 initial load —
# all 283,460 files landed with size and mtime intact and mode 777. Asking rsync to
# preserve perms against a destination that overrides them is a request that cannot
# succeed, and it made the verification pass below flag every file in the library as
# drift. Must stay in sync with the --no-perms on the verification rsync.
rsync -aq --no-perms --delete --max-delete="$MAX_DELETE" -e "$SSH_OPTS" "$SRC" "$DEST" >/dev/null 2>>"$LOG_FILE"
RSYNC_EXIT=$?
set -e
# Exit 25 is specifically --max-delete tripping. Call that out, because unlike a
# transport error it means the sync was refused on purpose and needs a human decision.
if [ "$RSYNC_EXIT" -eq 25 ]; then
    log "ABORTED: rsync hit --max-delete=$MAX_DELETE — the source has more deletions pending than expected."
    log "Nothing was deleted on FleetNAS. Confirm the deletions are intentional, then rerun by hand with a raised --max-delete."
    exit 1
fi
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "WARNING: rsync exited with code $RSYNC_EXIT (partial transfer or error). See $LOG_FILE for rsync's stderr. Continuing to verification to determine actual scope."
fi

log "Sync complete. Verifying with a second dry-run pass..."

DRIFT_FILE="$WORK_DIR/drift.txt"
# A clean sync leaves nothing to do on a rerun. Whatever this prints is real
# remaining difference: new/changed files (>f...), or pending deletions (*deleting).
# Unchanged directories still itemize as ".d..t......" — those are noise, so drop them.
#
# --no-perms must match the sync rsync above. Without it this check was structurally
# incapable of ever passing: the 2026-08-03 initial load transferred all 283,460 files
# correctly, and every single one still itemized as ".f...p....." — leading "." meaning
# no transfer needed, "p" meaning the destination's forced 777 differs from the source's
# 644. That is a 283,460-line WARNING in cron.log every night, on a backup that is
# actually perfect, which is precisely how a real drift report gets ignored.
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
    log "Image verification complete — FleetNAS matches WBU exactly (0 differences)."
fi

SRC_COUNT=$(find "$SRC" -type f | wc -l)
log "Source file count: $SRC_COUNT"

log "=== Live image sync to FleetNAS complete ==="
