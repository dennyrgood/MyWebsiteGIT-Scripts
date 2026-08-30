#!/bin/bash
# =============================================================
#  comfy_fleet.sh
#  One-command fleet scan + analysis.
#  Place in ~/repos/scripts/comfyui/ alongside comfy_fleet.py
#
#  Default behavior: SSH into all 3 machines (via Tailscale), run the
#  scan scripts remotely, then analyze -- the full pipeline in one call.
#
#  Usage:
#    ./comfy_fleet.sh                    # full auto: SSH-scan all 3 + analyze
#    ./comfy_fleet.sh --local-only        # skip SSH scan, analyze existing CSVs only
#    ./comfy_fleet.sh --local-only --year 2025
#    ./comfy_fleet.sh ib tb              # SSH-scan only these machines, then analyze
# =============================================================

REPORTS_DIR="$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

LOCAL_ONLY=false
PY_ARGS=()
SCAN_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --local-only) LOCAL_ONLY=true ;;
    ib|imagebeast|cwh|chatworkhorse|tb|travelbeast) SCAN_ARGS+=("$arg") ;;
    *) PY_ARGS+=("$arg") ;;
  esac
done

echo ""
echo "============================================="
echo "  ComfyUI Fleet Analysis"
echo "  Reports : $REPORTS_DIR"
echo "============================================="
echo ""

if [ "$LOCAL_ONLY" = false ]; then
  "$SCRIPT_DIR/remote_scan.sh" "${SCAN_ARGS[@]}" --no-analyze
  echo ""
fi

cd "$REPORTS_DIR" || { echo "ERROR: Could not cd to $REPORTS_DIR"; exit 1; }

# 2026-08-30: pinned to the Homebrew interpreter explicitly -- see the matching
# comment in scheduled_scan.sh. This one usually gets away with bare `python3`
# since it's normally run interactively (an interactive shell's PATH finds
# Homebrew's 3.14 first), but any non-interactive/minimal-PATH invocation (cron,
# a bare SSH command, launchd) would resolve to Apple's system Python 3.9.6
# instead and hit the same "str | None" (PEP 604, needs 3.10+) crash.
/opt/homebrew/bin/python3 "$SCRIPT_DIR/comfy_fleet.py" "${PY_ARGS[@]}"
