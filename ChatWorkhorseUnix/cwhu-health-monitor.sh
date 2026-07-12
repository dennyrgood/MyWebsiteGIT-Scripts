#!/bin/bash
# /home/dhm/repos/scripts/ChatWorkhorseUnix/cwhu-health-monitor.sh
# 2026-07-12 20:00 UTC — created
# 2026-07-12 21:00 UTC — rebuilt to match wbu-health-monitor.sh: added docker
#                         container health checks (missing + unhealthy), streak-based
#                         D-state check, check_condition_streak() helper.
# CWHU system health monitor. Runs every 5 minutes via cron.
# Checks: iowait, D-state processes, disk usage, docker containers.
# Emails on first detection and every 30 minutes while condition persists.
# Sends all-clear when condition resolves. No email if all healthy.

HOST="chatworkhorseunix"
TO="dennyrgood@yahoo.com"
STATE_FILE="/tmp/cwhu-monitor-state.tmp"
NOW=$(date +%s)
ALERT_INTERVAL=$((30 * 60))

IOWAIT_THRESHOLD=20
DISK_THRESHOLD=85
DOCKER_CONTAINERS=(immich_machine_learning immich_server immich_postgres immich_redis)
DOCKER_FAIL_THRESHOLD=2
DSTATE_FAIL_THRESHOLD=2

# --- Load state (defaults to zero/inactive if file absent) ---
IOWAIT_LAST_ALERT=0; IOWAIT_ACTIVE=0
DSTATE_LAST_ALERT=0; DSTATE_ACTIVE=0; DSTATE_STREAK=0
DISK_LAST_ALERT=0;   DISK_ACTIVE=0

# Per-container state initialized dynamically below
for c in "${DOCKER_CONTAINERS[@]}"; do
    eval "MISSING_${c}_LAST_ALERT=0;   MISSING_${c}_ACTIVE=0;   MISSING_${c}_STREAK=0"
    eval "UNHEALTHY_${c}_LAST_ALERT=0; UNHEALTHY_${c}_ACTIVE=0; UNHEALTHY_${c}_STREAK=0"
done

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

# --- Check 4: docker container health ---
declare -A DOCKER_MISSING_TRIGGERED DOCKER_UNHEALTHY_TRIGGERED
for c in "${DOCKER_CONTAINERS[@]}"; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        DOCKER_MISSING_TRIGGERED[$c]=1
        DOCKER_UNHEALTHY_TRIGGERED[$c]=0
    else
        DOCKER_MISSING_TRIGGERED[$c]=0
        HSTATUS=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)
        if [ "$HSTATUS" = "unhealthy" ]; then
            DOCKER_UNHEALTHY_TRIGGERED[$c]=1
        else
            DOCKER_UNHEALTHY_TRIGGERED[$c]=0
        fi
    fi
done

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

# --- Streak-aware condition helper ---
check_condition_streak() {
    local triggered=$1 last_alert=$2 was_active=$3 streak=$4 threshold=$5
    if [ "$triggered" -eq 1 ]; then
        streak=$(( streak + 1 ))
        if [ "$streak" -ge "$threshold" ]; then
            if [ "$was_active" -eq 0 ] || \
               [ $(( NOW - last_alert )) -ge $ALERT_INTERVAL ]; then
                echo "alert $streak"
            else
                echo "suppress $streak"
            fi
        else
            echo "wait $streak"
        fi
    elif [ "$was_active" -eq 1 ]; then
        echo "clear 0"
    else
        echo "ok 0"
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

# D-state (streak-based)
read verdict new_streak <<< "$(check_condition_streak $DSTATE_TRIGGERED $DSTATE_LAST_ALERT $DSTATE_ACTIVE $DSTATE_STREAK $DSTATE_FAIL_THRESHOLD)"
DSTATE_STREAK=$new_streak
case "$verdict" in
    alert)
        DSTATE_LAST_ALERT=$NOW; DSTATE_ACTIVE=1
        ALERT_BODY+="=== D-STATE PROCESSES ===\n"
        ALERT_BODY+="Present for ${new_streak} consecutive checks (~$((new_streak * 5)) min).\n"
        ALERT_BODY+="$(echo "$DSTATE_PROCS" | head -10)\n\n"
        ;;
    clear)    DSTATE_ACTIVE=0; CLEAR_BODY+="  - D-state processes cleared\n" ;;
    suppress) DSTATE_ACTIVE=1 ;;
    wait|ok)  DSTATE_ACTIVE=0 ;;
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

