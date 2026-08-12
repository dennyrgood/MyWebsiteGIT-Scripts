#!/bin/bash
# /home/dhm/repos/scripts/ChatWorkhorseUnix/cwhu-nightly-summary.sh
# 2026-07-12 20:00 UTC — created
# CWHU nightly health summary email — tails warm-sync logs, checks health monitor state.
# 2026-07-14 16:00 UTC — added restore_log to LOGS array and TLDR pass/fail check.
# 2026-07-14 16:30 UTC — fixed blank RESTORE_LOG entry in LOGS array when no file exists yet; restore_log now conditionally appended.
# 2026-08-03 UTC — every TLDR log line now carries a relative age "[3d ago]", so a
#                  stale log is visible even when another check owns the subject.
# 2026-08-03 UTC — fixed two monitor-watchdog faults: the stale-monitor TLDR line
#                  was labelled "wbu-health-monitor" (copy-paste from the WBU
#                  script — it named the wrong machine on the one line that fires
#                  during a real fault), and a MISSING state file wrote a warning
#                  to the body without ever setting REASON, so a health monitor
#                  that had never run still produced a ✅ "all healthy" subject.
# 2026-08-12 UTC — added UPS/NUT section (TLDR line, body block, on-battery-24h
#                  count, OB/RB detection folded into REASON). CWHU became a NUT
#                  client of ups2 on WorkBenchUnix this date; this closes the gap
#                  where WorkBenchUnix/nightly_summary.sh had the equivalent
#                  section since 2026-08-04 but CWHU's summary had none.
TO="dennyrgood@yahoo.com"
LINES=5
MONITOR_STATE="/tmp/cwhu-monitor-state.tmp"
SYNC_LOG=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_log_*.txt 2>/dev/null | head -1)
SYNC_ERRORS=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_errors_*.txt 2>/dev/null | head -1)
RESTORE_LOG=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/restore_log_*.txt 2>/dev/null | head -1)
LOGS=(
    "$SYNC_LOG"
    "$SYNC_ERRORS"
)
[ -n "$RESTORE_LOG" ] && LOGS+=("$RESTORE_LOG")

# --- UPS / NUT (added 2026-08-12) ---
# CWHU is a NUT client of ups2 on WorkBenchUnix — the UPS that powers its host, and
# therefore this VM. Real-time faults (unreachable, replace-battery) are
# cwhu-health-monitor's job and already surface through the active-alerts line
# below; this block is the nightly view instead: what the UPS says right now, and
# whether CWHU ran on battery overnight. Ported from WorkBenchUnix/nightly_summary.sh
# (added there 2026-08-04), adapted for CWHU's client role: queries WBU over the LAN
# rather than localhost, and says "unreachable" (network-framed) rather than
# "unreadable" (driver-framed) to match cwhu-health-monitor.sh's terminology.
#
# On-battery events are deliberately NOT a real-time alert — a brief flicker would
# page for nothing, and during a genuine outage the box may be shutting down before
# the mail leaves. But "we were on battery at 3am and you slept through it" is worth
# knowing over coffee, so it is counted here.
UPS_NAME="ups2"
UPS_HOST="192.168.178.242"   # WBU LAN address — see cwhu-health-monitor.sh
UPS_BAD=0
UPS_REASON=""
UPS_TLDR="  ups: (unavailable)"
UPS_BLOCK="(upsc returned nothing for ${UPS_NAME}@${UPS_HOST} — see cwhu-health-monitor alerts)"
UPS_OUT=$(upsc "${UPS_NAME}@${UPS_HOST}" 2>/dev/null)
if [ -n "$UPS_OUT" ]; then
    U_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
    U_CHARGE=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="battery.charge"{print $2}')
    U_LOAD=$(printf '%s\n'   "$UPS_OUT" | awk -F': ' '$1=="ups.load"{print $2}')
    # grep -c exits 1 on zero matches; || true keeps that from emptying the variable.
    ONBATT_N=$(journalctl -u nut-monitor --since '24 hours ago' --no-pager 2>/dev/null \
               | grep -c 'running on battery' || true)
    ONBATT_N=${ONBATT_N:-0}
    UPS_TLDR="  ups: ${U_STATUS} charge=${U_CHARGE}% load=${U_LOAD}% on-battery-events-24h=${ONBATT_N}"
    case " $U_STATUS " in
        *" OB "*) UPS_BAD=1; UPS_REASON="UPS on battery";      UPS_TLDR="⚠️${UPS_TLDR} — ON BATTERY NOW" ;;
        *" RB "*) UPS_BAD=1; UPS_REASON="UPS replace battery"; UPS_TLDR="⚠️${UPS_TLDR} — REPLACE BATTERY" ;;
        *)        if [ "$ONBATT_N" -gt 0 ]; then
                      UPS_TLDR="${UPS_TLDR} (ran on battery in the last 24h)"
                  else
                      UPS_TLDR="${UPS_TLDR} ✓"
                  fi ;;
    esac
    UPS_BLOCK="$UPS_OUT"
else
    UPS_BAD=1
    UPS_REASON="UPS unreachable"
    UPS_TLDR="⚠️  ups: unreachable (upsc ${UPS_NAME}@${UPS_HOST} returned nothing)"
fi

