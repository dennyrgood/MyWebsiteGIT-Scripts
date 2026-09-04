#!/bin/bash
# =============================================================
#  remote_scan.sh
#  SSH into each fleet Windows machine (via Tailscale), run the three
#  scan PS1 scripts directly (no .bat/pause), then optionally run
#  comfy_fleet.py analysis. Results land in the shared OneDrive
#  comfy-reports folder as before -- this only automates step 1.
#
#  Usage:
#    ./remote_scan.sh                 # scan all 3 machines, then analyze
#    ./remote_scan.sh ib               # scan just ImageBeast
#    ./remote_scan.sh --no-analyze     # scan all, skip comfy_fleet.py
#    ./remote_scan.sh ib tb            # scan a subset
#
#  Aliases: ib=imagebeast, cwh=chatworkhorse, tb=travelbeast
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NO_ANALYZE=false
HOSTS=()

for arg in "$@"; do
  case "$arg" in
    --no-analyze) NO_ANALYZE=true ;;
    ib|imagebeast)      HOSTS+=("imagebeast") ;;
    cwh|chatworkhorse)  HOSTS+=("chatworkhorse") ;;
    tb|travelbeast)     HOSTS+=("travelbeast") ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done
if [ ${#HOSTS[@]} -eq 0 ]; then
  HOSTS=(imagebeast chatworkhorse travelbeast)
fi

# --- Topology cross-check against fleet_config.json ---------------------------
# The Windows-side paths below duplicate fields that already exist in
# fleet_config.json (comfy_root / models_root|models_bare / png_dir). They are
# NOT read from it deliberately: this script's ssh+PowerShell invocation is
# quoting-sensitive (see the one-line -Command rule in readme.MD), and rewriting
# it to interpolate config values is a real risk to the one path that captures
# all fleet data.
#
# What IS worth catching is the silent half of that duplication: adding a
# machine to fleet_config.json and forgetting to add a case entry here, so it
# never gets scanned and nothing ever says so. This check makes that loud.
CONFIG_JSON="$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports/fleet_config.json"
if [ -f "$CONFIG_JSON" ]; then
  for cfg_host in $(/opt/homebrew/bin/python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
print(" ".join(m.get("tailscale_host", h.lower()) for h,m in c.get("machines",{}).items()))
' "$CONFIG_JSON" 2>/dev/null); do
    if ! grep -qE "^[[:space:]]*${cfg_host}\)" "$0"; then
      echo "WARNING: '${cfg_host}' is in fleet_config.json but has no case entry in $(basename "$0") --" >&2
      echo "         it will never be scanned, and its inputs will never appear in the reports." >&2
    fi
  done
fi

scan_host() {
  local host="$1"
  local comfy scripts models wfdir pngdir primedir output

  case "$host" in
    imagebeast)
      comfy='C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI'
      models='C:\ComfyUI_Models\models'
      pngdir='C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\output'
      primedir='C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\workflows\000 Starting Images'
      output='C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\Work\comfy-reports'
      ;;
    chatworkhorse)
      comfy='C:\ComfyUI_windows_portable\ComfyUI'
      models='C:\Users\pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\Models_bare'
      pngdir='C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\output'
      primedir='C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\workflows\000 Starting Images'
      output='C:\Users\pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\Work\comfy-reports'
      ;;
    travelbeast)
      comfy='C:\ComfyUI-Easy-Install\ComfyUI'
      models='C:\Users\DrDen\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\Models_bare'
      pngdir='C:\Users\DrDen\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\output'
      primedir='C:\Users\DrDen\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\workflows\000 Starting Images'
      output='C:\Users\DrDen\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\Work\comfy-reports'
      ;;
    *)
      echo "No config for host: $host" >&2; return 1 ;;
  esac
  scripts='C:\repos\scripts\comfyui'
  wfdir="${comfy}\\user\\default\\workflows"

  echo ""
  echo "============================================="
  echo "  Scanning $host"
  echo "============================================="

  # shellcheck disable=SC2087
  # Kept as one line (no embedded newlines) -- the Windows OpenSSH server
  # runs exec commands through cmd.exe, which mis-splits a multi-line
  # -Command string into separate invocations.
  ssh "$host" powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[1/3] Scanning custom nodes...'; & '$scripts\Get-CustomNodes.ps1' '$comfy' -OutputDir '$output'; Write-Host '[2/3] Scanning models...'; & '$scripts\Get-Models.ps1' -ModelsPath '$models' -OutputDir '$output'; Write-Host '[3/3] Mapping workflows to models...'; & '$scripts\Get-WorkflowModelMap.ps1' -ModelsPath '$models' -WorkflowDir '$wfdir' -PngDir '$pngdir' -StartingPrimesDir '$primedir' -OutputDir '$output'"
  echo "  Done: $host"
}

for h in "${HOSTS[@]}"; do
  scan_host "$h"
done

if [ "$NO_ANALYZE" = false ]; then
  echo ""
  echo "============================================="
  echo "  Running analysis"
  echo "============================================="
  # Call comfy_fleet.py directly (not comfy_fleet.sh) -- comfy_fleet.sh calls
  # this script by default, and going back through it here would loop.
  REPORTS_DIR="$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports"
  ( cd "$REPORTS_DIR" && /opt/homebrew/bin/python3 "$SCRIPT_DIR/comfy_fleet.py" )
fi
