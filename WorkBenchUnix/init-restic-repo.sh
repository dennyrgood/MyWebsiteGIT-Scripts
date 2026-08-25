#!/bin/bash
# init-restic-repo.sh — create the restic repo and its passphrase file.
# Created: 2026-08-25.
#
# The passphrase is read with `read -s` and written straight to a root-only
# file. It is never echoed, never passed as a command-line argument (so it
# cannot appear in `ps` or shell history), and never printed. Nothing about
# it reaches a terminal transcript.
#
# restic has no unencrypted mode. Lose this passphrase and the repo is
# unrecoverable by design -- there is no reset, no recovery key, no support
# channel. Record it somewhere that survives this building being lost.

set -u
umask 077

REPO="/mnt/immich-backup/restic"
MOUNT="/mnt/immich-backup"
PASSFILE="/root/.restic-passphrase"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"
command -v restic >/dev/null || fail "restic not found on PATH"

echo "===== preconditions ====="

mountpoint -q "$MOUNT" || fail "$MOUNT is not mounted — refusing to init into the root filesystem"
echo "ok: $MOUNT is mounted"

[ -d "$REPO" ] || fail "$REPO does not exist"
if [ -n "$(ls -A "$REPO" 2>/dev/null)" ]; then
    fail "$REPO is not empty — a repo may already exist here. Refusing."
fi
echo "ok: $REPO exists and is empty"

if [ -e "$PASSFILE" ]; then
    fail "$PASSFILE already exists — refusing to overwrite an existing passphrase"
fi
echo "ok: no existing passphrase file"

echo "ok: restic $(restic version | awk '{print $2}')"

echo
echo "=================================================================="
echo " Choose a passphrase for the restic repository."
echo
echo " It will NOT be displayed as you type, and will NOT be printed"
echo " anywhere afterwards. It is written only to $PASSFILE (root, 0600)."
echo
echo " Pick something memorable -- a few unrelated words. The point is"
echo " that you can still type it in Gran Canaria in two years, not that"
echo " it resists an attacker. Encryption here is mandatory, not desired."
echo "=================================================================="
echo

printf "Passphrase: "
read -rs PASS1
echo
printf "Again to confirm: "
read -rs PASS2
echo

[ -n "$PASS1" ] || fail "empty passphrase — aborting"
[ "$PASS1" = "$PASS2" ] || fail "the two entries did not match — aborting, nothing was written"

if [ "${#PASS1}" -lt 12 ]; then
    echo
    echo "WARNING: that passphrase is under 12 characters."
    printf "Type YES to use it anyway: "
    read -r SHORTOK
    [ "$SHORTOK" = "YES" ] || fail "aborted — nothing was written"
fi

echo
echo "===== writing passphrase file ====="
printf '%s' "$PASS1" > "$PASSFILE" || fail "could not write $PASSFILE"
chown root:root "$PASSFILE"
chmod 0600 "$PASSFILE"
unset PASS1 PASS2
echo "ok: $PASSFILE ($(stat -c '%U:%G %a' "$PASSFILE"))"

echo
echo "===== initialising repository ====="
# --repository-version 2 is the default in 0.19 and enables compression.
# Worth having: the postgres dumps are plain SQL and compress hard. The
# JPEGs will not compress at all, which is expected and fine.
if ! restic init -r "$REPO" --password-file "$PASSFILE"; then
    echo
    echo "!! init failed — removing the passphrase file so this can be rerun cleanly"
    rm -f "$PASSFILE"
    fail "restic init failed"
fi

echo
echo "===== verifying ====="
restic -r "$REPO" --password-file "$PASSFILE" cat config
echo
echo "snapshots (should be an empty list):"
restic -r "$REPO" --password-file "$PASSFILE" snapshots

echo
echo "===== result ====="
du -sh "$REPO"
echo
echo "Repo:       $REPO"
echo "Passphrase: $PASSFILE  (root-only)"
echo
echo "-------------------------------------------------------------------"
echo " STILL OUTSTANDING: an off-site copy of the passphrase."
echo " $PASSFILE lives on the same machine as the source data."
echo " If Amsterdam is lost, the s3g copy of this repo is undecryptable"
echo " without a passphrase record that is NOT in Amsterdam."
echo "-------------------------------------------------------------------"
