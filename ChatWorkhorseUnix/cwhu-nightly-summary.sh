#!/bin/bash
# /home/dhm/repos/scripts/ChatWorkhorseUnix/cwhu-nightly-summary.sh
# 2026-07-12 20:00 UTC — created
# CWHU nightly health summary email — tails warm-sync logs, checks health monitor state.
# 2026-07-14 16:00 UTC — added restore_log to LOGS array and TLDR pass/fail check.
# 2026-07-14 16:30 UTC — fixed blank RESTORE_LOG entry in LOGS array when no file exists yet; restore_log now conditionally appended.
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
# --- Build TLDR ---
TLDR="============================= TLDR ===============================\n"
for LOG in "${LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        TLDR+="  $(basename "$LOG"): $(tail -1 "$LOG")\n"
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
        TLDR+="  wbu-health-monitor: ⚠️ stale (${STATE_AGE}s)\n"
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
STATUS="✅ OK"
if [ ! -f "$SYNC_LOG" ]; then
    STATUS="⚠️ NOT OK (missing: sync_log)"
elif ! tail -5 "$SYNC_LOG" | grep -q "Warm-sync complete."; then
    STATUS="⚠️ NOT OK ($(basename "$SYNC_LOG"))"
fi
# --- Staleness check: sync log older than 26 hours ---
if [ -f "$SYNC_LOG" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$SYNC_LOG") ))
    if [ "$FILE_AGE" -gt 93600 ]; then  # 26 hours
        STATUS="⚠️ NOT OK (stale: $(basename "$SYNC_LOG"))"
    fi
fi
# --- Health monitor state ---
BODY+="=== HEALTH MONITOR STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    # Freshness check
    STATE_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$STATE_AGE" -gt 600 ]; then  # 10 minutes — should run every 5
        BODY+="⚠️ WARNING: state file is ${STATE_AGE}s old (monitor may not be running)\n"
        STATUS="⚠️ NOT OK (stale health monitor state)"
    fi
    # Active alerts
    ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$ACTIVE" ]; then
        BODY+="ACTIVE ALERTS:\n$ACTIVE\n"
        STATUS="⚠️ NOT OK (active health alerts)"
    else
        BODY+="No active alerts.\n"
    fi
    BODY+="\n$(cat "$MONITOR_STATE")\n"
else
    BODY+="(state file not found — health monitor may not have run yet)\n"
fi
SUBJECT="${STATUS} - Nightly Health Summary - ChatWorkhorseUnix - $(date '+%Y-%m-%d')"
{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
