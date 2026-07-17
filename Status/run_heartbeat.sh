#!/bin/bash
# run_heartbeat.sh — fleet heartbeat writer (Linux)
# Created: 2026-06-28 UTC — cron target for WorkBenchUnix and ChatWorkhorseUnix.
# Usage: run_heartbeat.sh <tailscale-hostname>
# Updated: 2026-06-28 UTC — pass --immich-api-key to heartbeat writer (stats endpoint requires auth)
# Updated: 2026-07-17 UTC — write to flat ~/fleet_monitor and drop the rsync-to-OneDrive push;
#                           metrics are now served over Tailscale by fleet_metrics_server.py.

set -euo pipefail

HOST="${1:?usage: run_heartbeat.sh <hostname>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="${FLEET_METRICS_DIR:-/home/dhm/fleet_monitor}"
IMMICH_API_KEY="iuCCTHgYgbSaGQ2USs1xW4rk9bfZwHvQWhsi1agIU"

python3 "${SCRIPT_DIR}/heartbeat_writer_linux.py" \
    --host "${HOST}" \
    --output-dir "${LOCAL_DIR}" \
    --immich-api-key "${IMMICH_API_KEY}"
