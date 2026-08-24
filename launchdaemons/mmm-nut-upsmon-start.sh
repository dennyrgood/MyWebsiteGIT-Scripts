#!/bin/bash
# mmm-nut-upsmon-start.sh
# Wrapper invoked by com.dennis.mmm-nut-upsmon.plist instead of running upsmon
# directly, so a stale PID file can't block startup after a reboot.
#
# 2026-08-24 real incident: after a reboot, upsmon failed to start for ~10 minutes
# (60 consecutive "Fatal error: A previous upsmon instance is already running!" in
# /Library/Logs/mmm_nut_upsmon.log) even though no other upsmon process existed at
# all. Cause: /opt/homebrew/var/run/upsmon.pid (confirmed via `strings upsmon` as
# the real --with-pidpath, not the unused /opt/homebrew/var/state/ups) survived from
# before the reboot -- upsmon has no shutdown hook that unlinks it -- and upsmon's
# own startup check only tests whether that PID NUMBER currently belongs to ANY live
# process, not specifically to upsmon. Early in a fresh boot, low PIDs get reused
# fast by ordinary system processes, so the stale number collided with something
# unrelated and upsmon refused to start until enough KeepAlive retries happened to
# outlast the false collision. The box had no shutdown protection for that entire
# window.
#
# Fix: before starting, check whether the recorded PID actually IS upsmon right now
# -- if not, the file is stale and safe to remove. Deliberately does NOT blindly rm
# the file unconditionally: if a real second upsmon instance is genuinely already
# running (e.g. this wrapper somehow got invoked twice), deleting the file and
# starting a third would be worse than the fault this exists to fix -- in that case
# this exits 1 and lets upsmon's own refusal stand.

PIDFILE="/opt/homebrew/var/run/upsmon.pid"
UPSMON="/opt/homebrew/sbin/upsmon"

if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -qi upsmon; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') mmm-nut-upsmon-start.sh: PID $OLD_PID is a live upsmon process -- not starting a second instance" >&2
        exit 1
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') mmm-nut-upsmon-start.sh: stale/corrupt PID file (contents: '${OLD_PID}', not a live upsmon) -- removing" >&2
    rm -f "$PIDFILE"
fi

exec "$UPSMON" -F
