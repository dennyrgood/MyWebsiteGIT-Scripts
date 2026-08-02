#!/bin/bash
# Created: 2026-08-02 UTC — end-to-end test of the Mac Mini -> FleetNAS rsync pipeline
# (SSH key, host reachability, remote write access) using a small throwaway directory,
# before committing to the multi-TB Plex sync in backup_plex_to_fleetnas.sh. Safe to
# run repeatedly; writes under plex/_test/ on the NAS, not the real plex/ tree.
#
# DEST_RSYNC vs DEST_PATH: solved already in WorkBenchUnix/backup_immich_images_to_
# fleetnas.sh (2026-07-31) — UGOS's patched rsync rejects absolute paths as a
# destination ("invalid path: '/volume1/...'") and instead addresses destinations by
# SHARE NAME with no /volume1 prefix ("plex/_test/"). Plain ssh commands (mkdir/ls
# below) are unaffected and still need the real absolute path. Ref:
# https://www.kevinhooke.com/2025/10/19/rsync-files-to-a-ugreen-nas/
set -e

SRC="$HOME/Test_NAS/"
DEST_HOST="dhm@192.168.178.123"
SSH_KEY="$HOME/.ssh/id_ed25519_fleetnas"
SSH_TIMEOUT_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
SSH_OPTS="ssh -i $SSH_KEY $SSH_TIMEOUT_OPTS"
DEST_RSYNC="$DEST_HOST:plex/_test/"
DEST_PATH="/volume1/plex/_test"

echo "=== Test sync: $SRC -> $DEST_RSYNC ==="

ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "mkdir -p '$DEST_PATH'"

rsync -av --delete -e "$SSH_OPTS" "$SRC" "$DEST_RSYNC"

echo "=== Verifying remote contents ==="
ssh -n -i "$SSH_KEY" $SSH_TIMEOUT_OPTS "$DEST_HOST" "ls -la '$DEST_PATH'"

echo "=== Test sync complete ==="
