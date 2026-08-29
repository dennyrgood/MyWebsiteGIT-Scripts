#!/bin/bash
# remove-root-integrity-cron.sh — take the integrity checks out of ROOT's
# crontab. They belong in dhm's, where add-integrity-cron.sh now puts them.
# Created: 2026-08-29.
#
# The first version of add-integrity-cron.sh installed to root. That was wrong
# (these jobs need no root, and their sibling backup scripts run as dhm), and
# it left root-owned logs under /home/dhm/.cache which then broke non-sudo
# runs. The corrected script installs to dhm -- so after running both, the
# entries exist TWICE and would fire twice a night, with root's copy
# recreating the ownership problem.
#
# Removes only the three integrity lines and their comment block. Everything
# else in root's crontab is left untouched.

set -u
STAMP=$(date +%Y-%m-%d_%H%M)
BACKUP="/root/crontab.bak.$STAMP"

fail() { echo; echo "FAILED: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"

crontab -l > "$BACKUP" 2>/dev/null || fail "could not read root crontab"
chmod 0600 "$BACKUP"
echo "backup: $BACKUP ($(wc -l < "$BACKUP") lines)"

BEFORE=$(grep -c "verify_immich_source_integrity.sh\|audit_mirror_checksums.sh" "$BACKUP" || true)
if [ "$BEFORE" -eq 0 ]; then
    echo "nothing to remove — root's crontab has no integrity entries"; exit 0
fi
echo "found $BEFORE integrity line(s) to remove"

# Drop the three job lines and the comment block introduced with them.
awk '
    /^# --- content integrity checks/ { skip = 1 }
    skip && /^$/                      { skip = 0; next }
    skip                              { next }
    /verify_immich_source_integrity\.sh|audit_mirror_checksums\.sh/ { next }
    { print }
' "$BACKUP" > /tmp/crontab.clean.$$ || fail "could not filter crontab"

crontab /tmp/crontab.clean.$$ || { rm -f /tmp/crontab.clean.$$; fail "install failed — crontab untouched"; }
rm -f /tmp/crontab.clean.$$

AFTER=$(crontab -l | grep -c "verify_immich_source_integrity.sh\|audit_mirror_checksums.sh" || true)
if [ "$AFTER" -ne 0 ]; then
    crontab "$BACKUP"; fail "$AFTER line(s) still present — restored from $BACKUP"
fi
echo "ok: removed from root's crontab"

echo
echo "===== root's crontab now ====="
crontab -l | grep -vE "^#|^$"
echo
echo "===== dhm's crontab (where they belong) ====="
su - dhm -c "crontab -l" 2>/dev/null | grep -E "verify_immich|audit_mirror" || echo "  (none — run add-integrity-cron.sh as dhm)"
echo
echo "To undo:  sudo crontab $BACKUP"
