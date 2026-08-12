#!/bin/bash
# Created: 2026-08-04 UTC — installs the NUT client on ChatWorkhorseUnix so the VM
# shuts itself down cleanly, five minutes into an outage, before its Windows host
# begins shutting down at eight.
#
# Run ON CWHU as: sudo bash setup-nut-client.sh
#
# The monslave password is read with `read -s` — never echoed, never passed as an
# argument (which would put it in ps output and shell history). Get it from WBU with:
#     sudo grep -A1 monslave /etc/nut/upsd.users
set -euo pipefail

R="/home/dhm/repos/scripts"
CWHU="$R/ChatWorkhorseUnix"
STAMP="$(date -u +%Y-%m-%d)"

if [ "$(hostname | tr '[:upper:]' '[:lower:]')" != "chatworkhorseunix" ]; then
    echo "REFUSING: this is $(hostname), not chatworkhorseunix." >&2
    echo "This config points at ups2 on WBU and assumes CWHU's 5-minute timer." >&2
    exit 1
fi

for f in "$CWHU/nut-upsmon.template.conf" "$CWHU/nut-upssched.conf" \
         "$R/WorkBenchUnix/nut-upssched-cmd.sh" "$R/clean.ubuntu.shutdown"; do
    [ -f "$f" ] || { echo "MISSING: $f  (git pull in $R?)" >&2; exit 1; }
done

# The whole point of this client is to invoke clean.ubuntu.shutdown. If that is not
# executable the shutdown silently does nothing, so fail now rather than during an
# outage.
[ -x "$R/clean.ubuntu.shutdown" ] || { echo "NOT EXECUTABLE: $R/clean.ubuntu.shutdown" >&2; exit 1; }

echo "==> Checking WorkBenchUnix is reachable on 3493..."
if ! timeout 5 bash -c '</dev/tcp/192.168.178.242/3493' 2>/dev/null; then
    echo "WARNING: cannot reach 192.168.178.242:3493 from here." >&2
    echo "         If this VM is NAT'd, outbound should still work — check WBU is up." >&2
    read -rp "Continue anyway? [y/N] " cont
    case "$cont" in [yY]*) ;; *) exit 1 ;; esac
fi

echo "==> Installing nut-client..."
apt-get install -y nut-client

echo "==> Backing up current /etc/nut..."
for f in /etc/nut/*.conf; do
    case "$f" in *.bak.*) continue ;; esac
    [ -f "$f" ] || continue
    [ -f "$f.bak.$STAMP" ] || cp -p "$f" "$f.bak.$STAMP"
done

# -s so it is not echoed to the terminal, and therefore never reaches a transcript
# or a session log. Not a script argument, which would expose it in `ps`.
echo
read -rsp "monslave password (from WBU's /etc/nut/upsd.users): " PW
echo
[ -n "$PW" ] || { echo "Empty password — aborting." >&2; exit 1; }

echo "==> Writing upsmon.conf (640 root:nut)..."
umask 077
sed "s|__PASSWORD__|$PW|" "$CWHU/nut-upsmon.template.conf" > /etc/nut/upsmon.conf
chown root:nut /etc/nut/upsmon.conf
chmod 640 /etc/nut/upsmon.conf
umask 022
unset PW

echo "==> Installing upssched.conf, upssched-cmd, nut.conf..."
install -o root -g nut  -m 640 "$CWHU/nut-upssched.conf"           /etc/nut/upssched.conf
install -o root -g root -m 755 "$R/WorkBenchUnix/nut-upssched-cmd.sh" /etc/nut/upssched-cmd
printf '# CWHU is a NUT client of ups2 on WorkBenchUnix. No local UPS.\nMODE=netclient\n' > /etc/nut/nut.conf
chown root:nut /etc/nut/nut.conf
chmod 640 /etc/nut/nut.conf

echo "==> Enabling and (re)starting nut-monitor..."
# `enable --now` is a no-op on an already-active service, so on a second/third run
# of this script it would leave upsmon running against the OLD upsmon.conf (and
# therefore the old password) even though a new one was just written. Always
# `restart` explicitly so a rerun actually picks up the new config.
systemctl enable nut-monitor
systemctl restart nut-monitor
sleep 4

echo
echo "==> Result:"
echo "    enabled: $(systemctl is-enabled nut-monitor 2>&1)"
echo "    active:  $(systemctl is-active  nut-monitor 2>&1)"
echo
echo "==> Did it authenticate? (any ACCESS-DENIED here means a wrong password)"
journalctl -u nut-monitor -n 12 --no-pager 2>&1 | grep -viE 'password' | tail -12

echo
echo "==> Live UPS read (proves CWHU can see the UPS powering its host):"
upsc ups2@192.168.178.242 2>&1 | grep -E 'ups.status|battery.charge:|ups.load' || \
    echo "    FAILED - see: journalctl -u nut-monitor -n 40"

cat <<'NEXT'

==> STILL TO VERIFY: that the notify path fires.

    This cannot be tested from here. A fresh upsmon start never emits COMMOK — only
    a connection that DROPS and RETURNS does. CWHU has no local upsd to bounce, so
    the pair has to be forced from the server side.

    On WorkBenchUnix, run:
        sudo systemctl restart nut-server

    Then back on CWHU:
        journalctl -t upssched-cmd -n 5 --no-pager

    A SELFTEST line means NOTIFYCMD -> upssched -> upssched-cmd works and the
    5-minute timer will arm. No line means it will not, and this VM would sit on
    battery until its host shut down on top of it.

    Full live test, watching both sides:
        journalctl -f -t nut-monitor -t upssched-cmd
    (two -t flags OR together; mixing -u and -t ANDs them and shows nothing)
NEXT
