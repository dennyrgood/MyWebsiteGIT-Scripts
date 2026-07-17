#!/bin/bash
# Install (or reinstall) the repo's LaunchAgents: copy each plist into
# ~/Library/LaunchAgents and (re)load it. Safe to re-run after editing a
# plist — it boots out the old copy first.
#
#   ./install.sh              install/reload all agents
#   ./install.sh --uninstall  stop and remove all agents
#
# Day-to-day management (no need to re-run this script):
#   launchctl kickstart -k gui/$UID/com.dennis.search-adv-web   # restart
#   launchctl bootout gui/$UID/com.dennis.search-adv-web        # stop
#   tail -f ~/Library/Logs/search_adv_web.log                   # logs

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

mkdir -p "$DEST"

for plist in "$HERE"/*.plist; do
    label="$(basename "$plist" .plist)"
    # Boot out any loaded copy (ignore "not loaded" failures).
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true

    if [[ "${1:-}" == "--uninstall" ]]; then
        rm -f "$DEST/$label.plist"
        echo "removed   $label"
        continue
    fi

    cp "$plist" "$DEST/"
    launchctl bootstrap "$DOMAIN" "$DEST/$label.plist"
    echo "installed $label"
done

[[ "${1:-}" == "--uninstall" ]] && exit 0

echo
launchctl list | grep -E 'com\.dennis\.' || true
