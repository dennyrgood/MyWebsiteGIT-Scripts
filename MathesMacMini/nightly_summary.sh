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
MONITOR_STATE="/tmp/mathes-mac-mini-monitor-state.tmp"
MONITOR_STALE_SECS=600   # 10 min — mmm-health-monitor runs every 5 min via launchd

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

    # rsync exit 24 ("vanished source files") is benign — Plex actively renaming/
    # scanning library files mid-transfer, not a real failure (confirmed 2026-08-04:
    # the very first full run hit exactly this on source1 and completed correctly).
    # Anything else non-zero is a real problem.
    COMPLETE_LINE=$(tail -5 "$PLEX_LOG" | grep "=== Plex sync to FleetNAS complete")
    S1_EXIT=$(echo "$COMPLETE_LINE" | grep -oE 'source1 exit=[0-9]+' | sed 's/.*exit=//')
    S2_EXIT=$(echo "$COMPLETE_LINE" | grep -oE 'source2 exit=[0-9]+' | sed 's/.*exit=//')
    VANISHED_COUNT=$(grep -c "file has vanished" "$PLEX_LOG" 2>/dev/null)
    VANISHED_COUNT=${VANISHED_COUNT:-0}
    if [ -z "$COMPLETE_LINE" ]; then
        OK=0; REASON="Plex sync to FleetNAS did not complete cleanly"
    elif ! [[ "$S1_EXIT" =~ ^(0|24)$ ]] || ! [[ "$S2_EXIT" =~ ^(0|24)$ ]]; then
        OK=0; REASON="Plex sync to FleetNAS did not complete cleanly (source1 exit=${S1_EXIT}, source2 exit=${S2_EXIT})"
    elif [ "$AGE_SECS" -gt "$STALE_SECS" ]; then
        OK=0; REASON="Plex sync log stale (${AGE})"
    elif [ "$VANISHED_COUNT" -gt 0 ]; then
        # Transfer succeeded (exit 0/24), but don't fold this into a bare "all
        # healthy" — files missing from the NAS copy is worth seeing even when
        # it's the benign case (Plex renamed/deleted them mid-scan). Not an
        # alarm (still ✅), just visible instead of buried in the log body.
        REASON="${VANISHED_COUNT} file(s) vanished during sync — verify if unexpected (see log below)"
    fi
else
    TLDR+="  plex_*.log: (file not found)\n"
    OK=0; REASON="Plex sync log missing — cron may not have run yet"
fi

# --- Health monitor watchdog (freshness + active alerts) in TLDR ---
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -f %m "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        TLDR+="  mmm-health-monitor: ⚠️ stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)\n"
        [ "$OK" -eq 1 ] && { OK=0; REASON="health monitor stale/missing"; }
    else
        TLDR+="  mmm-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓\n"
    fi
    MONITOR_ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$MONITOR_ACTIVE" ]; then
        TLDR+="  mmm-health-monitor: ⚠️ active alerts\n"
        [ "$OK" -eq 1 ] && { OK=0; REASON="active health alerts"; }
    else
        TLDR+="  mmm-health-monitor: no active alerts ✓\n"
    fi
else
    TLDR+="  mmm-health-monitor: ⚠️ state file missing ($MONITOR_STATE)\n"
    [ "$OK" -eq 1 ] && { OK=0; REASON="health monitor stale/missing"; }
fi

TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

# --- Health monitor state (full dump, appended at the end) ---
BODY+="=== HEALTH MONITOR STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    if [ -n "$MONITOR_ACTIVE" ]; then
        BODY+="ACTIVE ALERTS:\n$MONITOR_ACTIVE\n"
    else
        BODY+="No active alerts.\n"
    fi
    BODY+="\n$(cat "$MONITOR_STATE")\n"
else
    BODY+="⚠️ WARNING: state file not found — health monitor has not run\n"
fi

if [ "$OK" -eq 1 ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} Mac Mini nightly $(date '+%Y-%m-%d') — ${REASON}"

{
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO"
