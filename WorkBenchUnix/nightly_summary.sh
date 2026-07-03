#!/bin/bash
# /srv/immich/scripts/nightly_summary.sh
# 2026-07-01 20:00 UTC
# Daily backup summary email — tails all backup logs and sends via msmtp.

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
# 2026-07-03 06:00 UTC — added TLDR block
TLDR="=== TLDR ===\n"
for LOG in "${LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        TLDR+="  $(basename "$LOG"): $(tail -1 "$LOG")\n"
    else
        TLDR+="  $(basename "$LOG"): (file not found)\n"
    fi
done
TLDR+="\n"
BODY="${TLDR}${BODY}"
# --- Determine OK / NOT OK ---
if echo -e "$BODY" | grep -v "^===" | grep -v "role already exists\|database already exists\|possible errors during restore" | grep -qiE "WARNING|ERROR|rsync error|[^0] genuinely missing"; then

    STATUS="⚠️ NOT OK"
else
    STATUS="✅ OK"
fi

SUBJECT="Nightly Backup Summary - WorkBenchUnix - $(date '+%Y-%m-%d') - ${STATUS}"

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
