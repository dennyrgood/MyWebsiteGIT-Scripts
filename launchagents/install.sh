#!/bin/bash
# Install (or reinstall) the repo's LaunchAgents: copy each plist into
# ~/Library/LaunchAgents and (re)load it. Safe to re-run after editing a
# plist — it boots out the old copy first.
#
# Host-aware: which agents get installed depends on the Mac's ComputerName
# (must match its Tailscale name — see launchagents/README.md's Ollama
# section for why). Unrecognized hosts abort rather than silently
# installing everything, since the GUI/travel agents are mb (primary)
# only — mb2 and mmm are fleet-only (heartbeat + metrics server, no
# Ollama, no search_adv/search_shows/travel/tmdb GUIs).
#
#   ./install.sh              install/reload this host's agents
#   ./install.sh --uninstall  stop and remove this host's agents
#   ./install.sh --all        install/reload every plist regardless of host (rare; debugging)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

FLEET_ONLY="com.dennis.heartbeat-writer com.dennis.fleet-metrics-server"
ALL_AGENTS="com.dennis.search-adv-web com.dennis.search-shows-web com.dennis.travel-http com.dennis.tmdb-explorer $FLEET_ONLY"

HOST="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
case "$HOST" in
    denniss-macbook-air)
        LABELS="$ALL_AGENTS" ;;
    denniss-2nd-macbook-air|mathes-mac-mini)
        LABELS="$FLEET_ONLY" ;;
    *)
        if [[ "${1:-}" == "--all" ]]; then
            LABELS="$ALL_AGENTS"
        else
            echo "error: unrecognized host '$HOST' — add it to the case statement in install.sh" >&2
            echo "       (or pass --all to force every agent, e.g. for debugging)" >&2
            exit 1
        fi
        ;;
esac

mkdir -p "$DEST"

for label in $LABELS; do
    plist="$HERE/$label.plist"
    if [[ ! -f "$plist" ]]; then
        echo "warning: $label.plist not found in $HERE, skipping" >&2
        continue
    fi

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
