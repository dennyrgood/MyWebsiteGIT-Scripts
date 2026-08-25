#!/bin/bash
# mount-esp.sh — add the EFI System Partition to /etc/fstab and mount it.
# Created: 2026-08-25.
#
# Why: nvme0n1p1 (the ESP) has the GPT no-automount attribute set, so systemd
# never mounts it and /boot/efi has been an empty directory. The boot stack on
# the ESP is currently intact, but grub-efi/shim package updates have had
# nowhere to write, so it will drift. This pins it in fstab.
#
# Safety: backs up fstab first, validates with `mount -a`, and rolls the
# backup back automatically if anything fails. Does not touch the ESP contents.

set -u

ESP_UUID="1A00-4C49"
MP="/boot/efi"
FSTAB="/etc/fstab"
STAMP=$(date +%Y-%m-%d_%H%M)
BACKUP="/etc/fstab.bak.$STAMP"
LINE="UUID=$ESP_UUID  $MP  vfat  umask=0077,shortname=winnt,nofail,x-systemd.device-timeout=5  0  1"

fail() { echo; echo "FAILED: $*"; exit 1; }

rollback() {
    echo "!! rolling back $FSTAB from $BACKUP"
    cp -a "$BACKUP" "$FSTAB"
    systemctl daemon-reload 2>/dev/null
    echo "!! fstab restored. System is as it was before this script ran."
}

[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"

echo "===== preconditions ====="

# 1. the UUID we are about to write must actually be the ESP
ACTUAL=$(blkid -s UUID -o value /dev/nvme0n1p1 2>/dev/null)
[ "$ACTUAL" = "$ESP_UUID" ] || fail "nvme0n1p1 UUID is '$ACTUAL', expected '$ESP_UUID'"
echo "ok: nvme0n1p1 UUID matches $ESP_UUID"

FSTYPE=$(blkid -s TYPE -o value /dev/nvme0n1p1 2>/dev/null)
[ "$FSTYPE" = "vfat" ] || fail "nvme0n1p1 is type '$FSTYPE', expected vfat"
echo "ok: filesystem is vfat"

# 2. no existing entry for this mountpoint
if grep -qE "^[^#]*[[:space:]]$MP[[:space:]]" "$FSTAB"; then
    fail "$FSTAB already has an active entry for $MP — nothing to do"
fi
echo "ok: no existing $MP entry in fstab"

# 3. mountpoint must exist and be empty
[ -d "$MP" ] || fail "$MP does not exist"
if mountpoint -q "$MP"; then fail "$MP is already mounted"; fi
if [ -n "$(ls -A "$MP" 2>/dev/null)" ]; then
    fail "$MP is not empty — refusing to mount over existing files"
fi
echo "ok: $MP exists, is empty, and is not mounted"

echo
echo "===== backing up fstab ====="
cp -a "$FSTAB" "$BACKUP" || fail "could not back up $FSTAB"
echo "ok: $BACKUP"

echo
echo "===== appending entry ====="
{
    echo ""
    echo "# $STAMP: ESP pinned so grub-efi/shim updates can reach it."
    echo "# p1 has the GPT no-automount attribute, so systemd will not mount it on its own."
    echo "$LINE"
} >> "$FSTAB" || { rollback; fail "could not write to $FSTAB"; }
echo "added:"
echo "  $LINE"

echo
echo "===== validating ====="
systemctl daemon-reload 2>/dev/null

if ! findmnt --verify --verbose 2>&1 | tail -20; then
    echo "(findmnt --verify reported problems above)"
fi

if ! mount -a 2>&1; then
    rollback
    fail "'mount -a' returned an error — see message above"
fi

if ! mountpoint -q "$MP"; then
    rollback
    fail "$MP still not mounted after 'mount -a'"
fi
echo "ok: $MP is mounted"

echo
echo "===== confirming the boot stack is visible ====="
if [ -f "$MP/EFI/ubuntu/grubx64.efi" ] && [ -f "$MP/EFI/ubuntu/shimx64.efi" ]; then
    echo "ok: EFI/ubuntu/grubx64.efi and shimx64.efi present"
else
    echo "WARNING: expected grub/shim files not found under $MP/EFI/ubuntu/"
    echo "         (mount succeeded, but check the contents before rebooting)"
fi
ls -la "$MP/EFI/" 2>/dev/null
df -h "$MP" | tail -1

echo
echo "===== result ====="
echo "fstab backup: $BACKUP"
echo "To undo:  sudo cp -a $BACKUP /etc/fstab && sudo umount $MP"
echo
echo "NOT rebooted. Reboot when convenient to confirm it mounts cleanly at boot."
