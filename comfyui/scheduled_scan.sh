#!/bin/bash
# scheduled_scan.sh
# Wrapper for the launchd-triggered daily fleet scan. Not meant to be run
# interactively -- use comfy_fleet.sh directly for that. This wrapper adds
# the housekeeping steps that only make sense for an unattended, recurring
# run: stable "latest" copies (so the served directory always has one
# obvious file to open) and automatic pruning of old timestamped output
# (so fleet-output/ doesn't grow forever, the way it did across one day's
# interactive session).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORTS_DIR="$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports"
OUTPUT_DIR="$REPORTS_DIR/fleet-output"

echo "=== $(date) -- scheduled fleet scan starting ==="

"$SCRIPT_DIR/comfy_fleet.sh"

# Stable-named copies of the newest report + explorer, so a bookmark/tile
# always points at something current without picking a timestamp.
latest_report=$(ls -t "$OUTPUT_DIR"/fleet_report_*.html 2>/dev/null | head -1)
latest_explorer=$(ls -t "$OUTPUT_DIR"/fleet_explorer_*.html 2>/dev/null | head -1)
[ -n "$latest_report" ] && cp "$latest_report" "$OUTPUT_DIR/fleet_report_latest.html"
[ -n "$latest_explorer" ] && cp "$latest_explorer" "$OUTPUT_DIR/fleet_explorer_latest.html"

# Keep the last 3 runs' worth of timestamped files (inputs, fleet-output,
# history) -- same retention already used interactively this session.
# 2026-08-30: pinned to the Homebrew interpreter explicitly -- under launchd's
# minimal PATH, bare `python3` resolves to Apple's system Python (/usr/bin/python3,
# 3.9.6), which predates PEP 604's `str | None` syntax (added in 3.10) that
# comfy_fleet.py's own type hints use. Ran fine interactively (Homebrew's 3.14.7
# is first on an interactive shell's PATH) but crashed every night under launchd
# with "TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'".
/opt/homebrew/bin/python3 "$SCRIPT_DIR/comfy_fleet.py" --config "$REPORTS_DIR/fleet_config.json" --prune-output --confirm-prune --keep-runs 3

echo "=== $(date) -- scheduled fleet scan complete ==="
