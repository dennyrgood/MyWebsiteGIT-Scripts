#!/bin/bash
# Created: 2026-07-02 UTC
# Copies WBU's live rebuild/recovery files into the fleet-configs repo snapshot.
# Manual-run only — review `git diff` and commit yourself after running.

set -e
DEST=~/repos/fleet-configs/WorkBenchUnix

cp -p /etc/fstab "$DEST/fstab.txt"
cp -p ~/immich-app/docker-compose.yml "$DEST/docker-compose.yml"
cp -p ~/immich-app/hwaccel.ml.yml "$DEST/hwaccel.ml.yml"
cp -p ~/immich-app/.env "$DEST/.env"
crontab -l > "$DEST/crontab-l-dhm.txt"
sudo crontab -l > "$DEST/crontab-l-root.txt"

# NUT client (UPS clean-shutdown, added 2026-08-04). upsmon.conf is captured IN FULL,
# password included: it holds the credential for the `upsmon` account on this box's
# own upsd — WBU is the NUT master, the UPS is attached here (MONITOR ups2@localhost
# ... master). A redacted copy would not rebuild the box. That is only acceptable
# because fleet-configs is private — do not copy this file into the scripts repo,
# which is not. Mode 600 in the repo to match /etc/nut's 640 root:nut.
#
# 2026-08-04 UTC: corrected — this comment previously said "the `nut` account on
# FleetNAS". The NAS is not the NUT server and there is no `nut` account; upsd runs
# locally here and the account is `upsmon`.
#
# upssched.conf and upssched-cmd are deliberately NOT copied: they carry no secrets
# and are version-controlled in the scripts repo as WorkBenchUnix/nut-upssched.conf
# and nut-upssched-cmd.sh — same rule as fleet_metrics_server below.
sudo install -o "$(id -un)" -g "$(id -gn)" -m 600 /etc/nut/upsmon.conf "$DEST/nut-upsmon.conf"
sudo install -o "$(id -un)" -g "$(id -gn)" -m 644 /etc/nut/nut.conf    "$DEST/nut-nut.conf"
systemctl is-enabled nut-monitor > "$DEST/nut-monitor.enabled.txt" 2>&1 || true

# Fleet metrics server (systemd). Unit + writer + fleet_metrics_server.py are all
# version-controlled in the scripts repo (Status/), and the writer's cron line is
# captured above — so nothing new to copy. We only record that the server is a
# systemd service and whether it's enabled, so the rebuild knows to install it:
#   sudo cp ~/repos/scripts/Status/fleet_metrics_server.service /etc/systemd/system/
#   sudo systemctl enable --now fleet_metrics_server
systemctl is-enabled fleet_metrics_server > "$DEST/fleet_metrics_server.enabled.txt" 2>&1 || true

echo "Snapshot complete. Review with: cd $DEST && git status"
