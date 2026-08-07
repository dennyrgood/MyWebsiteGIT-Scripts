#!/bin/bash
# ~/repos/scripts/FleetNAS/fleetnas-snapshot-fleet-configs.sh
# Created: 2026-08-07 UTC
# Copies FleetNAS's live rebuild/recovery files into the fleet-configs snapshot.
# Manual-run only — review `git diff` and commit yourself after running.
#
# Run ON FleetNAS:   ~/repos/scripts/FleetNAS/fleetnas-snapshot-fleet-configs.sh
# Needs sudo for root's crontab and a couple of root-only files, so run it from a
# real session on the box — sudo over non-interactive ssh cannot prompt.
#
# WHY THIS BOX IS DIFFERENT FROM THE OTHER UBUNTU BOXES:
# FleetNAS is a UGREEN appliance. Everything under / is an overlay on the OS
# disk, and a firmware update can reset it. $HOME is a btrfs subvolume on the
# RAID array and survives. So the whole point of this snapshot is the things on
# the OVERLAY — root's crontab above all, because if that is lost both
# monitoring scripts survive intact but nothing runs them, and "no email" is
# also exactly what a healthy NAS looks like.
#
# NOT COPIED — already version-controlled in the (public) scripts repo, same
# rule as WBU's fleet_metrics_server and upssched files:
#   nas/nas-health-monitor.sh, nas/nas-nightly-summary.sh,
#   nas/logrotate-nas-health-monitor, nas/install-git-nas.sh, nas/root-crontab
# Those are recovered by cloning `scripts`, not from here.

set -e

# Optional first argument: a subdirectory under NAS/ to write into instead of
# NAS/ itself. Used to capture before/after state around a risky operation, e.g.
#   ./fleetnas-snapshot-fleet-configs.sh cutover-1.17-to-1.18/before
#   ./fleetnas-snapshot-fleet-configs.sh cutover-1.17-to-1.18/after
# With no argument it writes the normal rolling snapshot into NAS/.
DEST=~/repos/fleet-configs/FleetNAS${1:+/$1}

BASE=~/repos/fleet-configs/FleetNAS
if [ ! -d ~/repos/fleet-configs ]; then
    echo "❌ fleet-configs is not cloned on this box."
    echo "     cd ~/repos && git clone https://github.com/dennyrgood/fleet-configs.git"
    echo "   (private repo — you will be asked for your GitHub username and PAT)"
    exit 1
fi
# Base dir must be deliberate; sub-dirs (before/after captures) are created here.
if [ ! -d "$BASE" ]; then
    echo "❌ $BASE does not exist. Create it first:  mkdir -p $BASE"
    exit 1
fi
mkdir -p "$DEST"

ME_U=$(id -un); ME_G=$(id -gn)

# --- Crontabs -------------------------------------------------------------
# root's is the critical artifact on this box. nas/root-crontab in the scripts
# repo is a hand-maintained twin of this file: same content, different
# durability. This copy is authoritative and lives on OTHER machines; that one
# lives on the NAS's own RAID volume and restores with no dependency on
# anything else. Keep both; if they ever disagree, THIS one is live truth.
crontab -l > "$DEST/crontab-l-dhm.txt" 2>/dev/null || echo "(no crontab for $ME_U)" > "$DEST/crontab-l-dhm.txt"
sudo crontab -l > "$DEST/crontab-l-root.txt"

# --- NUT ------------------------------------------------------------------
# FleetNAS has its OWN UPS: ups0, driver nutdrv_qx over USB, upsd running
# locally. This is NOT a copy of WBU's config — WBU is master for ups2 with its
# own separate UPS. Captured in full, credentials included, because a redacted
# copy would not rebuild the box; that is only acceptable because fleet-configs
# is PRIVATE. Do not copy these into the scripts repo, which is public.
# Mode 600 in the repo regardless of the (loose) source permissions.
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf upssched.conf; do
    [ -f "/etc/nut/$f" ] && sudo install -o "$ME_U" -g "$ME_G" -m 600 "/etc/nut/$f" "$DEST/nut-$f"
done
# UGREEN's own UPS service config (root-only at source).
[ -f /etc/nut/ups_server.json ] && sudo install -o "$ME_U" -g "$ME_G" -m 600 /etc/nut/ups_server.json "$DEST/nut-ups_server.json"

