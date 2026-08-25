#!/bin/bash
# Created: 2026-07-02 UTC
# Copies WBU's live rebuild/recovery files into the fleet-configs repo snapshot.
# Manual-run only — review `git diff` and commit yourself after running.

set -e
DEST=~/repos/fleet-configs/WorkBenchUnix

cp -p /etc/fstab "$DEST/fstab.txt"
cp -p ~/immich-app/docker-compose.yml "$DEST/docker-compose.yml"
cp -p ~/immich-app/hwaccel.ml.yml "$DEST/hwaccel.ml.yml"
cp -p ~/immich-app/.env "$DEST/.env"
crontab -l > "$DEST/crontab-l-dhm.txt"
sudo crontab -l > "$DEST/crontab-l-root.txt"

# NUT client (UPS clean-shutdown, added 2026-08-04). upsmon.conf is captured IN FULL,
# password included: it holds the credential for the `upsmon` account on this box's
# own upsd — WBU is the NUT master, the UPS is attached here (MONITOR ups2@localhost
# ... master). A redacted copy would not rebuild the box. That is only acceptable
# because fleet-configs is private — do not copy this file into the scripts repo,
# which is not. Mode 600 in the repo to match /etc/nut's 640 root:nut.
#
# 2026-08-04 UTC: corrected — this comment previously said "the `nut` account on
# FleetNAS". The NAS is not the NUT server and there is no `nut` account; upsd runs
# locally here and the account is `upsmon`.
#
# upssched.conf and upssched-cmd are deliberately NOT copied: they carry no secrets
# and are version-controlled in the scripts repo as WorkBenchUnix/nut-upssched.conf
# and nut-upssched-cmd.sh — same rule as fleet_metrics_server below.
sudo install -o "$(id -un)" -g "$(id -gn)" -m 600 /etc/nut/upsmon.conf "$DEST/nut-upsmon.conf"
sudo install -o "$(id -un)" -g "$(id -gn)" -m 644 /etc/nut/nut.conf    "$DEST/nut-nut.conf"
systemctl is-enabled nut-monitor > "$DEST/nut-monitor.enabled.txt" 2>&1 || true

# Fleet metrics server (systemd). Unit + writer + fleet_metrics_server.py are all
# version-controlled in the scripts repo (Status/), and the writer's cron line is
# captured above — so nothing new to copy. We only record that the server is a
# systemd service and whether it's enabled, so the rebuild knows to install it:
#   sudo cp ~/repos/scripts/Status/fleet_metrics_server.service /etc/systemd/system/
#   sudo systemctl enable --now fleet_metrics_server
systemctl is-enabled fleet_metrics_server > "$DEST/fleet_metrics_server.enabled.txt" 2>&1 || true


# Syncthing (added 2026-08-25). Replicates the restic repo off-site to s3g --
# see WorkBenchUnix/OFFSITE_BACKUP.md.
#
# config.xml is captured with <apikey> and <password> REDACTED, unlike
# nut-upsmon.conf above. The reasoning differs: upsmon's password is required to
# rebuild the box, whereas Syncthing's API key and GUI password are generated
# fresh on a rebuild and are needed by nothing here. syncthing_offsite_status.sh
# reads the API key from the LIVE config, never from this snapshot.
#
# Redaction is done with an XML parser and then VERIFIED -- if either secret
# survives into the output the file is deleted and the snapshot aborts. A regex
# would fail open, which for a credential is the wrong direction to fail.
#
# NOT captured: cert.pem / key.pem, which together are this box's device
# identity (VUU2OPZ...). Copying them would let a rebuilt WBU keep its device ID
# so remotes reconnect without re-pairing -- a real convenience -- but key.pem is
# a private key, and anyone holding it could impersonate this box to s3g and push
# arbitrary content into its Receive Only copy of the repo. That is a wider blast
# radius than the upsmon password, so it stays out even though fleet-configs is
# private. Consequence: a rebuilt WBU gets a NEW device ID and must be re-added
# on every remote (currently just s3g). https-cert/key are GUI-only and
# regenerate themselves.
ST_STATE="$HOME/.local/state/syncthing"
if [ -f "$ST_STATE/config.xml" ]; then
    python3 - "$ST_STATE/config.xml" "$DEST/syncthing-config.xml" <<'PYEOF'
