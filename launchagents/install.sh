#!/bin/bash
# Install (or reinstall) the repo's LaunchAgents: copy each plist into
# ~/Library/LaunchAgents and (re)load it. Safe to re-run after editing a
# plist — it boots out the old copy first.
#
# Host-aware: which agents get installed depends on the Mac's ComputerName
# (must match its Tailscale name — see launchagents/README.md's Ollama
# section for why). Unrecognized hosts abort rather than silently
# installing everything, since the GUI/travel agents are mostly mb
# (primary) only — mb2 is fully fleet-only (heartbeat + metrics server,
# no Ollama, no search_adv/search_shows/travel/tmdb GUIs); mmm is
# fleet-only plus its own Plex/Syncthing agents and (since 2026-08-11) a
# second, independent tmdb-explorer instance for browsing directly on
# that box.
#
#   ./install.sh              install/reload this host's agents
#   ./install.sh --uninstall  stop and remove this host's agents
#   ./install.sh --all        install/reload every plist regardless of host (rare; debugging)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

FLEET_ONLY="com.dennis.heartbeat-writer com.dennis.fleet-metrics-server"
# Mac Mini-specific: FleetNAS Plex backup + its nightly report + the Plex/Syncthing
# health monitor. None of these apply to mb2 (no Plex/Syncthing there), so they're a
# separate list rather than folded into FLEET_ONLY.
#
# mmm-plex-backup briefly lived as a plain crontab entry instead (2026-08-05) after
# every launchd-triggered run — StartCalendarInterval AND manual `launchctl kickstart`
# alike — died at ~300s with an rsync io-timeout, while the identical script run
# interactively from Terminal completed in 53s. Root cause turned out to be a TCC
# "Removable Volumes" consent dialog that only a GUI-session-present user can answer —
# cron isn't actually immune to this (a cron-fired attempt hung identically), it just
# hadn't hit the unanswered dialog yet in testing before the mechanism got blamed.
# Once the dialog was granted (kTCCServiceSystemPolicyRemovableVolumes for
# /opt/homebrew/bin/rsync, confirmed via TCC.db), the underlying problem was gone
# regardless of launchd vs cron — moved back to launchd for consistency with the other
# two agents. See MathesMacMini/backup_plex_to_fleetnas.sh's header for the full
# investigation.
#
# tmdb-explorer added 2026-08-11: a second, independent instance for browsing
# directly on mmm, separate from the live one on mb (different host, same port,
# no conflict). Same plist as mb's — see launchagents/README.md.
MMM_ONLY="$FLEET_ONLY com.dennis.mmm-plex-backup com.dennis.mmm-nightly-summary com.dennis.mmm-health-monitor com.dennis.tmdb-explorer"
ALL_AGENTS="com.dennis.search-adv-web com.dennis.search-shows-web com.dennis.travel-http com.dennis.comfy-fleet-http com.dennis.comfy-fleet-scan $MMM_ONLY"

RAW_HOST="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
# Normalize: strip apostrophes (straight ' and curly macOS default '),
# lowercase, spaces -> hyphens. Not every Mac has been renamed to match its
# Tailscale name exactly (e.g. mmm's ComputerName is "Mathes Mac mini", not
# "mathes-mac-mini", and mb's default ComputerName is "Dennis's MacBook
# Air" with a curly apostrophe that a plain space/case normalization
# doesn't remove) — match on the normalized form instead of requiring an
# exact rename everywhere.
HOST="$(echo "$RAW_HOST" | sed "s/['’]//g" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
case "$HOST" in
    denniss-macbook-air)
        LABELS="$ALL_AGENTS" ;;
    denniss-2nd-macbook-air)
        LABELS="$FLEET_ONLY" ;;
    mathes-mac-mini)
        LABELS="$MMM_ONLY" ;;
    *)
        if [[ "${1:-}" == "--all" ]]; then
            LABELS="$ALL_AGENTS"
        else
            echo "error: unrecognized host '$RAW_HOST' (normalized: '$HOST') — add it to the case statement in install.sh" >&2
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
