#!/bin/bash
# /home/dhm/repos/scripts/WorkBenchUnix/nightly_summary.sh
# 2026-07-01 20:00 UTC
# Daily health summary email — tails all backup logs, checks health monitor
# freshness and active alerts, sends via msmtp.
# 2026-07-03 09:00 UTC — added TLDR block
# 2026-07-03 09:30 UTC — switched grep -v to -vE for alternation
# 2026-07-03 11:00 UTC — replaced fragile word-scan STATUS check with per-log success-string check
# 2026-07-05 HH:MM UTC — added 6-hour staleness check for CWHU sync log
# 2026-07-12 UTC — renamed subject "Backup Summary" -> "Health Summary".
#                  Added wbu-health-monitor watchdog: freshness (>15 min = NOT OK),
#                  active alerts by name in TLDR, state file dumped at bottom.
#                  Corrected header path from /srv/immich/scripts/ to actual cron location.

TO="dennyrgood@yahoo.com"
LINES=5
MONITOR_STATE="/tmp/wbu-monitor-state.tmp"
MONITOR_STALE_SECS=900   # 15 minutes; cron runs monitor every 5 min

MACMINI_DB=$(ls -1t /home/dhm/.cache/export-sync/macmini_db_*.log 2>/dev/null | head -1)
MACMINI_IMG=$(ls -1t /home/dhm/.cache/export-sync/macmini_images_*.log 2>/dev/null | head -1)
CWHU_SYNC=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_log_*.txt 2>/dev/null | head -1)
CWHU_ERRORS=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_errors_*.txt 2>/dev/null | head -1)
EXPORT_ARCHIVE=$(cat /home/dhm/.cache/immich-export/export_archive.log 2>/dev/null | wc -l > /dev/null; echo /home/dhm/.cache/immich-export/export_archive.log)

LOGS=(
    # "/var/log/immich-backup-c.log"  # 2026-07-22: backup-c drive retired (repeat failures), cron disabled — see WorkBenchUnix/backup_immich.sh comment
    "/var/log/immich-dump-for-cwhu.log"
    "$MACMINI_DB"
    "$MACMINI_IMG"
    "$CWHU_SYNC"
    "$CWHU_ERRORS"
    "/home/dhm/.cache/immich-export/export_archive.log"
    "/home/dhm/.cache/immich-export/export_flat_to_amsterdamdesktop.log"
    "/home/dhm/.cache/immich-export/export_multi_to_amsterdamdesktop.log"
    "/home/dhm/.cache/immich-export/export_flat_to_macmini.log"
    "/home/dhm/.cache/immich-export/export_multi_to_macmini.log"
)

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

# --- Append health monitor state file to bottom of body ---
BODY+="=== $MONITOR_STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    BODY+="$(cat "$MONITOR_STATE")\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

# --- Evaluate health monitor freshness ---
# Empty MONITOR_FRESH_LINE means healthy (nothing to add to TLDR beyond the OK line).
MONITOR_FRESH_LINE=""
MONITOR_FRESH_BAD=0
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        MONITOR_FRESH_LINE="  wbu-health-monitor: ⚠️ stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)"
        MONITOR_FRESH_BAD=1
    else
        MONITOR_FRESH_LINE="  wbu-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓"
    fi
else
    MONITOR_FRESH_LINE="  wbu-health-monitor: ⚠️ state file missing ($MONITOR_STATE)"
    MONITOR_FRESH_BAD=1
fi

# --- Extract active alerts from state file ---
# Any line matching *_ACTIVE=1 means that condition is currently firing.
MONITOR_ACTIVE_LINE=""
MONITOR_ACTIVE_BAD=0
if [ -f "$MONITOR_STATE" ]; then
    ACTIVE_ALERTS=$(grep '_ACTIVE=1$' "$MONITOR_STATE" | sed 's/_ACTIVE=1$//' | paste -sd', ' -)
    if [ -n "$ACTIVE_ALERTS" ]; then
        MONITOR_ACTIVE_LINE="  wbu-health-monitor: ⚠️ active alerts: ${ACTIVE_ALERTS}"
        MONITOR_ACTIVE_BAD=1
    else
        MONITOR_ACTIVE_LINE="  wbu-health-monitor: no active alerts ✓"
    fi
fi

# --- Build TLDR (last line of each log, plus monitor watchdog lines) ---
TLDR="============================= TLDR ===============================\n"
for LOG in "${LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        TLDR+="  $(basename "$LOG"): $(tail -1 "$LOG")\n"
    else
        TLDR+="  $(basename "$LOG"): (file not found)\n"
    fi
done
TLDR+="${MONITOR_FRESH_LINE}\n"
TLDR+="${MONITOR_ACTIVE_LINE}\n"
TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

# --- Determine OK / NOT OK ---
# Check each log for its expected success string rather than scanning for bad words.
# sync_errors_*.txt is intentionally excluded — docker compose noise, no success string.
# Mac Mini logs are intentionally excluded — Friday-only, expected to be stale other days.
STATUS="✅ OK"
declare -A EXPECTED=(
    # ["/var/log/immich-backup-c.log"]="Backup to /mnt/backup-c finished."  # 2026-07-22: backup-c drive retired (repeat failures), cron disabled
    ["/var/log/immich-dump-for-cwhu.log"]="Dump for CWHU complete."
    ["$CWHU_SYNC"]="Warm-sync complete."
)
for LOG in "${!EXPECTED[@]}"; do
    if [ ! -f "$LOG" ]; then
        STATUS="⚠️ NOT OK (missing: $(basename "$LOG"))"
        break
    fi
    if ! tail -5 "$LOG" | grep -q "${EXPECTED[$LOG]}"; then
        STATUS="⚠️ NOT OK ($(basename "$LOG"))"
        break
    fi
done

# --- Staleness check for CWHU sync log (lives on remote machine, can go stale) ---
if [ -f "$CWHU_SYNC" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CWHU_SYNC") ))
    if [ "$FILE_AGE" -gt 21600 ]; then  # 6 hours
        STATUS="⚠️ NOT OK (stale: $(basename "$CWHU_SYNC"))"
    fi
fi

# --- Health monitor watchdog contributes to STATUS ---
# Only override STATUS if it's still OK; don't clobber a more specific existing failure.
if [ "$STATUS" = "✅ OK" ]; then
    if [ "$MONITOR_FRESH_BAD" -eq 1 ]; then
        STATUS="⚠️ NOT OK (health monitor stale/missing)"
    elif [ "$MONITOR_ACTIVE_BAD" -eq 1 ]; then
        STATUS="⚠️ NOT OK (active health alerts)"
    fi
fi

SUBJECT="${STATUS} - Nightly Health Summary - WorkBenchUnix - $(date '+%Y-%m-%d')"

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
