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
# 2026-08-31: comfy-fleet-http serves LOCAL_OUTPUT_DIR, NOT $OUTPUT_DIR directly.
# $OUTPUT_DIR lives inside OneDrive's live-syncing tree, and a long-running
# `python3 -m http.server` process holding that as its launchd WorkingDirectory
# was found (twice in <24h) to get its cached cwd handle invalidated by an
# OneDrive sync operation -- `ls` on the directory worked fine the whole time,
# but the server's own directory listing returned "No permission to list
# directory" for hours until manually restarted. Rather than keep auto-healing
# around that (see mb-health-monitor.sh's matching 2026-08-31 comment, which
# stays in place as a safety net), the server now points at a plain local
# directory that OneDrive never touches, refreshed from $OUTPUT_DIR at the end
# of every scan below -- same-day fresh, but immune to OneDrive's sync churn.
LOCAL_OUTPUT_DIR="$SCRIPT_DIR/fleet-output-local"

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

# Mirror the (now-pruned) output out of OneDrive to the plain local dir
# comfy-fleet-http actually serves. --delete so removed/pruned files don't
# linger in the local copy; run after pruning so the mirror reflects the same
# retention window as $OUTPUT_DIR itself.
mkdir -p "$LOCAL_OUTPUT_DIR"
rsync -a --delete "$OUTPUT_DIR/" "$LOCAL_OUTPUT_DIR/"

echo "=== $(date) -- scheduled fleet scan complete ==="
