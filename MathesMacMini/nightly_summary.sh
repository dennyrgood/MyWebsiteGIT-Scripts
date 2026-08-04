#!/bin/bash
# Created: 2026-08-04 UTC — daily health summary email for mathes-mac-mini, modeled on
# WorkBenchUnix/nightly_summary.sh but scoped down to what actually runs on this box:
# the Mac Mini -> FleetNAS Plex sync (backup_plex_to_fleetnas.sh). Sends via msmtp
# (iCloud SMTP, Keychain-backed password — see MathesMacMini/README or the msmtp
# runbook in WorkBenchUnix/ for setup), not WBU's account. Run via cron/launchd, which
# both get a minimal PATH, so msmtp is called by full Homebrew path throughout.
#
# Unlike WBU's report, this does NOT scan for kernel panics / unclean reboots via
# journalctl — that's Linux-specific and has no direct macOS equivalent wired up yet.
# Scope is deliberately narrow (Plex sync only) per 2026-08-04 decision; extend here
# if/when more jobs run on this box.

MSMTP="/opt/homebrew/bin/msmtp"
TO="dennyrgood@yahoo.com"
LINES=10
STALE_SECS=108000   # 30h — backup cron fires ~4am, report runs a few hours later;
                     # a healthy log is a few hours old, a missed night pushes past 24h.
                     # Padded beyond WBU's 24h since this job's steady-state runtime
                     # (large media files over RAID5) is less predictable than WBU's.

PLEX_LOG=$(ls -1t "$HOME/.cache/fleetnas-sync/plex_"*.log 2>/dev/null | head -1)
PLEX_LOG=${PLEX_LOG:-"$HOME/.cache/fleetnas-sync/plex_NONE.log"}

BODY="=== $PLEX_LOG ===\n"
if [ -f "$PLEX_LOG" ]; then
    BODY+="$(tail -$LINES "$PLEX_LOG")\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

fmt_age() {
    local secs=$1
    if   [ "$secs" -lt 3600 ];   then echo "$((secs / 60))m"
    elif [ "$secs" -lt 172800 ]; then echo "$((secs / 3600))h"
    else echo "$((secs / 86400))d"
    fi
}

OK=1
REASON="all healthy"

TLDR="============================= TLDR ===============================\n"
if [ -f "$PLEX_LOG" ]; then
    AGE_SECS=$(( $(date +%s) - $(stat -f %m "$PLEX_LOG") ))
    AGE=$(fmt_age "$AGE_SECS")
    TLDR+="  $(basename "$PLEX_LOG"): [${AGE} ago] $(tail -1 "$PLEX_LOG")\n"

    if ! tail -5 "$PLEX_LOG" | grep -q "source1 exit=0, source2 exit=0"; then
        OK=0; REASON="Plex sync to FleetNAS did not complete cleanly"
    elif [ "$AGE_SECS" -gt "$STALE_SECS" ]; then
        OK=0; REASON="Plex sync log stale (${AGE})"
    fi
else
    TLDR+="  plex_*.log: (file not found)\n"
    OK=0; REASON="Plex sync log missing — cron may not have run yet"
fi
TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

if [ "$OK" -eq 1 ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} Mac Mini nightly $(date '+%Y-%m-%d') — ${REASON}"

{
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO"
