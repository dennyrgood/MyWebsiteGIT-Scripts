#!/bin/bash
# mathes-mac-mini-snapshot-fleet-configs.sh
# Created: 2026-07-21
# mac-mini is a NO-REPO Mac. It cannot commit to fleet-configs, so it STAGES its
# bespoke fleet files into OneDrive/ForFleetConfigs/mathes-mac-mini/, for a repo
# machine (your MacBook Air) to collect with collect-fleet-configs-from-onedrive.sh.
#
# Unlike the repo Macs, this box's writer + metrics server are standalone copies in
# $HOME (not installed from scripts/launchagents), so we copy the actual files.
#
# Delivery: this script lives in the scripts repo (scripts/MathesMacMini/) as source
# of truth; copy it into OneDrive so this box can run it. Run manually.

set -e

# OneDrive root (personal)
OD="${ONEDRIVE:-$HOME/OneDrive}"
[ -d "$OD" ] || OD="$HOME/Library/CloudStorage/OneDrive-Personal"
[ -d "$OD" ] || { echo "OneDrive folder not found ($OD)"; exit 1; }

DEST="$OD/ForFleetConfigs/mathes-mac-mini"
mkdir -p "$DEST"

# bespoke standalone files actually used on this box
cp -p ~/onedrive_heartbeat_writer_all_macs.py "$DEST/" 2>/dev/null || echo "note: writer .py not at ~/ — adjust path"
cp -p ~/fleet_metrics_server.py               "$DEST/" 2>/dev/null || echo "note: fleet_metrics_server.py not at ~/ — adjust path"
cp -p ~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist      "$DEST/" 2>/dev/null || true
cp -p ~/Library/LaunchAgents/com.dennis.fleet-metrics-server.plist  "$DEST/" 2>/dev/null || true

launchctl list | grep -i com.dennis > "$DEST/launchctl-com-dennis.txt" || true
sw_vers                              > "$DEST/sw_vers.txt"

cat > "$DEST/README.md" <<'EOF'
# MathesMacMini — rebuild notes (NO-REPO box)

Fleet-status role: Mac writer + metrics server, run as STANDALONE copies in $HOME
(this box has no scripts-repo clone). To rebuild, place these files and load the agents:
- `~/onedrive_heartbeat_writer_all_macs.py`  (writer → ~/fleet_monitor)
- `~/fleet_metrics_server.py`                 (serves ~/fleet_monitor on :9100)
- `~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist`
- `~/Library/LaunchAgents/com.dennis.fleet-metrics-server.plist`
Then: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dennis.*.plist`
EOF

echo "Staged to $DEST"
echo "Collect it from your MacBook Air: scripts/collect-fleet-configs-from-onedrive.sh"
