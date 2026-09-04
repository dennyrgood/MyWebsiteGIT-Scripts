#!/bin/bash
# Created: 2026-08-30 UTC — daily health summary email for denniss-2nd-macbook-air (mb2),
# modeled on DennissMacBookAir/mb-nightly-summary.sh but scoped to what actually runs on
# THIS box: no comfy-fleet-scan/-http here (mb-only), so there's no scheduled-job
# freshness section — just the health-monitor TLDR + full state dump.
#
# Sends via msmtp (iCloud SMTP, ~/.msmtprc). Credential storage: plaintext app-specific
# password in ~/.msmtprc, chmod 600 — same approach as WorkBenchUnix/ChatWorkhorseUnix
# (see WorkBenchUnix/RUNBOOK_msmtp-credential-rotation.md).
#
# 2026-08-30/31 history: Keychain passwordeval was tried first. It appeared to work
# (two unattended kickstarts in a row returned EX_OK the evening it was set up), but the
# 2026-08-31 07:00 scheduled run hung for 3h44m — the login keychain's grant hadn't
# survived overnight (screen lock/sleep), and with nobody at the console to answer the
# Secure-Input prompt, the job just sat there forever with no email sent and no error
# logged. That silent-hang failure mode is worse than a bounced send, so this was
# switched to plaintext, which makes no Keychain/security call at all and structurally
# cannot hang this way. Rotate the password via the same runbook steps.
#
# Run via launchd, which gets a minimal PATH, so msmtp is called by full Homebrew path
# throughout.

MSMTP="/opt/homebrew/bin/msmtp"
TO="dennyrgood@yahoo.com"
HOST="denniss-2nd-macbook-air"
MONITOR_STATE="/tmp/denniss-2nd-macbook-air-monitor-state.tmp"
# 2026-09-04: briefly padded to 43200s (12h) after mb2 slept overnight (05:12->07:00 gap;
# StartInterval launchd jobs don't fire/catch up while asleep) and falsely flagged
# mb-health-monitor as stale — it was fine, ran clean the instant it was kicked. Root
# cause fixed at the source instead: mb2 is now `sudo pmset -a sleep 0 standby 0
# powernap 0`'d (always on AC, lid never closed), so it shouldn't sleep at all going
# forward. Reverted to a tight-ish threshold so this check is actually useful again for
# catching a same-day health-monitor failure — padded a bit past the 5-min run interval
# to absorb ordinary scheduling jitter, not to ride out sleep.
MONITOR_STALE_SECS=1800   # 30 min (6x the 5-min run interval)

OK=1
REASON="all healthy"
BODY=""

# Per-service breakdown of $MONITOR_STATE for the TLDR — reads the same
# MISSING_${svc}_ACTIVE/DOWN_${svc}_ACTIVE keys mb2-health-monitor.sh already writes.
svc_status() {
    local svc=$1
    local missing down
    missing=$(grep "^MISSING_${svc}_ACTIVE=" "$MONITOR_STATE" 2>/dev/null | cut -d= -f2)
    down=$(grep "^DOWN_${svc}_ACTIVE=" "$MONITOR_STATE" 2>/dev/null | cut -d= -f2)
    if [ "$missing" = "1" ]; then
        echo "⚠️ MISSING"
    elif [ "$down" = "1" ]; then
        echo "⚠️ NOT RESPONDING"
    else
        echo "✓"
    fi
}

# --- Health monitor watchdog (freshness + active alerts) in TLDR ---
TLDR="============================= TLDR ===============================\n"
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -f %m "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        TLDR+="  mb2-health-monitor: ⚠️ stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)\n"
        OK=0; REASON="health monitor stale/missing"
    else
        TLDR+="  mb2-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓\n"
    fi
    MONITOR_ACTIVE=$(grep "_ACTIVE=1" "$MONITOR_STATE" 2>/dev/null)
    if [ -n "$MONITOR_ACTIVE" ]; then
        TLDR+="  mb2-health-monitor: ⚠️ active alerts\n"
        [ "$OK" -eq 1 ] && { OK=0; REASON="active health alerts"; }
    else
        TLDR+="  mb2-health-monitor: no active alerts ✓\n"
    fi
    TLDR+="    metrics-server:    $(svc_status METRICS_SERVER)\n"
    TLDR+="    heartbeat-writer:  $(svc_status HEARTBEAT_WRITER)\n"
    TLDR+="    travel-http:       $(svc_status TRAVEL_HTTP)\n"
else
    TLDR+="  mb2-health-monitor: ⚠️ state file missing ($MONITOR_STATE)\n"
    OK=0; REASON="health monitor stale/missing"
fi

TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

# --- Health monitor state (full dump, appended at the end) ---
BODY+="=== HEALTH MONITOR STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    if [ -n "$MONITOR_ACTIVE" ]; then
        BODY+="ACTIVE ALERTS:\n$MONITOR_ACTIVE\n"
    else
        BODY+="No active alerts.\n"
    fi
    BODY+="\n$(cat "$MONITOR_STATE")\n"
else
    BODY+="⚠️ WARNING: state file not found — health monitor has not run\n"
fi

if [ "$OK" -eq 1 ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} MacBook Air 2 nightly $(date '+%Y-%m-%d') — ${REASON}"

{
    echo "Subject: $SUBJECT"
    # 2026-08-31 UTC — Cc self, nightly-summary only — see DennissMacBookAir's version
    # for the full rationale (feeds a separate daily digest script).
    echo "Cc: dennis.mathes@icloud.com"
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO" dennis.mathes@icloud.com
