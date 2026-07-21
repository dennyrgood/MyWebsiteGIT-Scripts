#!/bin/bash
# collect-fleet-configs-from-onedrive.sh
# Created: 2026-07-21 — run on your MacBook Air (has OneDrive + the fleet-configs repo).
#
# The no-repo fleet boxes (surface3-gc, remotews, mathes-mac-mini) can't commit to
# fleet-configs, so their per-box snapshot scripts stage files into
# OneDrive/ForFleetConfigs/<box>/. This pulls those into the fleet-configs repo so
# you can review and commit. The snapshot scripts themselves are NOT copied (they are
# version-controlled under scripts/<Machine>/).

set -e

OD="${ONEDRIVE:-$HOME/OneDrive}"
[ -d "$OD" ] || OD="$HOME/Library/CloudStorage/OneDrive-Personal"
[ -d "$OD" ] || { echo "OneDrive folder not found ($OD)"; exit 1; }

SRC="$OD/ForFleetConfigs"
REPO=~/repos/fleet-configs
[ -d "$REPO" ] || { echo "fleet-configs repo not found at $REPO"; exit 1; }

# box (OneDrive subdir) : fleet-configs folder name
for pair in "surface3-gc:Surface3GC" "remotews:RemoteWS" "mathes-mac-mini:MathesMacMini"; do
    box="${pair%%:*}"
    dir="${pair##*:}"
    s="$SRC/$box"
    d="$REPO/$dir"
    if [ ! -d "$s" ]; then
        echo "skip $box — nothing staged in OneDrive yet"
        continue
    fi
    mkdir -p "$d"
    rsync -a --exclude '*-snapshot-fleet-configs.*' "$s"/ "$d"/
    echo "collected $box -> fleet-configs/$dir"
done

echo
echo "Review and commit: cd $REPO && git status"
