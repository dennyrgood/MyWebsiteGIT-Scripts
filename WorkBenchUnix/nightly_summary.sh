#!/bin/bash
# /srv/immich/scripts/nightly_summary.sh
# 2026-07-01 20:00 UTC
# Daily backup summary email — tails all backup logs and sends via msmtp.
# 2026-07-03 09:00 UTC — added TLDR block
# 2026-07-03 09:30 UTC — switched grep -v to -vE for alternation
# 2026-07-03 11:00 UTC — replaced fragile word-scan STATUS check with per-log success-string check
# 2026-07-05 HH:MM UTC — added 6-hour staleness check for CWHU sync log
TO="dennyrgood@yahoo.com"
LINES=5
MACMINI_DB=$(ls -1t /home/dhm/.cache/export-sync/macmini_db_*.log 2>/dev/null | head -1)
MACMINI_IMG=$(ls -1t /home/dhm/.cache/export-sync/macmini_images_*.log 2>/dev/null | head -1)
CWHU_SYNC=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_log_*.txt 2>/dev/null | head -1)
CWHU_ERRORS=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_errors_*.txt 2>/dev/null | head -1)
EXPORT_ARCHIVE=$(cat /home/dhm/.cache/immich-export/export_archive.log 2>/dev/null | wc -l > /dev/null; echo /home/dhm/.cache/immich-export/export_archive.log)
LOGS=(
    "/var/log/immich-backup-c.log"
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
# Mac Mini logs are intentionally excluded — Friday-only, expected to be stale other days.
STATUS="✅ OK"
declare -A EXPECTED=(
    ["/var/log/immich-backup-c.log"]="Backup to /mnt/backup-c finished."
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
SUBJECT="Nightly Backup Summary - WorkBenchUnix - $(date '+%Y-%m-%d') - ${STATUS}"
{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
