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
# 2026-08-08: added the NUT/upsmon LaunchDaemon + its live config. The plist itself is
# already version-controlled (scripts repo, launchdaemons/) and needs no copy here, same
# reasoning as the LaunchAgents above - but /opt/homebrew/etc/nut/upsmon.conf is NOT: it
# holds the NAS monitoring password in plaintext (root:wheel, mode 600), so it can only
# go in fleet-configs (private), never the scripts repo, matching how WBU's upsmon.conf/
# upsd.users are handled. That's a `sudo cat`, so this snapshot is no longer sudo-free -
# expect a password prompt.
#
# Manual-run; review `git diff` and commit yourself after.

set -e
DEST=~/repos/fleet-configs/MathesMacMini
mkdir -p "$DEST"

launchctl list | grep -i com.dennis             > "$DEST/launchctl-com-dennis.txt" || true
ls -1 ~/Library/LaunchAgents/com.dennis.*.plist > "$DEST/installed-launchagents.txt" 2>/dev/null || true
command -v brew >/dev/null 2>&1 && brew leaves  > "$DEST/brew-leaves.txt" || true
sw_vers                                         > "$DEST/sw_vers.txt"

# System-domain (root) LaunchDaemons don't show up in a plain `launchctl list` the way
# gui-domain LaunchAgents do above - that only lists the caller's own domain. `sudo`
# needed for the same reason the config capture below needs it.
ls -1 /Library/LaunchDaemons/com.dennis.*.plist   > "$DEST/installed-launchdaemons.txt" 2>/dev/null || true
sudo launchctl print system/com.dennis.mmm-nut-upsmon > "$DEST/launchctl-print-nut-upsmon.txt" 2>&1 || true

# Live upsmon.conf, credential included - restrict permissions on the copy too, defense
# in depth even though fleet-configs is private.
if sudo cat /opt/homebrew/etc/nut/upsmon.conf > "$DEST/nut-upsmon.conf" 2>/dev/null; then
    chmod 600 "$DEST/nut-upsmon.conf"
else
    echo "(could not read /opt/homebrew/etc/nut/upsmon.conf - run this snapshot as a user who can sudo)" > "$DEST/nut-upsmon.conf"
fi

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
4. NUT/UPS client: `brew install nut`, restore `nut-upsmon.conf` (this dir) to
   `/opt/homebrew/etc/nut/upsmon.conf` (`sudo chown root:wheel`, `chmod 600`),
   then `cd ~/repos/scripts/launchdaemons && sudo ./install.sh`. See the
   UPS/NUT setup guide, Section 7, for the why.

Captured here: live `launchctl` state (gui + system domains), installed
LaunchAgent/LaunchDaemon lists, `brew leaves`, `sw_vers`, and the live NUT
upsmon.conf (credential included - this dir is private, do not move it).
EOF

echo "Snapshot complete. Review: cd $DEST && git status"
