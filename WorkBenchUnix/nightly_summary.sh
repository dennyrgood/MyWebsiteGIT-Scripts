#!/bin/bash
# /srv/immich/scripts/nightly_summary.sh
# 2026-07-01 20:00 UTC
# Daily backup summary email — tails all backup logs and sends via msmtp.
# 2026-07-03 09:00 UTC — added TLDR block
# 2026-07-03 09:30 UTC — switched grep -v to -vE for alternation
# 2026-07-03 11:00 UTC — replaced fragile word-scan STATUS check with per-log success-string check
TO="dennyrgood@yahoo.com"
LINES=5
MACMINI_DB=$(ls -1t /home/dhm/.cache/export-sync/macmini_db_*.log 2>/dev/null | head -1)
MACMINI_IMG=$(ls -1t /home/dhm/.cache/export-sync/macmini_images_*.log 2>/dev/null | head -1)
CWHU_SYNC=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_log_*.txt 2>/dev/null | head -1)
CWHU_ERRORS=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_errors_*.txt 2>/dev/null | head -1)
LOGS=(
    "/var/log/immich-backup-c.log"
    "/var/log/immich-dump-for-cwhu.log"
    "$MACMINI_DB"
    "$MACMINI_IMG"
    "$CWHU_SYNC"
    "$CWHU_ERRORS"
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
# --- Build TLDR (last line of each log) ---
TLDR="============================= TLDR ===============================\n"
for LOG in "${LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        TLDR+="  $(basename "$LOG"): $(tail -1 "$LOG")\n"
    else
        TLDR+="  $(basename "$LOG"): (file not found)\n"
    fi
done
TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"
# --- Determine OK / NOT OK ---
# Check each log for its expected success string rather than scanning for bad words.
# sync_errors_*.txt is intentionally excluded — docker compose noise, no success string.
STATUS="✅ OK"
declare -A EXPECTED=(
    ["/var/log/immich-backup-c.log"]="Backup to /mnt/backup-c finished."
    ["/var/log/immich-dump-for-cwhu.log"]="Dump for CWHU complete."
    ["$MACMINI_DB"]="Postgres dump sync to Mac Mini complete"
    ["$MACMINI_IMG"]="Live image sync to Mac Mini complete"
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
SUBJECT="Nightly Backup Summary - WorkBenchUnix - $(date '+%Y-%m-%d') - ${STATUS}"
{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
