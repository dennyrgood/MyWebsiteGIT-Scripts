#!/bin/bash
# ~/repos/scripts/nas/nas-nightly-summary.sh
# 2026-08-06 17:30 UTC
# 2026-08-06 19:15 UTC: fixed RAID state awk again — use field positions
#                       instead of -F': ' split which failed on this mdadm version.
# 2026-08-06 19:00 UTC: fixed RAID state awk to use -F': ' field split instead
#                       of sub() which was unreliable on multi-word state strings.
# 2026-08-06 18:30 UTC: fixed RAID state match to handle 'active' prefix
#                       (mdadm reports 'active, degraded, recovering' not
#                       'clean, degraded, recovering' during some rebuilds).
# Daily NAS health summary email. Runs at 05:00 UTC via cron.
# Covers: SMART per drive, RAID array state, NAS health monitor freshness
# and active alerts, UPS status, disk usage, and full health monitor log.
# Sends via SSH -> WBU -> msmtp.

HOST="FleetNAS"
TO="dennyrgood@yahoo.com"
WBU="dhm@192.168.178.242"
DRIVES=(sda sdb sdc)
MDADM=/sbin/mdadm
RAID_DEV=/dev/md1
UPS_NAME="ups0"
UPS_HOST="localhost"
MONITOR_STATE="/tmp/nas-monitor-state.tmp"
MONITOR_STALE_SECS=900   # 15 min; cron runs monitor every 5 min
HEALTH_LOG="/var/log/nas-health-monitor.log"

BODY=""

# --- SMART snapshot per drive ---
SMART_BAD=0
SMART_TLDR=""
BODY+="=== SMART DRIVE HEALTH ===\n"
for d in "${DRIVES[@]}"; do
    SMART_OUT=$(smartctl -A /dev/$d 2>/dev/null)
    HEALTH=$(smartctl -H /dev/$d 2>/dev/null | awk '/SMART overall-health/{print $NF}')
    REALLOC=$(echo "$SMART_OUT" | awk '$2=="Reallocated_Sector_Ct" {print $10+0}')
    PENDING=$(echo "$SMART_OUT" | awk '$2=="Current_Pending_Sector" {print $10+0}')
    TEMP=$(echo "$SMART_OUT"    | awk '$2=="Temperature_Celsius"    {print $10+0}')
    REALLOC=${REALLOC:-0}; PENDING=${PENDING:-0}; TEMP=${TEMP:-0}

    LINE="  /dev/${d}: health=${HEALTH} realloc=${REALLOC} pending=${PENDING} temp=${TEMP}°C"
    if [ "$REALLOC" -gt 0 ] || [ "$PENDING" -gt 0 ] || [ "$HEALTH" != "PASSED" ]; then
        SMART_BAD=1
        SMART_TLDR+="  ⚠️ /dev/${d}: health=${HEALTH} realloc=${REALLOC} pending=${PENDING} temp=${TEMP}°C\n"
        BODY+="${LINE}  ⚠️\n"
    else
        SMART_TLDR+="  /dev/${d}: health=${HEALTH} realloc=${REALLOC} pending=${PENDING} temp=${TEMP}°C ✓\n"
        BODY+="${LINE}  ✓\n"
    fi
done
BODY+="\n"

# --- RAID array state ---
RAID_DETAIL=$(sudo $MDADM --detail $RAID_DEV 2>/dev/null)
RAID_STATE=$(echo "$RAID_DETAIL" | awk '/State :/ && !/RaidDevice/ {print $3, $4, $5}')
RAID_REBUILD=$(echo "$RAID_DETAIL" | awk '/Rebuild Status/{print $0}')
RAID_BAD=0
RAID_TLDR=""
case "$RAID_STATE" in
    *failed*)
        RAID_BAD=1
        RAID_TLDR="  ⚠️ RAID: FAILED — ${RAID_STATE}"
        ;;
    *degraded*) 
        if [[ "$RAID_STATE" == *recovering* ]]; then
            RAID_TLDR="  RAID: rebuilding — ${RAID_STATE}"
            [ -n "$RAID_REBUILD" ] && RAID_TLDR+=" ($(echo "$RAID_REBUILD" | xargs))"
        else
            RAID_BAD=1
            RAID_TLDR="  ⚠️ RAID: DEGRADED — ${RAID_STATE}"
        fi
        ;;
    clean*|active*)
        RAID_TLDR="  RAID: ${RAID_STATE} ✓"
        ;;
    *)
        RAID_BAD=1
        RAID_TLDR="  ⚠️ RAID: unexpected state — ${RAID_STATE}"
        ;;
esac
BODY+="=== RAID ARRAY (${RAID_DEV}) ===\n${RAID_DETAIL}\n\n"

