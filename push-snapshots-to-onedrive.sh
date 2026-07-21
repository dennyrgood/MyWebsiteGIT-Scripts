#!/bin/bash
# push-snapshots-to-onedrive.sh
# Created: 2026-07-21 — run on your MacBook Air. Delivers the no-repo boxes' snapshot
# scripts (and the collector) from the scripts repo into OneDrive/ForFleetConfigs/, so
# surface3-gc / remotews / mathes-mac-mini pick up the latest versions. This is the
# inverse of collect-fleet-configs-from-onedrive.sh — run it after editing any snapshot
# script in the repo.

set -e

REPO="$(cd "$(dirname "$0")" && pwd)"   # scripts repo root (this script lives there)

OD="${ONEDRIVE:-$HOME/OneDrive}"
[ -d "$OD" ] || OD="$HOME/Library/CloudStorage/OneDrive-Personal"
[ -d "$OD" ] || { echo "OneDrive folder not found ($OD)"; exit 1; }
BASE="$OD/ForFleetConfigs"
mkdir -p "$BASE"

# collector, at the ForFleetConfigs root
cp -p "$REPO/collect-fleet-configs-from-onedrive.sh" "$BASE/"
echo "pushed: collect-fleet-configs-from-onedrive.sh"

# per-box snapshot scripts   (repo-relative path : OneDrive box subfolder)
for pair in \
    "Surface3GC/surface3-gc-snapshot-fleet-configs.ps1:surface3-gc" \
    "RemoteWS/remotews-snapshot-fleet-configs.ps1:remotews" \
    "MathesMacMini/mathes-mac-mini-snapshot-fleet-configs.sh:mathes-mac-mini"; do
    rel="${pair%%:*}"
    box="${pair##*:}"
    if [ ! -f "$REPO/$rel" ]; then echo "MISSING in repo: $rel"; continue; fi
    mkdir -p "$BASE/$box"
    cp -p "$REPO/$rel" "$BASE/$box/"
    echo "pushed: $rel -> ForFleetConfigs/$box/"
done

echo
echo "Delivered to $BASE"
