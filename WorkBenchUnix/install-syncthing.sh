#!/bin/bash
# install-syncthing.sh — install Syncthing from upstream's apt repo and prepare
# the restic repo for replication to s3g.
# Created: 2026-08-25.
#
# Runs the daemon as dhm, not root. That is safe here because the restic repo
# is encrypted: an unprivileged reader gets ciphertext. The passphrase lives at
# /root/.restic-passphrase, outside the synced folder, and stays root-only.
#
# Ubuntu ships 1.27.2; upstream's repo is current and gets security updates
# faster, which matters for something that speaks to the internet.
#
# This installs and prepares only. Folder setup happens in the GUI afterwards,
# because pairing needs the s3g end anyway.

set -u

SYNC_USER="dhm"
REPO_DIR="/mnt/immich-backup/restic"
KEYRING="/etc/apt/keyrings/syncthing-archive-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/syncthing.list"

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"
id "$SYNC_USER" >/dev/null 2>&1 || fail "user $SYNC_USER does not exist"
mountpoint -q /mnt/immich-backup || fail "/mnt/immich-backup is not mounted"
[ -d "$REPO_DIR" ] || fail "$REPO_DIR does not exist"

echo "===== adding upstream apt repo ====="
install -d -m 0755 /etc/apt/keyrings
if [ ! -f "$KEYRING" ]; then
    curl -fsSL --max-time 60 https://syncthing.net/release-key.gpg \
        | gpg --dearmor -o "$KEYRING" || fail "could not fetch signing key"
    chmod 0644 "$KEYRING"
    echo "ok: $KEYRING"
else
    echo "ok: keyring already present"
fi

echo "deb [signed-by=$KEYRING] https://apt.syncthing.net/ syncthing stable" > "$SOURCES"
echo "ok: $SOURCES"

echo
echo "===== installing ====="
apt-get update -qq || fail "apt-get update failed"
DEBIAN_FRONTEND=noninteractive apt-get install -y syncthing || fail "install failed"
syncthing --version | head -1

echo
echo "===== preparing the restic repo for replication ====="
# 0700 -> 0755. Safe: the contents are encrypted, and this is what lets the
# unprivileged daemon read them without granting it root.
chmod 0755 "$REPO_DIR"
echo "ok: $REPO_DIR is now $(stat -c '%a %U:%G' "$REPO_DIR")"

# Syncthing refuses to sync a folder without this marker, and a Send Only
# folder otherwise never writes -- so pre-create it owned by the daemon user.
if [ ! -d "$REPO_DIR/.stfolder" ]; then
    mkdir -p "$REPO_DIR/.stfolder"
    echo "ok: created .stfolder"
fi
chown "$SYNC_USER:$SYNC_USER" "$REPO_DIR/.stfolder"
echo "ok: .stfolder owned by $SYNC_USER"

# restic takes a lock for every operation. Replicating locks means a stale one
# can land on the s3g copy and block a restore from it -- exactly when you would
# least want an obstacle. The repo data itself is append-only, which is why the
# rest of this tree suits Syncthing so well.
cat > "$REPO_DIR/.stignore" <<'IGNORE'
// restic lock files: transient, and a replicated stale lock would obstruct a
// restore at the far end. The rest of the repo is immutable packs, ideal for
// Syncthing.
/locks
IGNORE
chown "$SYNC_USER:$SYNC_USER" "$REPO_DIR/.stignore"
echo "ok: .stignore written (excludes /locks)"

echo
echo "===== enabling the service ====="
systemctl enable "syncthing@$SYNC_USER.service" >/dev/null 2>&1 \
    || fail "could not enable syncthing@$SYNC_USER"
systemctl restart "syncthing@$SYNC_USER.service" || fail "could not start syncthing"
sleep 3
systemctl is-active --quiet "syncthing@$SYNC_USER.service" \
    || fail "service is not active — check: journalctl -u syncthing@$SYNC_USER"
echo "ok: syncthing@$SYNC_USER is running"

echo
echo "===== this machine's device ID ====="
# Needed on the s3g end to pair. Not a secret -- it is a public key fingerprint.
sudo -u "$SYNC_USER" syncthing --device-id 2>/dev/null \
    || echo "(run: sudo -u $SYNC_USER syncthing --device-id)"

echo
echo "===== GUI ====="
echo "The GUI listens on 127.0.0.1:8384 and is NOT exposed to the network."
echo "Reach it from your Mac with an SSH tunnel:"
echo
echo "    ssh -L 8384:localhost:8384 wbu"
echo
echo "then open http://localhost:8384"
