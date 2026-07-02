#!/bin/bash
# Created: 2026-07-02 UTC
# Copies CWHU's live rebuild/recovery files into the fleet-configs repo snapshot.
# Manual-run only — review `git diff` and commit yourself after running.

set -e
DEST=~/repos/fleet-configs/ChatWorkhorseUnix

cp -p /etc/fstab "$DEST/fstab.txt"
cp -p ~/immich-app/docker-compose.yml "$DEST/docker-compose.yml"
cp -p ~/immich-app/hwaccel.ml.yml "$DEST/hwaccel.ml.yml"
cp -p ~/immich-app/.env "$DEST/.env"
crontab -l > "$DEST/crontab-l.txt"

echo "Snapshot complete. Review with: cd $DEST && git status"