# Docker containers
for c in "${DOCKER_CONTAINERS[@]}"; do
    # Missing check
    trig=${DOCKER_MISSING_TRIGGERED[$c]}
    last=$(eval echo \$MISSING_${c}_LAST_ALERT)
    active=$(eval echo \$MISSING_${c}_ACTIVE)
    streak=$(eval echo \$MISSING_${c}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $DOCKER_FAIL_THRESHOLD)"
    eval "MISSING_${c}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "MISSING_${c}_LAST_ALERT=$NOW; MISSING_${c}_ACTIVE=1"
            ALERT_BODY+="=== CONTAINER MISSING: ${c} ===\n"
            ALERT_BODY+="Not present in docker ps for ${new_streak} consecutive checks.\n\n"
            ;;
        clear)    eval "MISSING_${c}_ACTIVE=0"
                  CLEAR_BODY+="  - container ${c} is back\n" ;;
        suppress) eval "MISSING_${c}_ACTIVE=1" ;;
        wait|ok)  eval "MISSING_${c}_ACTIVE=0" ;;
    esac

    # Unhealthy check
    trig=${DOCKER_UNHEALTHY_TRIGGERED[$c]}
    last=$(eval echo \$UNHEALTHY_${c}_LAST_ALERT)
    active=$(eval echo \$UNHEALTHY_${c}_ACTIVE)
    streak=$(eval echo \$UNHEALTHY_${c}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $DOCKER_FAIL_THRESHOLD)"
    eval "UNHEALTHY_${c}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "UNHEALTHY_${c}_LAST_ALERT=$NOW; UNHEALTHY_${c}_ACTIVE=1"
            ALERT_BODY+="=== CONTAINER UNHEALTHY: ${c} ===\n"
            ALERT_BODY+="Docker health status = unhealthy for ${new_streak} consecutive checks.\n"
            ALERT_BODY+="Recent health log:\n"
            ALERT_BODY+="$(docker inspect --format='{{range .State.Health.Log}}{{.Start}}  exit={{.ExitCode}}  {{.Output}}{{end}}' $c 2>/dev/null | tail -c 800)\n\n"
            ;;
        clear)    eval "UNHEALTHY_${c}_ACTIVE=0"
                  CLEAR_BODY+="  - container ${c} returned to healthy\n" ;;
        suppress) eval "UNHEALTHY_${c}_ACTIVE=1" ;;
        wait|ok)  eval "UNHEALTHY_${c}_ACTIVE=0" ;;
    esac
done

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
the kernel to complete an I/O operation. This monitor requires D-state
processes to be present for ${DSTATE_FAIL_THRESHOLD} consecutive samples (~$((DSTATE_FAIL_THRESHOLD * 5)) min) before
alerting, filtering out transient jbd2/* and short-lived Postgres blips.

What to do:
  1. ps -eo pid,stat,comm,args | awk '\$2~/^D/'  -- see what is stuck
  2. dmesg | tail -30           -- look for I/O errors
  3. If it persists: a reboot may be required

DOCKER CONTAINER MISSING / UNHEALTHY:
A container is 'missing' when not present in 'docker ps' at all.
'Unhealthy' means the container is running but its healthcheck has
failed repeatedly. Alerts require ${DOCKER_FAIL_THRESHOLD} consecutive failing samples
(~10 min) to ride out normal restarts.

What to do:
  1. docker ps -a                                 -- see container state
  2. docker inspect --format='{{.State.Health.Status}}' <name>
  3. docker logs --tail 100 <name>                -- look for errors
  4. docker inspect --format='{{json .State.Health}}' <name> | jq
  5. If wedged: cd /home/dhm/repos/immich && docker compose up -d --force-recreate <service>
------------------------------------------------------------------------"

# --- Save state ---
{
    echo "IOWAIT_LAST_ALERT=$IOWAIT_LAST_ALERT"
    echo "IOWAIT_ACTIVE=$IOWAIT_ACTIVE"
    echo "DSTATE_LAST_ALERT=$DSTATE_LAST_ALERT"
    echo "DSTATE_ACTIVE=$DSTATE_ACTIVE"
    echo "DSTATE_STREAK=$DSTATE_STREAK"
    echo "DISK_LAST_ALERT=$DISK_LAST_ALERT"
    echo "DISK_ACTIVE=$DISK_ACTIVE"
    for c in "${DOCKER_CONTAINERS[@]}"; do
        for k in MISSING_${c}_LAST_ALERT MISSING_${c}_ACTIVE MISSING_${c}_STREAK \
                 UNHEALTHY_${c}_LAST_ALERT UNHEALTHY_${c}_ACTIVE UNHEALTHY_${c}_STREAK; do
            echo "$k=$(eval echo \$$k)"
        done
    done
} > "$STATE_FILE"

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
