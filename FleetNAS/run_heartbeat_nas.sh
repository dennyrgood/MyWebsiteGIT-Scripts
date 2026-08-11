#!/bin/bash
# run_heartbeat_nas.sh — fleet heartbeat writer for FleetNAS.
# Created: 2026-08-11 UTC — same pattern as Status/run_heartbeat.sh (WBU/CWHU),
# but no Immich API key: FleetNAS runs no Immich instance, so the writer's
# get_immich_stats() just fails fast (connection refused on :2283) and leaves
# immich_photos/immich_videos null in machine_info — harmless.
#
# HOST is FleetNAS's LAN IP, not its hostname. Unlike the rest of the fleet,
# FleetNAS is NOT on Tailscale (it's a UGREEN NAS reachable only at
# 192.168.178.123 on the home LAN) — see config.py's FleetNAS entry, which
# uses this same IP as its "tailscale_name" (field is really just "the host
# string engine.py connects with"). heartbeat_writer_linux.py names its
# output files after --host, and Status/checkers/http_heartbeat_checker.py
# requests both the URL host AND the filename from the same target_host
# string, so this HOST and config.py's check_params.target_host MUST match
# exactly, or the checker 404s looking for the wrong filename.
#
# Usage: run_heartbeat_nas.sh (no args)
# Cron target, run as root (see root-crontab) every 2 minutes.

set -euo pipefail

HOST="192.168.178.123"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$(cd "${SCRIPT_DIR}/../Status" && pwd)"
LOCAL_DIR="${FLEET_METRICS_DIR:-/home/dhm/fleet_monitor}"

python3 "${STATUS_DIR}/heartbeat_writer_linux.py" \
    --host "${HOST}" \
    --output-dir "${LOCAL_DIR}"