# --- SSH ------------------------------------------------------------------
# authorized_keys only. Root's PRIVATE key is deliberately NOT captured: it is
# what lets the monitoring scripts ssh to WBU to send mail, and a private key in
# a repo is a different risk class from a NUT password. To rebuild that hop:
#   1. on FleetNAS:  sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
#   2. append the new /root/.ssh/id_ed25519.pub to dhm's
#      ~/.ssh/authorized_keys on WBU (192.168.178.242)
#   3. verify:  sudo ssh -o BatchMode=yes dhm@192.168.178.242 true
sudo install -o "$ME_U" -g "$ME_G" -m 600 /root/.ssh/authorized_keys "$DEST/root-authorized_keys.txt" 2>/dev/null || \
    echo "(none)" > "$DEST/root-authorized_keys.txt"
install -m 644 ~/.ssh/authorized_keys "$DEST/dhm-authorized_keys.txt" 2>/dev/null || true

# --- Storage identity -----------------------------------------------------
# Reference for reassembling or identifying the array elsewhere. You would not
# normally rebuild a UGREEN array by hand, but the UUID, layout and chunk size
# are exactly what you would need if you ever had to.
cp -p /etc/fstab "$DEST/fstab.txt"
cp -p /etc/mdadm/mdadm.conf "$DEST/mdadm.conf" 2>/dev/null || true
{
    echo "# captured $(date -u '+%Y-%m-%d %H:%M UTC') by $(basename "$0")"
    echo "## mdadm --detail --scan"; sudo /sbin/mdadm --detail --scan 2>&1
    echo; echo "## mdadm --detail /dev/md1"; sudo /sbin/mdadm --detail /dev/md1 2>&1
    echo; echo "## /proc/mdstat"; cat /proc/mdstat
    echo; echo "## lsblk"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>&1
    echo; echo "## blkid"; sudo blkid 2>&1
    echo; echo "## LVM"; sudo pvs 2>&1; sudo vgs 2>&1; sudo lvs 2>&1
} > "$DEST/storage-layout.txt"

# --- Appliance identity ---------------------------------------------------
{
    echo "# captured $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "hostname: $(hostname)"
    echo; echo "## /etc/os-release"; cat /etc/os-release
    echo; echo "## kernel"; uname -a
    # UGOS records its version NOWHERE standard — no /etc/*-release entry, no
    # ugreen dpkg package, nothing under /usr/share. The only reliable source is
    # UGREEN's own conf_tool binary. As of 2026-08-07 this box reports
    # BuildVersion 1.17.0.0103 (BuildTime 2026-06-30).
    echo; echo "## UGOS version (conf_tool -V)"
    /usr/sbin/conf_tool -V 2>&1 || echo "(conf_tool not available)"
    echo; echo "## /etc/issue"; cat /etc/issue 2>/dev/null
} > "$DEST/appliance-identity.txt"

# Full package list. Cheap, and the reason it earns its place here: diffing this
# across a UGREEN firmware update shows exactly what the vendor changed.
dpkg -l > "$DEST/dpkg-l.txt"

# --- Things that must be re-installed by hand after a firmware reset -------
{
    echo "# Written by $(basename "$0") — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "# Overlay-resident things that a firmware update can wipe, and how to"
    echo "# put them back. The scripts themselves are safe: ~/repos is on the RAID"
    echo "# volume. These are the bits that live on the OS disk."
    echo
    echo "1. root crontab  (WITHOUT THIS, MONITORING SILENTLY STOPS)"
    echo "     sudo crontab ~/repos/scripts/FleetNAS/root-crontab"
    echo "     sudo crontab -l          # verify"
    echo "   Symptom if missing: the 05:00 UTC nightly email simply never arrives."
    echo
    echo "2. logrotate config for the health monitor log"
    echo "     cd ~/repos/scripts/FleetNAS"
    echo "     sudo cp logrotate-nas-health-monitor /etc/logrotate.d/nas-health-monitor"
    echo "     sudo chown root:root /etc/logrotate.d/nas-health-monitor"
    echo "     sudo chmod 644 /etc/logrotate.d/nas-health-monitor"
    echo
    echo "3. root's ssh key to WBU (mail relay) — see nut/ssh notes in the"
    echo "   snapshot script; the private key is deliberately not stored here."
    echo
    echo "4. native git — only if ~/git is somehow lost (it is on the RAID"
    echo "   volume, so it should survive):"
    echo "     ~/repos/scripts/FleetNAS/install-git-nas.sh"
} > "$DEST/RESTORE-AFTER-FIRMWARE.md"

echo "Snapshot complete. Review with: cd $DEST && git status && git diff"
echo "Reminder: do NOT commit fleet-configs without reviewing the diff first."
