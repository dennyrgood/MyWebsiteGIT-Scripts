#!/bin/bash
# add-restic-cron.sh — add the nightly restic backup to root's crontab.
# Created: 2026-08-25.
#
# Backs the crontab up first, refuses if the entry already exists, and rolls
# back if the new crontab fails to install.
#
# 04:00 is chosen deliberately: after the 03:30 pg_dumpall (so each snapshot
# contains that morning's fresh dump) and well before the 05:00/05:20 FleetNAS
# syncs. Nightly deltas take seconds, so the margin either side is large.
#
# The redirect differs from the other cron lines on purpose. Those scripts echo
# and let cron capture the output; this one uses `tee -a` and writes its own
# log, so redirecting stdout to the same file would duplicate every line.
# stdout is discarded; stderr is still appended in case the script itself
# fails in a way its own logging never sees.

set -u

SCRIPT="/home/dhm/repos/scripts/WorkBenchUnix/backup_immich_to_restic.sh"
LOGFILE="/var/log/immich-restic.log"
CRON_LINE="0 4 * * * $SCRIPT >/dev/null 2>>$LOGFILE"
STAMP=$(date +%Y-%m-%d_%H%M)
BACKUP="/root/crontab.bak.$STAMP"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"
[ -x "$SCRIPT" ] || fail "$SCRIPT is missing or not executable"

echo "===== backing up current root crontab ====="
crontab -l > "$BACKUP" 2>/dev/null || fail "could not read root crontab"
chmod 0600 "$BACKUP"
echo "ok: $BACKUP ($(wc -l < "$BACKUP") lines)"

if grep -q "backup_immich_to_restic.sh" "$BACKUP"; then
    fail "crontab already references backup_immich_to_restic.sh — nothing to do"
fi
echo "ok: no existing entry"

echo
echo "===== adding ====="
{
    cat "$BACKUP"
    echo ""
    echo "# --- restic repo backup (local, for off-site Syncthing to s3g) — daily ---"
    echo "# Added $STAMP. Runs after the 03:30 dump, before the 05:00 FleetNAS sync."
    echo "# Script writes its own log via tee; stdout dropped to avoid duplicate lines."
    echo "$CRON_LINE"
} > /tmp/crontab.new.$$ || fail "could not build new crontab"

if ! crontab /tmp/crontab.new.$$; then
    rm -f /tmp/crontab.new.$$
    fail "crontab install failed — the existing crontab is untouched"
fi
rm -f /tmp/crontab.new.$$

# Verify the entry actually landed; restore if not.
if ! crontab -l | grep -q "backup_immich_to_restic.sh"; then
    echo "!! entry not present after install — restoring backup"
    crontab "$BACKUP"
    fail "verification failed; crontab restored from $BACKUP"
fi

echo "ok: entry installed"
echo
echo "===== resulting crontab ====="
crontab -l
echo
echo "backup: $BACKUP"
echo "To undo:  sudo crontab $BACKUP"
