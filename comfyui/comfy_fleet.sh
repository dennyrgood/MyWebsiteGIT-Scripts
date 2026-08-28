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

python3 "$SCRIPT_DIR/comfy_fleet.py" "${PY_ARGS[@]}"
