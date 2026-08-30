#!/bin/bash
# Created: 2026-08-30 UTC — daily health summary email for denniss-2nd-macbook-air (mb2),
# modeled on DennissMacBookAir/mb-nightly-summary.sh but scoped to what actually runs on
# THIS box: no comfy-fleet-scan/-http here (mb-only), so there's no scheduled-job
# freshness section — just the health-monitor TLDR + full state dump.
#
# Sends via msmtp (iCloud SMTP, ~/.msmtprc, Keychain service "msmtp-denniss-2nd-macbook-air",
# account dennis.mathes@icloud.com — passwordeval, not plaintext). 2026-08-30 setup note:
# the first passwordeval call after the Keychain item was created hung indefinitely
# waiting on a Secure-Input confirmation dialog — invisible over a Jump Desktop remote
# session even with "Allow all applications" ACL set, so it looked unfixable remotely.
# It resolved once the dialog was answered from the actual console at the right moment;
# every kickstart since (fully unattended) has returned EX_OK, so the grant is cached as
# expected for this Keychain item — this is one-time setup friction, not a per-run cost.
# Run via launchd, which gets a minimal PATH, so msmtp is called by full Homebrew path
# throughout.

MSMTP="/opt/homebrew/bin/msmtp"
TO="dennyrgood@yahoo.com"
HOST="denniss-2nd-macbook-air"
MONITOR_STATE="/tmp/denniss-2nd-macbook-air-monitor-state.tmp"
MONITOR_STALE_SECS=600   # 10 min — mb2-health-monitor runs every 5 min via launchd

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
    echo ""
    echo -e "$BODY"
} | "$MSMTP" -a icloud "$TO"
