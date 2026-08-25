#!/bin/bash
# install-restic.sh — install the official restic binary to /usr/local/bin.
# Created: 2026-08-25.
#
# Uses the upstream release rather than apt, which ships 0.16.4 on noble.
# Rationale: the restic repo built here must be readable by restic on s3g
# (Windows), so both ends should run the same current version.
#
# Verifies the download against upstream's published SHA256SUMS before
# installing. Installs to /usr/local/bin so apt never fights it.

set -eu

VERSION="0.19.1"
ARCH="linux_amd64"
BASE="https://github.com/restic/restic/releases/download/v${VERSION}"
FILE="restic_${VERSION}_${ARCH}.bz2"
DEST="/usr/local/bin/restic"
WORK=$(mktemp -d)

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo; echo "FAILED: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"

echo "===== downloading restic ${VERSION} ====="
curl -fsSL --max-time 120 -o "$WORK/$FILE" "$BASE/$FILE" \
    || fail "could not download $FILE"
curl -fsSL --max-time 60 -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS" \
    || fail "could not download SHA256SUMS"
echo "ok: $FILE and SHA256SUMS"

echo
echo "===== verifying checksum ====="
EXPECTED=$(grep " $FILE\$" "$WORK/SHA256SUMS" | awk '{print $1}')
[ -n "$EXPECTED" ] || fail "$FILE not listed in SHA256SUMS"
ACTUAL=$(sha256sum "$WORK/$FILE" | awk '{print $1}')
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "  expected: $EXPECTED"
    echo "  actual:   $ACTUAL"
    fail "CHECKSUM MISMATCH — refusing to install"
fi
echo "ok: sha256 matches upstream ($ACTUAL)"

echo
echo "===== installing ====="
bunzip2 -c "$WORK/$FILE" > "$WORK/restic" || fail "could not decompress"
chmod 0755 "$WORK/restic"
install -o root -g root -m 0755 "$WORK/restic" "$DEST" || fail "could not install to $DEST"
echo "ok: $DEST"

echo
echo "===== confirming ====="
"$DEST" version
echo
echo "which restic -> $(command -v restic || echo '(not on PATH for this shell)')"
