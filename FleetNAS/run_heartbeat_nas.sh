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
# Updated: 2026-08-11 UTC — also runs nas_status_snapshot.py to merge SMART/
# RAID/UPS data into machine_info (see that script's header for why it's a
# separate step instead of being folded into heartbeat_writer_linux.py).
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

# Merge FleetNAS-specific health (SMART/RAID/UPS) into the machine_info file
# heartbeat_writer_linux.py just wrote. Same reasoning as leaving Immich stats
# out of that shared file: this is NAS-only data with no business in a file
# also used by WBU/CWHU. See nas_status_snapshot.py's header for detail.
python3 "${SCRIPT_DIR}/nas_status_snapshot.py" \
    --machine-info-file "${LOCAL_DIR}/machine_info_${HOST}.json"