# --- Build TLDR ---
# Age is shown because the last line alone can't be read for staleness: a log ending
# in "Warm-sync complete." looks green whether it ran an hour ago or last Tuesday.
# REASON below is set once and every later check is guarded on it still being
# "all healthy", so only ONE failure ever reaches the subject — a stale log stays
# invisible whenever another check claims it first. Mirrors the same fix in
# WorkBenchUnix/nightly_summary.sh (2026-08-03).
fmt_age() {
    local secs=$1
    if   [ "$secs" -lt 3600 ];   then echo "$((secs / 60))m"
    elif [ "$secs" -lt 172800 ]; then echo "$((secs / 3600))h"   # keep hours up to 48h: "25h" says more than "1d"
    else echo "$((secs / 86400))d"
    fi
}

TLDR="============================= TLDR ===============================\n"
TLDR+="${UPS_TLDR}\n"
NOW_TLDR=$(date +%s)
for LOG in "${LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        AGE=$(fmt_age $(( NOW_TLDR - $(stat -c %Y "$LOG") )))
        TLDR+="  $(basename "$LOG"): [${AGE} ago] $(tail -1 "$LOG")\n"
    else
        TLDR+="  $(basename "$LOG"): (file not found)\n"
    fi
done
# Restore log pass/fail
if [ ! -f "$RESTORE_LOG" ]; then
    TLDR+="  restore_log: ⚠️ not found\n"
else
    RESTORE_ERRORS=$(grep -i "^error" "$RESTORE_LOG" | grep -iv "already exists" | wc -l)
    if [ "$RESTORE_ERRORS" -gt 0 ]; then
        TLDR+="  restore_log: ⚠️ ${RESTORE_ERRORS} unexpected error(s)\n"
    else
        TLDR+="  restore_log: ✓\n"
    fi
fi
# --- Add health monitor watchdog to TLDR ---
if [ -f "$MONITOR_STATE" ]; then
    STATE_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$STATE_AGE" -gt 600 ]; then
        TLDR+="  cwhu-health-monitor: ⚠️ stale (last-run $((STATE_AGE / 60))m ago; threshold 10m)\n"
    else
        TLDR+="  cwhu-health-monitor: last-run $((STATE_AGE / 60))m ago ✓\n"
    fi
    ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$ACTIVE" ]; then
        TLDR+="  cwhu-health-monitor: ⚠️ ACTIVE ALERTS\n"
    else
        TLDR+="  cwhu-health-monitor: no active alerts ✓\n"
    fi
else
    TLDR+="  cwhu-health-monitor: ⚠️ state file missing\n"
fi
TLDR+="===================================================================\n\n"
# --- Build log tails ---
BODY=""
BODY+="=== UPS (${UPS_NAME}@${UPS_HOST}) ===\n${UPS_BLOCK}\n\n"
for LOG in "${LOGS[@]}"; do
    BODY+="=== $LOG ===\n"
    if [ -f "$LOG" ]; then
        BODY+="$(tail -$LINES $LOG)\n"
    else
        BODY+="(file not found)\n"
    fi
    BODY+="\n"
done
BODY="${TLDR}${BODY}"
# --- Status check: warm-sync success string ---
REASON="all healthy"
if [ "$UPS_BAD" -eq 1 ]; then
    # Above the log-string checks below: an unreachable/bad UPS means CWHU (and WBU,
    # ChatWorkhorse, ImageBeast) has no reliable shutdown signal, which outranks a
    # stale backup log. Mirrors the priority WorkBenchUnix/nightly_summary.sh uses.
    REASON="$UPS_REASON"
elif [ ! -f "$SYNC_LOG" ]; then
    REASON="sync_log missing"
elif ! tail -5 "$SYNC_LOG" | grep -q "Warm-sync complete."; then
    REASON="$(basename "$SYNC_LOG") did not complete"
fi
# --- Staleness check: sync log older than 26 hours ---
if [ "$REASON" = "all healthy" ] && [ -f "$SYNC_LOG" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$SYNC_LOG") ))
    if [ "$FILE_AGE" -gt 93600 ]; then  # 26 hours
        REASON="$(basename "$SYNC_LOG") stale ($((FILE_AGE / 3600))h)"
    fi
fi
# --- Health monitor state ---
BODY+="=== HEALTH MONITOR STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    # Freshness check
    STATE_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$STATE_AGE" -gt 600 ]; then  # 10 minutes — should run every 5
        BODY+="⚠️ WARNING: state file is ${STATE_AGE}s old (monitor may not be running)\n"
        [ "$REASON" = "all healthy" ] && REASON="health monitor stale/missing"
    fi
    # Active alerts
    ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$ACTIVE" ]; then
        BODY+="ACTIVE ALERTS:\n$ACTIVE\n"
        [ "$REASON" = "all healthy" ] && REASON="active health alerts"
    else
        BODY+="No active alerts.\n"
    fi
    BODY+="\n$(cat "$MONITOR_STATE")\n"
else
    # A missing state file is strictly worse than a stale one — the monitor has never
    # run, or its /tmp state was wiped by a reboot. The stale branch above flips the
    # subject; this one used to write to the body and stop there, so a dead monitor
    # produced a ✅ "all healthy" email with a ⚠️ line buried in the TLDR. Matches the
    # MONITOR_FRESH_BAD handling in WorkBenchUnix/nightly_summary.sh.
    BODY+="⚠️ WARNING: state file not found — health monitor has not run\n"
    [ "$REASON" = "all healthy" ] && REASON="health monitor stale/missing"
fi
if [ "$REASON" = "all healthy" ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} ChatWorkhorseUnix nightly $(date '+%Y-%m-%d') — ${REASON}"
{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
