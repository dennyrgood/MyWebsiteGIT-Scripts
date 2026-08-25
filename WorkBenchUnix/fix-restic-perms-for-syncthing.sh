#!/bin/bash
# fix-restic-perms-for-syncthing.sh — make the restic repo readable by the
# unprivileged syncthing daemon.
# Created: 2026-08-25.
#
# init-restic-repo.sh ran under `umask 077` (set to protect the passphrase
# file) and restic inherited it, so the whole repo came out root-only:
#   config     -r--------
#   data/ keys/ index/ snapshots/   drwx------
# Syncthing runs as dhm and cannot read any of that, so replication would
# connect and then transfer nothing.
#
# Making the repo readable leaks nothing that matters. Every pack is encrypted,
# and keys/ holds the master key wrapped with scrypt -- useless without the
# passphrase, which lives at /root/.restic-passphrase, root-only, and is NOT in
# the synced tree. keys/ and config MUST replicate or the s3g copy is unusable.
#
# backup_immich_to_restic.sh now sets `umask 022` explicitly so packs written
# by the nightly cron stay readable. This script repairs what already exists.

set -u

REPO="/mnt/immich-backup/restic"
SYNC_USER="dhm"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"
mountpoint -q /mnt/immich-backup || fail "/mnt/immich-backup is not mounted"
[ -d "$REPO" ] || fail "$REPO does not exist"

echo "===== before ====="
ls -la "$REPO" | head -12

echo
echo "===== applying a+rX ====="
# a+rX: read for all, execute (traverse) only on directories. Never sets +x on
# a data file.
chmod -R a+rX "$REPO" || fail "chmod failed"
echo "ok"

echo
echo "===== after ====="
ls -la "$REPO" | head -12

echo
echo "===== verifying the daemon user can actually read ====="
if sudo -u "$SYNC_USER" test -r "$REPO/config"; then
    echo "ok: $SYNC_USER can read config"
else
    fail "$SYNC_USER still cannot read $REPO/config"
fi

SAMPLE=$(find "$REPO/data" -type f | head -1)
if [ -n "$SAMPLE" ]; then
    if sudo -u "$SYNC_USER" test -r "$SAMPLE"; then
        echo "ok: $SYNC_USER can read a data pack"
    else
        fail "$SYNC_USER cannot read $SAMPLE"
    fi
fi

COUNT=$(sudo -u "$SYNC_USER" find "$REPO" -type f 2>/dev/null | wc -l)
echo "ok: $SYNC_USER can enumerate $COUNT files in the repo"

echo
echo "===== confirming restic still works as root ====="
RESTIC_PASSWORD_FILE=/root/.restic-passphrase restic -r "$REPO" snapshots 2>&1 | tail -5

echo
echo "===== done ====="
echo "Repo is now readable by $SYNC_USER. Syncthing can replicate it."
