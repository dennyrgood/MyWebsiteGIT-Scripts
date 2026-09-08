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

# NUT client (UPS clean-shutdown, added 2026-09-08). Mirrors what
# WorkBenchUnix/wbu-snapshot-fleet-configs.sh captures on the server side.
#
# upsmon.conf is captured IN FULL, password included: it holds the `monslave`
# credential for ups2 on WorkBenchUnix, and a redacted copy would not rebuild the box.
# Only acceptable because fleet-configs is private — do NOT copy it into the scripts
# repo, which is not. Mode 600 here to match /etc/nut's 640 root:nut.
sudo install -o "$(id -un)" -g "$(id -gn)" -m 600 /etc/nut/upsmon.conf "$DEST/nut-upsmon.conf"
sudo install -o "$(id -un)" -g "$(id -gn)" -m 644 /etc/nut/nut.conf    "$DEST/nut-nut.conf"
systemctl is-enabled nut-monitor > "$DEST/nut-monitor.enabled.txt" 2>&1 || true

# authorized_keys. Not a secret (public halves only), but losing it costs more than it
# looks: it carries the forced-command entry that lets ChatWorkhorse run
# clean.ubuntu.shutdown on this VM during an outage. Without that, CWH falls back to a
# bare ACPI power button, which is not a clean stop for Postgres in Docker.
#
# Added after that exact key was accidentally deleted on 2026-09-08 while editing this
# file by hand; it was only recoverable because ChatWorkhorse still had the public half.
cp -p ~/.ssh/authorized_keys "$DEST/ssh-authorized_keys.txt"

# upssched.conf and upssched-cmd are deliberately NOT copied: they carry no secrets and
# are version-controlled in the scripts repo as ChatWorkhorseUnix/nut-upssched.conf and
# WorkBenchUnix/nut-upssched-cmd.sh (the cmd script is shared with WBU; only the timer
# value differs, 300s here vs 1200s there).

# Fleet metrics server (systemd). Unit + writer + fleet_metrics_server.py are all
# version-controlled in the scripts repo (Status/), and the writer's cron line is
# captured above — so nothing new to copy. We only record that the server is a
# systemd service and whether it's enabled, so the rebuild knows to install it:
#   sudo cp ~/repos/scripts/Status/fleet_metrics_server.service /etc/systemd/system/
#   sudo systemctl enable --now fleet_metrics_server
systemctl is-enabled fleet_metrics_server > "$DEST/fleet_metrics_server.enabled.txt" 2>&1 || true

echo "Snapshot complete. Review with: cd $DEST && git status"
