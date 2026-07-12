#!/bin/bash
# /home/dhm/repos/scripts/ChatWorkhorseUnix/cwhu-health-monitor.sh
# 2026-07-12 20:00 UTC — created
# CWHU system health monitor. Runs every 5 minutes via cron.
# Checks: iowait, D-state processes, disk usage.
# Emails on first detection and every 30 minutes while condition persists.
# Sends all-clear when condition resolves. No email if all healthy.

HOST="chatworkhorseunix"
TO="dennyrgood@yahoo.com"
STATE_FILE="/tmp/cwhu-monitor-state.tmp"
NOW=$(date +%s)
ALERT_INTERVAL=$((30 * 60))

IOWAIT_THRESHOLD=20
DISK_THRESHOLD=85

# --- Load state (defaults to zero/inactive if file absent) ---
IOWAIT_LAST_ALERT=0; IOWAIT_ACTIVE=0
DSTATE_LAST_ALERT=0; DSTATE_ACTIVE=0
DISK_LAST_ALERT=0;   DISK_ACTIVE=0

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# --- Check 1: iowait ---
IOWAIT=$(iostat -c 1 6 2>/dev/null | awk '
    /^[ \t]+[0-9]/ { n++; if (n > 1) { sum += $4; count++ } }
    END { if (count > 0) printf "%.1f", sum/count; else print "0" }
')
IOWAIT_TRIGGERED=$(awk -v i="$IOWAIT" -v t="$IOWAIT_THRESHOLD" \
    'BEGIN{print (i+0 > t+0) ? 1 : 0}')

# --- Check 2: D-state processes ---
DSTATE_PROCS=$(ps -eo pid,stat,comm,args --no-headers | awk '$2 ~ /^D/')
DSTATE_TRIGGERED=0
[ -n "$DSTATE_PROCS" ] && DSTATE_TRIGGERED=1

# --- Check 3: disk usage ---
DISK_OVER=$(df -h | awk -v t="$DISK_THRESHOLD" \
    'NR>1 { gsub(/%/,"",$5); if ($5+0 > t+0) print $0 }')
DISK_TRIGGERED=0
[ -n "$DISK_OVER" ] && DISK_TRIGGERED=1

# --- Evaluate each condition: alert / suppress / clear / ok ---
check_condition() {
    local triggered=$1 last_alert=$2 was_active=$3
    if [ "$triggered" -eq 1 ]; then
        if [ "$was_active" -eq 0 ] || \
           [ $(( NOW - last_alert )) -ge $ALERT_INTERVAL ]; then
            echo "alert"
        else
            echo "suppress"
        fi
    elif [ "$was_active" -eq 1 ]; then
        echo "clear"
    else
        echo "ok"
    fi
}

ALERT_BODY=""
CLEAR_BODY=""

# iowait
case "$(check_condition $IOWAIT_TRIGGERED $IOWAIT_LAST_ALERT $IOWAIT_ACTIVE)" in
    alert)
        IOWAIT_LAST_ALERT=$NOW; IOWAIT_ACTIVE=1
        ALERT_BODY+="=== HIGH IOWAIT ===\n"
        ALERT_BODY+="5-second average: ${IOWAIT}%  (threshold: ${IOWAIT_THRESHOLD}%)\n\n"
        ;;
    clear)    IOWAIT_ACTIVE=0; CLEAR_BODY+="  - iowait returned to normal\n" ;;
    suppress) IOWAIT_ACTIVE=1 ;;
    ok)       IOWAIT_ACTIVE=0 ;;
esac

# D-state
case "$(check_condition $DSTATE_TRIGGERED $DSTATE_LAST_ALERT $DSTATE_ACTIVE)" in
    alert)
        DSTATE_LAST_ALERT=$NOW; DSTATE_ACTIVE=1
        ALERT_BODY+="=== D-STATE PROCESSES ===\n"
        ALERT_BODY+="$(echo "$DSTATE_PROCS" | head -10)\n\n"
        ;;
    clear)    DSTATE_ACTIVE=0; CLEAR_BODY+="  - D-state processes cleared\n" ;;
    suppress) DSTATE_ACTIVE=1 ;;
    ok)       DSTATE_ACTIVE=0 ;;
esac

# Disk
case "$(check_condition $DISK_TRIGGERED $DISK_LAST_ALERT $DISK_ACTIVE)" in
    alert)
        DISK_LAST_ALERT=$NOW; DISK_ACTIVE=1
        ALERT_BODY+="=== DISK USAGE ABOVE ${DISK_THRESHOLD}% ===\n${DISK_OVER}\n\n"
        ;;
    clear)    DISK_ACTIVE=0; CLEAR_BODY+="  - disk usage returned to normal\n" ;;
    suppress) DISK_ACTIVE=1 ;;
    ok)       DISK_ACTIVE=0 ;;
esac

# --- Educational footer ---
FOOTER="------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

HIGH IOWAIT (>${IOWAIT_THRESHOLD}%):
iowait is the percentage of time the CPU is idle while waiting for disk
I/O to complete. Normal is under 5%. Sustained iowait above ${IOWAIT_THRESHOLD}%
usually means a storage device is slow, failing, or hung.

What to do:
  1. iostat -x 1 5         -- see which device is the bottleneck
  2. iotop -o              -- see which processes are doing I/O
  3. dmesg | tail -30      -- look for disk errors or resets

D-STATE PROCESSES:
A process in D-state (uninterruptible sleep) is blocked waiting for
the kernel to complete an I/O operation. Kernel threads jbd2/<dev>
and flush-<dev> in D-state almost always mean the block device is hung.

What to do:
  1. ps -eo pid,stat,comm,args | awk '\$2~/^D/'  -- see what is stuck
  2. dmesg | tail -30           -- look for I/O errors
  3. If USB: unplug it -- the D-state process will unblock
  4. If it persists: a reboot may be required
------------------------------------------------------------------------"

# --- Save state ---
cat > "$STATE_FILE" <<STATEEOF
IOWAIT_LAST_ALERT=$IOWAIT_LAST_ALERT
IOWAIT_ACTIVE=$IOWAIT_ACTIVE
DSTATE_LAST_ALERT=$DSTATE_LAST_ALERT
DSTATE_ACTIVE=$DSTATE_ACTIVE
DISK_LAST_ALERT=$DISK_LAST_ALERT
DISK_ACTIVE=$DISK_ACTIVE
STATEEOF

# --- Send alert email ---
if [ -n "$ALERT_BODY" ]; then
    {
        echo "To: $TO"
        echo "Subject: [${HOST}] HEALTH ALERT -- $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo -e "$ALERT_BODY"
        echo "$FOOTER"
    } | msmtp --account=icloud "$TO"
fi

# --- Send all-clear email ---
if [ -n "$CLEAR_BODY" ]; then
    {
        echo "To: $TO"
        echo "Subject: [${HOST}] ALL CLEAR -- $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo "The following conditions have resolved:"
        echo ""
        echo -e "$CLEAR_BODY"
    } | msmtp --account=icloud "$TO"
fi
