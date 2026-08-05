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

# 2026-08-05 UTC — RESOLVED, real root cause. After the Full Disk Access fix above,
# every launchd/cron-fired run (interactive runs were unaffected) instead started
# fine and then hung indefinitely mid-transfer, eventually dying at ~300s with
# "[Receiver] io timeout" once the NAS gave up waiting. Chased this down several wrong
# paths first — UGOS server-side timeout defaults, launchd's background process
# throttling (added ProcessType=Interactive to the plist, which helped but didn't
# fully fix it), NAS-side Btrfs/RAID5 scan slowness (disproven: a local --dry-run
# scan took 0.018s) — before getting an actual kernel stack trace via `sample <pid>`
# on a stuck run: the sender was blocked inside opendir() -> open$NOCANCEL, i.e. a
# LOCAL syscall that never returned, not a network stall at all. The real cause: a
# macOS TCC "Removable Volumes" consent dialog (kTCCServiceSystemPolicyRemovableVolumes
# for /opt/homebrew/bin/rsync) was sitting unanswered on the Mac's screen — a
# GUI-session process (launchd gui/$UID OR cron; both hit this identically) can
# trigger that dialog but nothing automated can click it, so the syscall blocks
# forever until something else intervenes (here, the NAS's own 300s timeout tearing
# down the connection, which is what finally interrupts the hung syscall — the
# "Interrupted system call" errors seen throughout were the dialog's absence, not its
# cause). Fixed by clicking Allow once on the Mac's screen; confirmed via
# `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT * FROM access
# WHERE client LIKE '%rsync%'"` showing auth_value=2 (granted). This is a DIFFERENT,
# narrower grant than the Full Disk Access one above (System Policy category:
# Removable Volumes, not All Files) — both were needed.
#
# --timeout/--rsync-path below were added while chasing the wrong NAS-timeout theory
# and did NOT fix anything (confirmed via `ps` that --rsync-path's injected
# --timeout=1800 really did land in the remote command, and it still died at 300s
# regardless — proof the stall was never actually a network/protocol timeout). Left
# in as a harmless safety net against a genuine future network stall, not because
# they're doing anything today.
RSYNC_TIMEOUT=1800   # 30 min — generous headroom over the observed ~300s failure point
RSYNC="/opt/homebrew/bin/rsync"
RSYNC_PATH_REMOTE="rsync --timeout=$RSYNC_TIMEOUT"
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
"$RSYNC" -a --delete --timeout="$RSYNC_TIMEOUT" --rsync-path="$RSYNC_PATH_REMOTE" -e "$SSH_OPTS" "$SRC1" "$DEST1" >>"$LOG_FILE" 2>&1
RSYNC1_EXIT=$?
set -e
if [ "$RSYNC1_EXIT" -ne 0 ]; then
    log "WARNING: rsync (source 1) exited with code $RSYNC1_EXIT. See $LOG_FILE."
fi

log "Syncing $SRC2 -> $DEST2 ..."
set +e
"$RSYNC" -a --delete --timeout="$RSYNC_TIMEOUT" --rsync-path="$RSYNC_PATH_REMOTE" -e "$SSH_OPTS" "$SRC2" "$DEST2" >>"$LOG_FILE" 2>&1
RSYNC2_EXIT=$?
set -e
if [ "$RSYNC2_EXIT" -ne 0 ]; then
    log "WARNING: rsync (source 2) exited with code $RSYNC2_EXIT. See $LOG_FILE."
fi

log "=== Plex sync to FleetNAS complete (source1 exit=$RSYNC1_EXIT, source2 exit=$RSYNC2_EXIT) ==="

# --- Scheduling: launchd LaunchAgent, daily at 4am, via
# launchagents/com.dennis.mmm-plex-backup.plist (installed to
# ~/Library/LaunchAgents by launchagents/install.sh). Crontab is empty on this box.
# History: crontab 2026-08-03 -> launchd 2026-08-04 -> crontab again 2026-08-05
# (chasing what looked like a launchd-specific rsync timeout) -> back to launchd
# 2026-08-05 once the real cause (a TCC dialog, not the scheduler) was found — see
# the RESOLVED comment above. Kept on launchd for consistency with
# mmm-nightly-summary/mmm-health-monitor now that it isn't actually the culprit.
