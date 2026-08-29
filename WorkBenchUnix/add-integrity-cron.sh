#!/bin/bash
# add-integrity-cron.sh - schedule the two content-integrity checks.
# Created: 2026-08-28. Revised 2026-08-29: dhm's crontab, not root's.
#
# These go in DHM's crontab, alongside backup_immich_images_to_macmini.sh and
# _to_fleetnas.sh, because they are the same kind of job and need the same
# access: dhm can read the library, owns the ssh keys to both destinations, and
# is in the docker group for the Immich database. None of it needs root.
#
# Putting them in root's crontab (the first version of this script) also meant
# root-owned logs under /home/dhm/.cache, which then refused a later non-sudo
# run with a pile of confusing tee errors.
#
#   Sunday 02:00   verify_immich_source_integrity.sh   (weekly)
#   15th   02:00   audit_mirror_checksums.sh fleetnas  (monthly)
#   15th   02:40   audit_mirror_checksums.sh macmini   (monthly)
#
# Times avoid every existing job: the 03:30 dump, the 04:00 restic backup, the
# 05:00/05:20 FleetNAS syncs, Friday's 05:00/05:05 Mac Mini syncs, and the
# 06:25/06:30 checks. All three read the whole library, so they must not
# overlap each other or the backups.
#
# The 15th rather than the 1st: restic prune runs on the 1st and rewrites pack
# files, and there is no reason to stack the two heaviest jobs on one night.
#
# Mac Mini runs 40 min after FleetNAS — FleetNAS measured 8 min, and the Mac
# holds the full images/ tree including thumbs (~114 GiB vs 85 GiB) so it needs
# longer. If that Mac is asleep the check fails loudly rather than silently,
# which is correct: a mirror you cannot reach is not a mirror.

set -u

BASE="/home/dhm/repos/scripts/WorkBenchUnix"
STAMP=$(date +%Y-%m-%d_%H%M)
BACKUP="$HOME/crontab.bak.$STAMP"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "run this WITHOUT sudo - these jobs belong in dhm's crontab, not root's"
[ -x "$BASE/verify_immich_source_integrity.sh" ] || fail "source integrity script missing"
[ -x "$BASE/audit_mirror_checksums.sh" ] || fail "mirror audit script missing"

echo "===== backing up current crontab ($(id -un)) ====="
crontab -l > "$BACKUP" 2>/dev/null || fail "could not read $(id -un)'s crontab"
chmod 0600 "$BACKUP"
echo "ok: $BACKUP ($(wc -l < "$BACKUP") lines)"

if grep -q "verify_immich_source_integrity.sh\|audit_mirror_checksums.sh" "$BACKUP"; then
    fail "crontab already references these scripts — nothing to do"
fi

echo
echo "===== adding ====="
{
    cat "$BACKUP"
    echo ""
    echo "# --- content integrity checks (added $STAMP) ---"
    echo "# These compare CONTENT against an independent record, unlike the nightly"
    echo "# syncs which compare size+mtime. A file corrupted in transit keeps its"
    echo "# size and mtime, which is how one sat on FleetNAS unnoticed until"
    echo "# 2026-08-28. Scripts write their own logs; stdout dropped to avoid"
    echo "# duplicate lines, stderr kept in case the script itself fails."
    echo "0 2 * * 0 $BASE/verify_immich_source_integrity.sh >/dev/null 2>>$HOME/.cache/immich-integrity/cron.log"
    echo "0 2 15 * * $BASE/audit_mirror_checksums.sh fleetnas >/dev/null 2>>$HOME/.cache/mirror-audit/cron.log"
    echo "40 2 15 * * $BASE/audit_mirror_checksums.sh macmini >/dev/null 2>>$HOME/.cache/mirror-audit/cron.log"
} > /tmp/crontab.new.$$ || fail "could not build new crontab"

crontab /tmp/crontab.new.$$ || { rm -f /tmp/crontab.new.$$; fail "crontab install failed — existing crontab untouched"; }
rm -f /tmp/crontab.new.$$

crontab -l | grep -q "verify_immich_source_integrity.sh" || {
    crontab "$BACKUP"; fail "verification failed; crontab restored from $BACKUP"
}
echo "ok: entries installed"

echo
echo "===== full backup/integrity schedule now ====="
crontab -l | grep -vE "^#|^$" | grep -E "immich|restic|syncthing|audit_mirror|nightly_summary" | sort -k2 -n
echo
echo "backup: $BACKUP"
echo "To undo:  sudo crontab $BACKUP"
