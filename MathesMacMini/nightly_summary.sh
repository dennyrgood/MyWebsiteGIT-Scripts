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
# Scope was Plex sync only per the 2026-08-04 decision; NUT/UPS was added 2026-08-08
# once this box's own upsmon client was verified end to end. Extend here if/when more
# jobs run on this box.
#
# 2026-08-30: TMDB Explorer and the fleet-status pair (HEARTBEAT_WRITER,
# METRICS_SERVER) were added to mmm-health-monitor.sh's missing/down checks — no new
# code needed here, since this script's existing "active alerts" line (below) already
# greps _ACTIVE=1 out of the SAME monitor state file generically, and the full-dump
# section at the end already includes their keys along with everything else.

MSMTP="/opt/homebrew/bin/msmtp"
TO="dennyrgood@yahoo.com"
LINES=10
STALE_SECS=108000   # 30h — backup cron fires ~4am, report runs a few hours later;
                     # a healthy log is a few hours old, a missed night pushes past 24h.
                     # Padded beyond WBU's 24h since this job's steady-state runtime
                     # (large media files over RAID5) is less predictable than WBU's.
MONITOR_STATE="/tmp/mathes-mac-mini-monitor-state.tmp"
MONITOR_STALE_SECS=600   # 10 min — mmm-health-monitor runs every 5 min via launchd

# 2026-08-08: NUT/UPS, added once the Mac Mini's NUT client was verified end to end
# (UPS/NUT setup guide, Section 7). Real-time faults (unreadable, replace-battery,
# local daemon missing) are mmm-health-monitor's job and already surface via the active-
# alerts line below; this is the nightly view — what the UPS says right now.
#
# Reads the real upsmon daemon's own log (UPSMON_LOG) rather than an independent
# `upsc` query — same-day fix after `upsc` turned out to fail ~100% of the time
# specifically under launchd (5ms "No route to host", root cause never nailed down
# despite ruling out interfaces/routes/firewalls/Tailscale/TCC/quarantine) while the
# real daemon's own connection, made once at boot, stayed rock solid throughout. See
# mathes-mac-mini-health-monitor.sh's matching 2026-08-08 comment for the full story.
UPS_NAME="ups0"
UPS_HOST="192.168.178.123"
UPSMON_LOG="/Library/Logs/mmm_nut_upsmon.log"
UPSMON_PROC_PATTERN="/opt/homebrew/sbin/upsmon"

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

# 2026-08-30: per-service breakdown of $MONITOR_STATE for the TLDR — added after the
# generic "no active alerts" aggregate line turned out to look identical whether or
# not TMDB/HEARTBEAT_WRITER/METRICS_SERVER checks existed at all: they were real
# (visible in the full state dump at the bottom), but nothing at-a-glance in the TLDR
# actually named them, so a passing run looked no different pre/post. This reads the
# same MISSING_${svc}_ACTIVE/DOWN_${svc}_ACTIVE keys mmm-health-monitor.sh already
# writes — no new state, just surfacing what's already there per-service instead of
# only as one aggregate line.
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

# --- UPS / NUT ---
# Computed and gated FIRST: no shutdown protection outranks a stale backup log, same
# priority WBU's nightly summary gives its own UPS check relative to log-string checks.
# Everything below this block that can set OK=0 is guarded with `[ "$OK" -eq 1 ]` so it
# can't clobber this REASON if the UPS is what's actually wrong.
UPS_BAD=0
UPS_REASON=""

UPSMON_ALIVE="no"
pgrep -f "$UPSMON_PROC_PATTERN" >/dev/null 2>&1 && UPSMON_ALIVE="yes"

# NUT only logs on state CHANGE, not periodically — a healthy connection that's never
# dropped produces zero comms lines after the initial connect, so "none ever logged"
# reads as healthy-by-default below, not unknown. Same for power state: no ONBATT/
# ONLINE line ever means it's been on line power the whole time (matches what's
# actually been observed — the daemon didn't even log an explicit ONLINE at boot).
#
# 2026-08-25: both scoped to lines since the CURRENT daemon instance's own startup
# banner, not the whole cumulative log (never rotated) — see the matching, more
# detailed 2026-08-25 comment in mathes-mac-mini-health-monitor.sh for the real
# incident this fixes: a fresh successful connect never logs "established"/"on line
# power" at all, so a historical drop with no later recovery notification (routine,
# not rare — it happens on ANY restart after a real drop) would otherwise strand
# this check as permanently bad, pointing at a line that could be weeks old.
LAST_START_LINE=$(grep -n "^Network UPS Tools upsmon" "$UPSMON_LOG" 2>/dev/null | tail -1 | cut -d: -f1)
LAST_START_LINE=${LAST_START_LINE:-0}
LOG_SINCE_START=$(tail -n +"$((LAST_START_LINE + 1))" "$UPSMON_LOG" 2>/dev/null)

