#!/bin/sh
# Route root/local system-mail (sudo auth alerts, cron job errors, smartd/mdadm
# events) to a real address so it DELIVERS instead of bouncing at iCloud with
# 504 "need fully-qualified address". Also tightens /etc/msmtprc perms — it holds
# the SMTP password in plaintext and was world-readable (644).
# Run as a normal user (it calls sudo itself):  sh install.msmtp.aliases.sh
# 2026-07-23.
set -e

ALIASES_SRC=/home/dhm/repos/scripts/ChatWorkhorseUnix/etc-aliases
ALIASES_DST=/etc/aliases
MSMTPRC=/etc/msmtprc

echo "1. Installing $ALIASES_DST ..."
sudo install -m 0644 "$ALIASES_SRC" "$ALIASES_DST"

echo "2. Adding 'aliases $ALIASES_DST' to the $MSMTPRC defaults block (if absent) ..."
if sudo grep -qE '^[[:space:]]*aliases[[:space:]]' "$MSMTPRC"; then
    echo "   (an aliases directive is already present — leaving it)"
else
    sudo sed -i "/^[[:space:]]*defaults[[:space:]]*\$/a\\    aliases $ALIASES_DST" "$MSMTPRC"
fi

echo "3. Restricting $MSMTPRC to root (600) — it contains the SMTP password ..."
sudo chmod 600 "$MSMTPRC"

echo "4. Verifying ..."
echo "   --- $ALIASES_DST ---"
sudo grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ALIASES_DST"
echo "   --- $MSMTPRC (defaults + aliases line) ---"
sudo grep -nE '^[[:space:]]*(defaults|aliases)' "$MSMTPRC"
echo "   --- perms ---"
sudo ls -la "$MSMTPRC"

echo "5. Sending a test message to root (should now deliver to the aliased address) ..."
printf 'To: root\nSubject: [%s] msmtp root-alias test\n\nIf this arrives, root-mail aliasing works.\n' "$(hostname)" \
    | sudo /usr/sbin/sendmail -i root
echo "   Sent. Confirm with:  tail -1 /var/log/msmtp.log   (expect recipients=dennyrgood@yahoo.com exitcode=EX_OK)"
