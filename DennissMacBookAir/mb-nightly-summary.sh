#!/bin/bash
# Created: 2026-08-30 UTC — daily health summary email for denniss-macbook-air (mb),
# modeled on MathesMacMini/nightly_summary.sh but scoped to what actually runs on
# THIS box. No UPS/Plex/Syncthing sections — none of that runs here. The one
# scheduled (non-KeepAlive) job on this box, comfy-fleet-scan (daily 05:00), gets
# its own freshness check here, the same role mmm's nightly script gives the Plex
# sync log — mb-health-monitor.sh deliberately excludes it since a once-daily
# StartCalendarInterval job is "missing" 23:55 hours a day by design.
#
# Sends via msmtp (iCloud SMTP, ~/.msmtprc) — see the mmm/WBU runbooks under
# WorkBenchUnix/RUNBOOK_msmtp-credential-rotation.md for credential setup/rotation.
# Run via launchd, which gets a minimal PATH, so msmtp is called by full Homebrew
# path throughout.

MSMTP="/opt/homebrew/bin/msmtp"
TO="dennyrgood@yahoo.com"
HOST="denniss-macbook-air"
LINES=10
MONITOR_STATE="/tmp/denniss-macbook-air-monitor-state.tmp"
# 2026-09-04: briefly padded to 43200s (12h) after the identical bug surfaced on mb2
# (StartInterval launchd jobs don't fire/catch up during sleep, so a normal overnight
# sleep alone falsely flagged mb-health-monitor as stale). Reverted to a tight-ish
# threshold on the understanding that mb, like mb2, is always on AC power with the lid
# never closed and should also get `sudo pmset -a sleep 0 standby 0 powernap 0` run on
# it directly (that command was run on mb2 as part of this fix — confirm/run it on mb
# too if not already done). Padded a bit past the 5-min run interval to absorb ordinary
# scheduling jitter, not to ride out sleep.
MONITOR_STALE_SECS=1800   # 30 min (6x the 5-min run interval)

SCAN_LOG="$HOME/Library/Logs/comfy_fleet_scan.log"
SCAN_STALE_SECS=115200   # 32h — scan fires 05:00, nightly summary runs a few hours
                         # later at 07:00; padded well past 24h so a single missed
                         # day doesn't look identical to two missed days, matching
                         # mmm's reasoning for its own padded threshold.

fmt_age() {
    local secs=$1
    if   [ "$secs" -lt 3600 ];   then echo "$((secs / 60))m"
    elif [ "$secs" -lt 172800 ]; then echo "$((secs / 3600))h"
    else echo "$((secs / 86400))d"
    fi
}

# Per-service breakdown of $MONITOR_STATE for the TLDR — reads the same
# MISSING_${svc}_ACTIVE/DOWN_${svc}_ACTIVE keys mb-health-monitor.sh already writes.
svc_status() {
    local svc=$1
    local missing down
    missing=$(grep "^MISSING_${svc}_ACTIVE=" "$MONITOR_STATE" 2>/dev/null | cut -d= -f2)
    down=$(grep "^DOWN_${svc}_ACTIVE=" "$MONITOR_STATE" 2>/dev/null | cut -d= -f2)
    if [ "$missing" = "1" ]; then
        echo "⚠️ MISSING"
    elif [ "$down" = "1" ]; then
        echo "⚠️ NOT RESPONDING"
    else
        echo "✓"
    fi
}

OK=1
REASON="all healthy"
BODY=""

# --- comfy-fleet-scan freshness ---
# 2026-08-30: scan log content is untrusted (it's Windows paths from remote SSH
# output, e.g. "...MathesDropBox\0ComfyUI\Work...") and gets embedded into BODY,
# which is later rendered with `echo -e` further down. A raw backslash there is
# not just cosmetic: echo -e treats "\0" as a literal NUL-byte escape, and a NUL
# mid-body silently truncates the email for most mail clients/renderers -- the
# UPS-analog section and the full state dump below never even made it out.
# Doubling backslashes here defuses that before it reaches echo -e.
BODY+="=== $SCAN_LOG ===\n"
if [ -f "$SCAN_LOG" ]; then
    BODY+="$(tail -$LINES "$SCAN_LOG" | sed 's/\\/\\\\/g')\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

SCAN_TLDR=""
if [ -f "$SCAN_LOG" ]; then
    SCAN_AGE_SECS=$(( $(date +%s) - $(stat -f %m "$SCAN_LOG") ))
    SCAN_AGE=$(fmt_age "$SCAN_AGE_SECS")
    SCAN_TLDR="  comfy-fleet-scan: [${SCAN_AGE} ago] $(tail -1 "$SCAN_LOG" | sed 's/\\/\\\\/g')"
    if [ "$OK" -eq 1 ] && [ "$SCAN_AGE_SECS" -gt "$SCAN_STALE_SECS" ]; then
        OK=0; REASON="comfy-fleet-scan log stale (${SCAN_AGE})"
        SCAN_TLDR="⚠️${SCAN_TLDR}"
    fi
else
    SCAN_TLDR="  comfy-fleet-scan: ⚠️ log not found"
    [ "$OK" -eq 1 ] && { OK=0; REASON="comfy-fleet-scan log missing — launchd may not have run it yet"; }
fi

# --- Health monitor watchdog (freshness + active alerts) in TLDR ---
TLDR="============================= TLDR ===============================\n"
TLDR+="${SCAN_TLDR}\n"
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -f %m "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        TLDR+="  mb-health-monitor: ⚠️ stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)\n"
        [ "$OK" -eq 1 ] && { OK=0; REASON="health monitor stale/missing"; }
    else
        TLDR+="  mb-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓\n"
    fi
    MONITOR_ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$MONITOR_ACTIVE" ]; then
        TLDR+="  mb-health-monitor: ⚠️ active alerts\n"
        [ "$OK" -eq 1 ] && { OK=0; REASON="active health alerts"; }
    else
        TLDR+="  mb-health-monitor: no active alerts ✓\n"
    fi
    TLDR+="    comfy-fleet-http:  $(svc_status COMFY_HTTP)\n"
    TLDR+="    metrics-server:    $(svc_status METRICS_SERVER)\n"
    TLDR+="    heartbeat-writer:  $(svc_status HEARTBEAT_WRITER)\n"
    TLDR+="    search-adv-web:    $(svc_status SEARCH_ADV)\n"
    TLDR+="    search-shows-web:  $(svc_status SEARCH_SHOWS)\n"
    TLDR+="    tmdb-explorer:     $(svc_status TMDB)\n"
    TLDR+="    travel-http:       $(svc_status TRAVEL_HTTP)\n"
else
    TLDR+="  mb-health-monitor: ⚠️ state file missing ($MONITOR_STATE)\n"
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
SUBJECT="${EMOJI} MacBook Air nightly $(date '+%Y-%m-%d') — ${REASON}"

{
    echo "Subject: $SUBJECT"
    # 2026-08-31 UTC — Cc self (dennis.mathes@icloud.com), nightly-summary only, never
    # the health-monitor alerts. That CC'd copy lands in the account's own INBOX
    # (confirmed via IMAP — iCloud doesn't auto-file SMTP-submitted mail to Sent), which
    # a separate daily digest script reads to report missing/not-ok boxes in one email.
    echo "Cc: dennis.mathes@icloud.com"
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO" dennis.mathes@icloud.com