LAST_COMMS_LINE=$(echo "$LOG_SINCE_START" | grep -E "Communications with UPS ${UPS_NAME}@${UPS_HOST}|UPS ${UPS_NAME}@${UPS_HOST} is unavailable" | tail -1)
COMMS_OK="yes"
[ -n "$LAST_COMMS_LINE" ] && ! echo "$LAST_COMMS_LINE" | grep -q "established" && COMMS_OK="no"

LAST_POWER_LINE=$(echo "$LOG_SINCE_START" | grep -E "UPS ${UPS_NAME}@${UPS_HOST} on (line power|battery)" | tail -1)
ON_BATTERY="no"
echo "$LAST_POWER_LINE" | grep -q "on battery" && ON_BATTERY="yes"

RB_SEEN="no"
grep -q "UPS ${UPS_NAME}@${UPS_HOST} battery needs to be replaced" "$UPSMON_LOG" 2>/dev/null && RB_SEEN="yes"

UPS_TLDR="  ups: local-upsmon=${UPSMON_ALIVE} comms=${COMMS_OK} on-battery=${ON_BATTERY}"
if [ "$UPSMON_ALIVE" = "no" ]; then
    UPS_BAD=1; UPS_REASON="local upsmon daemon not running"
    UPS_TLDR="⚠️${UPS_TLDR} — LOCAL DAEMON DOWN"
elif [ "$COMMS_OK" = "no" ]; then
    UPS_BAD=1; UPS_REASON="UPS unreadable (comms lost)"
    UPS_TLDR="⚠️${UPS_TLDR} — COMMS LOST"
elif [ "$RB_SEEN" = "yes" ]; then
    UPS_BAD=1; UPS_REASON="UPS replace battery"
    UPS_TLDR="⚠️${UPS_TLDR} — REPLACE BATTERY"
elif [ "$ON_BATTERY" = "yes" ]; then
    UPS_BAD=1; UPS_REASON="UPS on battery"
    UPS_TLDR="⚠️${UPS_TLDR} — ON BATTERY NOW"
else
    UPS_TLDR="${UPS_TLDR} ✓"
fi

UPS_BLOCK="Most recent comms line: ${LAST_COMMS_LINE:-(none logged — healthy default, no drops seen)}
Most recent power line:  ${LAST_POWER_LINE:-(none logged — assume on line power)}
(Read from ${UPSMON_LOG}, the real daemon's own log — not a live query. See this
script's 2026-08-08 comment above for why upsc itself isn't used here.)"

BODY+="=== UPS (${UPS_NAME}@${UPS_HOST}) ===\n${UPS_BLOCK}\n\n"
[ "$UPS_BAD" -eq 1 ] && { OK=0; REASON="$UPS_REASON"; }

TLDR="============================= TLDR ===============================\n"
TLDR+="${UPS_TLDR}\n"
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
    if [ "$OK" -eq 1 ] && [ -z "$COMPLETE_LINE" ]; then
        OK=0; REASON="Plex sync to FleetNAS did not complete cleanly"
    elif [ "$OK" -eq 1 ] && { ! [[ "$S1_EXIT" =~ ^(0|24)$ ]] || ! [[ "$S2_EXIT" =~ ^(0|24)$ ]]; }; then
        OK=0; REASON="Plex sync to FleetNAS did not complete cleanly (source1 exit=${S1_EXIT}, source2 exit=${S2_EXIT})"
    elif [ "$OK" -eq 1 ] && [ "$AGE_SECS" -gt "$STALE_SECS" ]; then
        OK=0; REASON="Plex sync log stale (${AGE})"
    elif [ "$OK" -eq 1 ] && [ "$VANISHED_COUNT" -gt 0 ]; then
        # Transfer succeeded (exit 0/24), but don't fold this into a bare "all
        # healthy" — files missing from the NAS copy is worth seeing even when
        # it's the benign case (Plex renamed/deleted them mid-scan). Not an
        # alarm (still ✅), just visible instead of buried in the log body.
        REASON="${VANISHED_COUNT} file(s) vanished during sync — verify if unexpected (see log below)"
    fi
else
    TLDR+="  plex_*.log: (file not found)\n"
    [ "$OK" -eq 1 ] && { OK=0; REASON="Plex sync log missing — cron may not have run yet"; }
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
    TLDR+="    plex:             $(svc_status PLEX)\n"
    TLDR+="    syncthing:        $(svc_status SYNCTHING)\n"
    TLDR+="    tmdb-explorer:    $(svc_status TMDB)\n"
    TLDR+="    heartbeat-writer: $(svc_status HEARTBEAT_WRITER)\n"
    TLDR+="    metrics-server:   $(svc_status METRICS_SERVER)\n"
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
    # 2026-08-31 UTC — Cc self, nightly-summary only — see DennissMacBookAir's version
    # for the full rationale (feeds a separate daily digest script).
    echo "Cc: dennis.mathes@icloud.com"
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO" dennis.mathes@icloud.com
