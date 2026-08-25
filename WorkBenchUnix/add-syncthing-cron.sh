#!/bin/bash
# add-syncthing-cron.sh — add the off-site replication check to root's crontab.
# Created: 2026-08-25.
#
# 06:25 is five minutes before nightly_summary.sh at 06:30, so the summary
# always reads a log written minutes earlier rather than yesterday's. The check
# itself takes a couple of seconds.
#
# Same guards as add-restic-cron.sh: backs up first, refuses on a duplicate,
# verifies the entry landed and restores if it did not.

set -u

SCRIPT="/home/dhm/repos/scripts/WorkBenchUnix/syncthing_offsite_status.sh"
LOGFILE="/var/log/syncthing-offsite.log"
CRON_LINE="25 6 * * * $SCRIPT >/dev/null 2>>$LOGFILE"
STAMP=$(date +%Y-%m-%d_%H%M)
BACKUP="/root/crontab.bak.$STAMP"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"
[ -x "$SCRIPT" ] || fail "$SCRIPT is missing or not executable"

echo "===== backing up current root crontab ====="
crontab -l > "$BACKUP" 2>/dev/null || fail "could not read root crontab"
chmod 0600 "$BACKUP"
echo "ok: $BACKUP ($(wc -l < "$BACKUP") lines)"

if grep -q "syncthing_offsite_status.sh" "$BACKUP"; then
    fail "crontab already references syncthing_offsite_status.sh — nothing to do"
fi
echo "ok: no existing entry"

echo
echo "===== adding ====="
{
    cat "$BACKUP"
    echo ""
    echo "# --- off-site replication check (restic repo -> s3g via Syncthing) — daily ---"
    echo "# Added $STAMP. Runs 5 min before nightly_summary.sh so the summary reads fresh state."
    echo "# Script writes its own log via tee; stdout dropped to avoid duplicate lines."
    echo "$CRON_LINE"
} > /tmp/crontab.new.$$ || fail "could not build new crontab"

if ! crontab /tmp/crontab.new.$$; then
    rm -f /tmp/crontab.new.$$
    fail "crontab install failed — the existing crontab is untouched"
fi
rm -f /tmp/crontab.new.$$

if ! crontab -l | grep -q "syncthing_offsite_status.sh"; then
    echo "!! entry not present after install — restoring backup"
    crontab "$BACKUP"
    fail "verification failed; crontab restored from $BACKUP"
fi

echo "ok: entry installed"
echo
echo "===== backup-related cron entries now ====="
crontab -l | grep -E "restic|syncthing|nightly_summary|dump_immich" | grep -v "^#"
echo
echo "backup: $BACKUP"
echo "To undo:  sudo crontab $BACKUP"
