#!/bin/bash
# /home/dhm/repos/scripts/WorkBenchUnix/monthly_motd_summary.sh
# 2026-07-02 HH:MM UTC
# Monthly MOTD/system status email — sends via msmtp.

TO="dennyrgood@yahoo.com"
SUBJECT="Monthly System Status - WorkBenchUnix - $(date '+%Y-%m-%d')"
BODY=$(cat /run/motd.dynamic)

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo "$BODY"
} | msmtp --account=icloud "$TO"