import sys, os, xml.etree.ElementTree as ET
src, dst = sys.argv[1], sys.argv[2]
tree = ET.parse(src)
root = tree.getroot()
secrets = []
gui = root.find('gui')
if gui is not None:
    for tag in ('apikey', 'password'):
        el = gui.find(tag)
        if el is not None and el.text:
            secrets.append(el.text)
            el.text = 'REDACTED'
tree.write(dst, encoding='utf-8', xml_declaration=True)
out = open(dst, encoding='utf-8').read()
if [x for x in secrets if x and x in out]:
    os.unlink(dst)
    sys.exit("REDACTION FAILED - secret survived into output; file removed")
PYEOF
    chmod 644 "$DEST/syncthing-config.xml"

    # Human-readable topology. The XML is the record of record, but the thing you
    # actually want at 2am is "what talks to what, in which direction".
    python3 - "$DEST/syncthing-config.xml" > "$DEST/syncthing-topology.txt" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
names = {d.get('id'): d.get('name') for d in root.findall('device')}
print("Remote devices")
for d in root.findall('device'):
    addrs = ", ".join(a.text or "" for a in d.findall('address'))
    print("  %-22s %s..  addresses: %s%s" % (
        d.get('name'), (d.get('id') or "")[:7], addrs,
        "  [introducer]" if d.get('introducer') == 'true' else ""))
print()
print("Folders")
for f in root.findall('folder'):
    if not f.get('id'):
        continue
    shared = [names.get(x.get('id'), (x.get('id') or "")[:7]) for x in f.findall('device')]
    print("  %s  (%s)" % (f.get('label') or f.get('id'), f.get('id')))
    print("      path        : %s" % f.get('path'))
    print("      type        : %s" % f.get('type'))
    print("      ignorePerms : %s" % f.get('ignorePerms'))
    print("      shared with : %s" % ", ".join(shared))
    ver = f.find('versioning')
    vt = ver.get('type') if ver is not None else ''
    print("      versioning  : %s" % (vt or 'none'))
print()
g = root.find('gui')
if g is not None:
    a = g.find('address')
    print("GUI: %s  tls=%s  (apikey/password redacted)" % (
        a.text if a is not None else '?', g.get('tls')))
PYEOF

    syncthing --version 2>/dev/null | head -1 > "$DEST/syncthing-version.txt" || true
    systemctl is-enabled "syncthing@$(id -un)" > "$DEST/syncthing.enabled.txt" 2>&1 || true

    # .stignore lives inside the restic repo, which is not otherwise snapshotted.
    cp -p /mnt/immich-backup/restic/.stignore "$DEST/syncthing-restic-stignore.txt" 2>/dev/null || true
fi


# /usr/local/bin (added 2026-08-25). Small local admin scripts accumulate here
# over time and exist NOWHERE else -- not in the scripts repo, not here until
# now. A rebuild would silently lose them, and you would not notice until you
# reached for one. Found while removing the dead grub-*-windows pair after p3
# was reformatted.
#
# Only text/scripts are copied. /usr/local/bin also holds installed BINARIES
# (restic, immich-go) which are megabytes and reinstallable from upstream --
# those do not belong in a config repo. Symlinks are skipped for the same
# reason: restic-wbu points into the scripts repo, which is already versioned.
#
# The directory is cleared first so a script deleted locally shows up as a git
# deletion here rather than lingering forever. The ls -la inventory records
# EVERYTHING including the binaries and symlinks, so a rebuild knows what used
# to be here even for what was not copied.
ULB_DEST="$DEST/usr-local-bin"
ls -la /usr/local/bin > "$DEST/usr-local-bin-inventory.txt"
rm -rf "$ULB_DEST"
mkdir -p "$ULB_DEST"
find /usr/local/bin -maxdepth 1 -type f -size -100k -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -qiE 'text|script'; then
            cp -p "$f" "$ULB_DEST/"
        fi
    done

echo "Snapshot complete. Review with: cd $DEST && git status"
