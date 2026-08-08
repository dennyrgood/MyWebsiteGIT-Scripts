#!/bin/bash
# Install (or reinstall) this repo's LaunchDaemons -- system-level launchd
# jobs that must run as root regardless of who's logged in (or whether
# anyone is). Sibling to ../launchagents/, which covers the opposite case:
# gui-domain agents that run as the logged-in user. upsmon needs root for
# the whole run (its SHUTDOWNCMD calls /sbin/shutdown), so it belongs here,
# not there.
#
# launchd silently refuses to load a LaunchDaemon plist unless it is owned
# by root:wheel and not group/world-writable -- get that wrong and
# `launchctl bootstrap` reports nothing wrong while the daemon just never
# starts. This script enforces ownership/permissions every run so it can't
# drift after a manual edit.
#
#   sudo ./install.sh              install/reload every daemon here
#   sudo ./install.sh --uninstall  stop and remove every daemon here

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo ./install.sh)" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="/Library/LaunchDaemons"
DOMAIN="system"

LABELS="com.dennis.mmm-nut-upsmon"

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
    chown root:wheel "$DEST/$label.plist"
    chmod 644 "$DEST/$label.plist"
    launchctl bootstrap "$DOMAIN" "$DEST/$label.plist"
    echo "installed $label"
done

[[ "${1:-}" == "--uninstall" ]] && exit 0

echo
launchctl print "$DOMAIN" | grep -B2 -A15 'com.dennis.mmm-nut-upsmon' || true
