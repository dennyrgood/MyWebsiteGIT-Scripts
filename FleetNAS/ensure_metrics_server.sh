#!/bin/bash
# ensure_metrics_server.sh — keep fleet_metrics_server.py running on FleetNAS.
# Created: 2026-08-11 UTC.
#
# UGREEN's firmware update can reset systemd units the same way it resets
# root's crontab (see root-crontab's header), and it's unconfirmed whether
# this appliance even exposes systemd unit management to the user. So this
# doesn't use a systemd unit — same self-healing-via-cron approach as the
# rest of FleetNAS's monitoring: cron checks every 5 minutes whether the
# server is up and (re)starts it if not, backed by an @reboot line for the
# common case. State (the running process) doesn't need to survive a reboot
# on its own — this script is what makes it come back.
#
# Cron (root, see root-crontab):
#   @reboot            sleep 30 && /home/dhm/repos/scripts/FleetNAS/ensure_metrics_server.sh
#   */5 * * * *        /home/dhm/repos/scripts/FleetNAS/ensure_metrics_server.sh

STATUS_DIR="/home/dhm/repos/scripts/Status"
LOG_FILE="/var/log/fleet-metrics-server.log"

if ! pgrep -f "fleet_metrics_server.py" >/dev/null 2>&1; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") restarting fleet_metrics_server.py" >> "${LOG_FILE}"
    FLEET_METRICS_DIR=/home/dhm/fleet_monitor \
        nohup python3 "${STATUS_DIR}/fleet_metrics_server.py" >> "${LOG_FILE}" 2>&1 &
    disown
fi
