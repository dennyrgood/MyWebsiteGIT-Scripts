#!/bin/bash
# Created: 2026-08-02 UTC — pushes the Mac Mini Plex media library to FleetNAS (plex/
# share). Runs ON mathes-mac-mini. One-way mirror, two independent sources merged under
# separate subfolders on the NAS side (sources are on different local volumes, not
# already unified). Pattern follows WorkBenchUnix/backup_immich_images_to_macmini.sh:
# dedicated SSH key, ConnectTimeout/ServerAlive guards, rsync exit code captured instead
# of allowed to kill the script under set -e (logging + continuing is what determines
# real scope of any transfer problem).
#
# DEST_RSYNC vs DEST_PATH: solved already in WorkBenchUnix/backup_immich_images_to_
# fleetnas.sh (2026-07-31), confirmed again here via test_sync_to_fleetnas.sh (2026-08-
# 02) — UGOS's patched rsync rejects absolute paths as a destination ("invalid path:
# '/volume1/...'") and instead addresses destinations by SHARE NAME with no /volume1
# prefix ("plex/MacMiniExt4g/"). Plain ssh commands (mkdir below) are unaffected and
# still need the real absolute path. Ref:
# https://www.kevinhooke.com/2025/10/19/rsync-files-to-a-ugreen-nas/
# 2026-08-05 UTC — pinned RSYNC to the full Homebrew path. First real launchd-fired
# run (as opposed to the manual nohup'd first sync) failed both sources with
# "Operation not permitted" on open() — two compounding causes: (1) launchd's minimal
# PATH has no /opt/homebrew/bin, so bare `rsync` silently resolved to Apple's bundled
# /usr/bin/rsync instead of the Homebrew 3.4.4 the manual run actually used; (2)
# whichever rsync launchd invokes is a fresh, ungranted TCC "responsible process" —
# Terminal.app's Full Disk Access grant does not carry over to a launchd-spawned
# process, so it needs its own explicit grant (System Settings -> Privacy & Security
# -> Full Disk Access -> add /opt/homebrew/bin/rsync). EPERM ("Operation not
# permitted"), not EACCES ("Permission denied"), is the TCC-denial signature. Full
# path here fixes cause (1); cause (2) has to be granted once via the GUI, can't be
# scripted.
set -e

RSYNC="/opt/homebrew/bin/rsync"
SRC1="/Volumes/MacMiniExt4g/PlexServer/"
SRC2="/Volumes/Expansion/plexServer/"
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="$HOME/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_PATH="/volume1/plex"
DEST1="$DEST_HOST:plex/MacMiniExt4g/"
DEST2="$DEST_HOST:plex/Expansion/"

LOG_DIR="$HOME/.cache/fleetnas-sync"
TS=$(date -u +%Y%m%d_%H%M%SZ)
LOG_FILE="$LOG_DIR/plex_${TS}.log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

log "=== Starting Plex sync: Mac Mini -> FleetNAS ==="

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH/MacMiniExt4g' '$DEST_PATH/Expansion'"

log "Syncing $SRC1 -> $DEST1 ..."
set +e
"$RSYNC" -a --delete -e "$SSH_OPTS" "$SRC1" "$DEST1" >>"$LOG_FILE" 2>&1
RSYNC1_EXIT=$?
set -e
if [ "$RSYNC1_EXIT" -ne 0 ]; then
    log "WARNING: rsync (source 1) exited with code $RSYNC1_EXIT. See $LOG_FILE."
fi

log "Syncing $SRC2 -> $DEST2 ..."
set +e
"$RSYNC" -a --delete -e "$SSH_OPTS" "$SRC2" "$DEST2" >>"$LOG_FILE" 2>&1
RSYNC2_EXIT=$?
set -e
if [ "$RSYNC2_EXIT" -ne 0 ]; then
    log "WARNING: rsync (source 2) exited with code $RSYNC2_EXIT. See $LOG_FILE."
fi

log "=== Plex sync to FleetNAS complete (source1 exit=$RSYNC1_EXIT, source2 exit=$RSYNC2_EXIT) ==="

# --- Cron: installed live 2026-08-03 UTC, daily at 4am (first manual run kicked off
# same day, ahead of the initial cron firing, to seed the mirror before the schedule
# takes over):
# 0 4 * * * /Users/dennishmathes/repos/scripts/MathesMacMini/backup_plex_to_fleetnas.sh >> /Users/dennishmathes/.cache/fleetnas-sync/cron.log 2>&1
