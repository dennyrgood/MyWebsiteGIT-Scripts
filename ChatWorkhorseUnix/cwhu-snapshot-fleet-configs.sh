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
crontab -l > "$DEST/crontab-l-dhm.txt"
sudo crontab -l > "$DEST/crontab-l-root.txt"

# Fleet metrics server (systemd). Unit + writer + fleet_metrics_server.py are all
# version-controlled in the scripts repo (Status/), and the writer's cron line is
# captured above — so nothing new to copy. We only record that the server is a
# systemd service and whether it's enabled, so the rebuild knows to install it:
#   sudo cp ~/repos/scripts/Status/fleet_metrics_server.service /etc/systemd/system/
#   sudo systemctl enable --now fleet_metrics_server
systemctl is-enabled fleet_metrics_server > "$DEST/fleet_metrics_server.enabled.txt" 2>&1 || true

echo "Snapshot complete. Review with: cd $DEST && git status"