# --- Disk usage ---
DISK_OVER=$(df -h | awk 'NR>1 && $1 !~ /^\/dev\/loop/ { gsub(/%/,"",$5); if ($5+0 > 85) print $0 }')
DISK_USAGE=$(df -h | awk 'NR>1 && $1 !~ /^\/dev\/loop/ && $6=="/volume1" {print $3"/"$2" ("$5")"}')
DISK_BAD=0
DISK_TLDR="  disk /volume1: ${DISK_USAGE:-unknown} ✓"
if [ -n "$DISK_OVER" ]; then
    DISK_BAD=1
    DISK_TLDR="  ⚠️ disk usage above 85%: ${DISK_OVER}"
fi
BODY+="=== DISK USAGE ===\n"
BODY+="$(df -h | awk 'NR==1 || ($1 !~ /^\/dev\/loop/ && NF>1)')\n\n"

# --- UPS status ---
UPS_OUT=$(upsc "${UPS_NAME}@${UPS_HOST}" 2>/dev/null)
UPS_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
UPS_CHARGE=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="battery.charge"{print $2}')
UPS_LOAD=$(printf '%s\n'   "$UPS_OUT" | awk -F': ' '$1=="ups.load"{print $2}')
UPS_BAD=0
UPS_REASON=""
UPS_TLDR="  ups: ${UPS_STATUS} charge=${UPS_CHARGE}% load=${UPS_LOAD}%"
if [ -z "$UPS_STATUS" ]; then
    UPS_BAD=1; UPS_REASON="UPS unreadable"
    UPS_TLDR="  ⚠️ ups: unreadable (upsc ${UPS_NAME}@${UPS_HOST} returned nothing)"
else
    case " $UPS_STATUS " in
        *" RB "*) UPS_BAD=1; UPS_REASON="UPS replace battery"
                  UPS_TLDR="  ⚠️ ups: ${UPS_STATUS} charge=${UPS_CHARGE}% — REPLACE BATTERY" ;;
        *)        UPS_TLDR+=" ✓" ;;
    esac
fi
BODY+="=== UPS (${UPS_NAME}@${UPS_HOST}) ===\n${UPS_OUT}\n\n"

# --- Health monitor freshness ---
MONITOR_FRESH_BAD=0
MONITOR_FRESH_LINE=""
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        MONITOR_FRESH_BAD=1
        MONITOR_FRESH_LINE="  ⚠️ nas-health-monitor: stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)"
    else
        MONITOR_FRESH_LINE="  nas-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓"
    fi
else
    MONITOR_FRESH_BAD=1
    MONITOR_FRESH_LINE="  ⚠️ nas-health-monitor: state file missing ($MONITOR_STATE)"
fi

# --- Health monitor active alerts ---
MONITOR_ACTIVE_BAD=0
MONITOR_ACTIVE_LINE=""
if [ -f "$MONITOR_STATE" ]; then
    ACTIVE_ALERTS=$(grep '_ACTIVE=1$' "$MONITOR_STATE" | sed 's/_ACTIVE=1$//' | paste -sd', ' -)
    if [ -n "$ACTIVE_ALERTS" ]; then
        MONITOR_ACTIVE_BAD=1
        MONITOR_ACTIVE_LINE="  ⚠️ nas-health-monitor: active alerts: ${ACTIVE_ALERTS}"
    else
        MONITOR_ACTIVE_LINE="  nas-health-monitor: no active alerts ✓"
    fi
fi

# --- Health monitor state file ---
BODY+="=== NAS HEALTH MONITOR STATE (${MONITOR_STATE}) ===\n"
if [ -f "$MONITOR_STATE" ]; then
    BODY+="$(cat "$MONITOR_STATE")\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

# --- Full health monitor log ---
BODY+="=== NAS HEALTH MONITOR LOG (${HEALTH_LOG}) ===\n"
if [ -f "$HEALTH_LOG" ]; then
    BODY+="$(cat "$HEALTH_LOG")\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

# --- Build TLDR ---
TLDR="============================= TLDR ===============================\n"
TLDR+="${SMART_TLDR}"
TLDR+="${RAID_TLDR}\n"
TLDR+="${DISK_TLDR}\n"
TLDR+="${UPS_TLDR}\n"
TLDR+="${MONITOR_FRESH_LINE}\n"
TLDR+="${MONITOR_ACTIVE_LINE}\n"
TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

# --- Determine subject ---
OK=1
REASON="all healthy"

[ "$SMART_BAD"          -eq 1 ] && OK=0 && REASON="SMART drive error"
[ "$RAID_BAD"           -eq 1 ] && OK=0 && REASON="RAID array problem"
[ "$UPS_BAD"            -eq 1 ] && OK=0 && REASON="$UPS_REASON"
[ "$DISK_BAD"           -eq 1 ] && OK=0 && REASON="disk usage above 85%"
[ "$MONITOR_FRESH_BAD"  -eq 1 ] && OK=0 && REASON="health monitor stale/missing"
[ "$MONITOR_ACTIVE_BAD" -eq 1 ] && OK=0 && REASON="active health alerts"

if [ "$OK" -eq 1 ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} ${HOST} nightly $(date '+%Y-%m-%d') — ${REASON}"

# --- Send via SSH to WBU msmtp ---
{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | ssh -o BatchMode=yes "$WBU" "sudo msmtp --account=icloud $TO"
