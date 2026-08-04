#!/bin/bash
# Created: 2026-08-04 UTC — end-to-end test of the AmsterdamDesktop -> FleetNAS rsync
# pipeline (SSH key, host reachability, remote write access) using a small throwaway
# directory, before committing to the ~1.05TB push in push_media_to_fleetnas.sh. Safe to
# run repeatedly; writes under photo_legacy/_test/ on the NAS, not the real photo_legacy
# tree. Mirrors MathesMacMini/test_sync_to_fleetnas.sh.
#
# MUST be run from inside WSL (Ubuntu), NOT from native Windows PowerShell/cmd. Confirmed
# 2026-08-04: native Windows rsync.exe (chocolatey/cygwin build) + Windows OpenSSH client
# fails every time against FleetNAS's UGOS rsync-backup wrapper — the server prints its
# normal "login group is admin, set euid as root / cannot set euid as root" warning (this
# is harmless noise; UGOS always tries and fails this elevation for gid=10/admin accounts,
# then falls through to running as the unprivileged connecting user) but the connection
# then dies instead of falling through, so 0 bytes ever transfer. The SAME warning appears
# on WSL Ubuntu, Mac Mini, and WorkBenchUnix and is harmless there. WSL was adopted as the
# working path rather than debugging the Windows client stack itself.
#
# DEST_RSYNC vs DEST_PATH: solved already in WorkBenchUnix/backup_immich_images_to_
# fleetnas.sh (2026-07-31) — UGOS's patched rsync rejects absolute paths as a
# destination ("invalid path: '/volume1/...'") and instead addresses destinations by
# SHARE NAME with no /volume1 prefix ("photo_legacy/_test/"). Plain ssh commands (mkdir/ls
# below) are unaffected and still need the real absolute path. Ref:
# https://www.kevinhooke.com/2025/10/19/rsync-files-to-a-ugreen-nas/
set -e

SRC="$HOME/Test_NAS/"
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="$HOME/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_RSYNC="$DEST_HOST:photo_legacy/_test/"
DEST_PATH="/volume1/photo_legacy/_test"

# Auto-populate a tiny test file if SRC is empty/missing, so this script is runnable
# standalone without a manual setup step first.
mkdir -p "$SRC"
if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    echo "rsync test $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SRC/testfile.txt"
fi

echo "=== Test sync: $SRC -> $DEST_RSYNC ==="

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

rsync -av --delete -e "$SSH_OPTS" "$SRC" "$DEST_RSYNC"

echo "=== Verifying remote contents ==="
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "ls -la '$DEST_PATH'"

echo "=== Test sync complete ==="
