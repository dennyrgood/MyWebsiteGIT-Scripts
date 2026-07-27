#!/bin/bash
# mathes-mac-mini-snapshot-fleet-configs.sh
# Created: 2026-07-21; converted to repo-based snapshot 2026-07-28 after mmm gained
# a local repo checkout and its fleet agents were migrated from standalone $HOME
# copies to the repo-versioned launchagents/install.sh setup (fleet-only: just
# heartbeat-writer + fleet-metrics-server, no GUI/travel/tmdb agents - see
# launchagents/README.md's host-aware install.sh section).
#
# Fleet writer + metrics server + their LaunchAgent plists are now version-controlled
# in the scripts repo (Status/ and launchagents/); `launchagents/install.sh` recreates
# them, so we don't copy those - just capture live state + a rebuild pointer, same
# pattern as the other repo Macs.
#
# Manual-run; review `git diff` and commit yourself after.

set -e
DEST=~/repos/fleet-configs/MathesMacMini
mkdir -p "$DEST"

launchctl list | grep -i com.dennis             > "$DEST/launchctl-com-dennis.txt" || true
ls -1 ~/Library/LaunchAgents/com.dennis.*.plist > "$DEST/installed-launchagents.txt" 2>/dev/null || true
command -v brew >/dev/null 2>&1 && brew leaves  > "$DEST/brew-leaves.txt" || true
sw_vers                                         > "$DEST/sw_vers.txt"

cat > "$DEST/README.md" <<'EOF'
# MathesMacMini — rebuild notes

Fleet-status role: Mac writer + metrics server ONLY (fleet-only box - no
Ollama, no search_adv/search_shows/travel/tmdb GUI agents). Both version-controlled.

Rebuild:
1. Clone the `scripts` repo to `~/repos/scripts`.
2. `cd ~/repos/scripts/launchagents && ./install.sh` — host-aware, resolves
   this Mac's ComputerName ("Mathes Mac mini" -> normalized "mathes-mac-mini")
   and installs only the fleet-only pair automatically.
3. Writer/server code lives in `scripts/Status/`.

Captured here: live `launchctl` state, installed agent list, `brew leaves`, `sw_vers`.
EOF

echo "Snapshot complete. Review: cd $DEST && git status"
