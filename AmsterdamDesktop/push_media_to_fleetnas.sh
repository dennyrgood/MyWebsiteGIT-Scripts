#!/bin/bash
# Created: 2026-08-04 UTC — one-time initial push of F:\Media (~1.05TB, ~727k files) from
# AmsterdamDesktop to FleetNAS's `photo_legacy` share. Run ONCE by hand, not on cron.
#
# MUST be run from inside WSL (Ubuntu), NOT from native Windows PowerShell/cmd. Confirmed
# 2026-08-04: native Windows rsync.exe (chocolatey/cygwin build) + Windows OpenSSH client
# fails every time against FleetNAS's UGOS rsync-backup wrapper — the server prints its
# normal "login group is admin, set euid as root / cannot set euid as root" warning (this
# is harmless noise; UGOS always tries and fails this elevation for gid=10/admin accounts,
# then falls through to running as the unprivileged connecting user) but the connection
# then dies instead of falling through, so 0 bytes ever transfer. The SAME warning appears
# on WSL Ubuntu, Mac Mini, and WorkBenchUnix and is harmless there — confirmed 2026-08-04
# via a small manual test.jpg push/verify/cleanup cycle from WSL against the immich share.
# The exact reason the native Windows client dies where every POSIX client (WSL, macOS,
# WorkBenchUnix) doesn't was not root-caused further — WSL was adopted as the working
# path rather than debugging the Windows client stack itself.
#
# Pattern follows MathesMacMini/backup_plex_to_fleetnas.sh and
# WorkBenchUnix/backup_immich_images_to_fleetnas.sh: dedicated SSH key,
# ConnectTimeout/ServerAlive guards, share-name destination addressing (UGOS's patched
# rsync rejects absolute /volume1/... destination paths — see the Appendix in
# WorkBenchUnix/post-1gig-switch.md for the full explanation), plain ssh for the real
# absolute path where needed.
#
# No --delete: this is a one-time additive push into what was, at creation time, an empty
# share (aside from UGOS's own auto-created `#recycle` folder, owned by root — leave it
# alone). If this script is ever re-run as a repeatable sync, decide deliberately whether
# --delete belongs, the same way the fleetnas image/db scripts do (with --max-delete as a
# guard rail), rather than adding it back reflexively.
#
# --exclude=Immich: F:\Media\Immich (populated by WorkBenchUnix/export_flat_to_
# amsterdamdesktop.sh and export_multi_to_amsterdamdesktop.sh) is out of scope for this
# push — confirmed 2026-08-04 the NAS's photo_legacy/Immich already holds this content
# (dated 2026-06-29, matching when those export scripts started populating it), and Immich
# has its own separate backup path to FleetNAS anyway (WorkBenchUnix/backup_immich_
# images_to_fleetnas.sh, targeting the immich share, not photo_legacy). A partial run on
# 2026-08-04 had already started re-copying Immich/export_flat/Archive/2001/* into
# photo_legacy/Immich before being caught and stopped — harmless (rsync without --delete
# only adds/updates matching files), but excluded going forward to avoid the wasted
# bandwidth/time on a multi-hundred-GB directory that doesn't need to move again.
set -e

SRC="/mnt/f/Media/"
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="$HOME/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_PATH="/volume1/photo_legacy"
DEST_RSYNC="$DEST_HOST:photo_legacy/"
RSYNC_EXCLUDE="--exclude=Immich"

LOG_DIR="$HOME/.cache/fleetnas-sync"
TS=$(date -u +%Y%m%d_%H%M%SZ)
LOG_FILE="$LOG_DIR/amsdt_media_initial_load_${TS}.log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting one-time media push: AmsterdamDesktop F:\\Media -> FleetNAS photo_legacy ==="

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

log "Syncing $SRC -> $DEST_RSYNC ..."
set +e
rsync -av $RSYNC_EXCLUDE -e "$SSH_OPTS" "$SRC" "$DEST_RSYNC" >>"$LOG_FILE" 2>&1
RSYNC_EXIT=$?
set -e
if [ "$RSYNC_EXIT" -ne 0 ]; then
    log "WARNING: rsync exited with code $RSYNC_EXIT (partial transfer or error). See $LOG_FILE."
fi

log "Sync complete. Verifying with a dry-run pass..."

set +e
rsync -ain $RSYNC_EXCLUDE -e "$SSH_OPTS" --out-format='%i|%n' "$SRC" "$DEST_RSYNC" 2>>"$LOG_FILE" \
    | grep -v '^\.d' > "$LOG_DIR/amsdt_media_drift_${TS}.txt"
set -e
DRIFT_COUNT=$(wc -l < "$LOG_DIR/amsdt_media_drift_${TS}.txt")

if [ "$DRIFT_COUNT" -gt 0 ]; then
    log "WARNING: $DRIFT_COUNT path(s) still differ after the sync — see $LOG_DIR/amsdt_media_drift_${TS}.txt"
else
    log "Verification complete — FleetNAS matches F:\\Media exactly (0 differences)."
fi

log "=== Media push to FleetNAS complete (rsync exit=$RSYNC_EXIT) ==="
