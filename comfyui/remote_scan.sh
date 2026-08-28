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
  ( cd "$REPORTS_DIR" && python3 "$SCRIPT_DIR/comfy_fleet.py" )
fi
