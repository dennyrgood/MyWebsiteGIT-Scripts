#!/bin/bash
# ~/repos/scripts/nas/nas-health-monitor.sh
# 2026-08-06 14:00 UTC
# 2026-08-06 19:15 UTC: fixed RAID state awk again — use field positions
#                       instead of -F': ' split which failed on this mdadm version.
# 2026-08-06 19:00 UTC: fixed RAID state awk to use -F': ' field split instead
#                       of sub() which was unreliable on multi-word state strings.
# 2026-08-06 18:30 UTC: fixed RAID trigger to handle 'active' prefix and
#                       alert on unexpected states.
# 2026-08-06 17:00 UTC: fixed msmtp invocation to use sudo on WBU (config is at
#                       /etc/msmtprc, only readable by root).
# 2026-08-06 16:30 UTC: wired up alert/all-clear sending via SSH to WBU msmtp;
#                       log write retained alongside email send.
# 2026-08-06 16:00 UTC: fixed RAID state parse (multi-word state); excluded
#                       /dev/loop* from disk check (UGREEN OS squashfs mounts
#                       are always 100%); suppressed RAID alert during recovery
#                       (degraded+recovering is expected during a rebuild).
# NAS system health monitor. Runs every 5 minutes via cron.
# Checks: SMART attributes (reallocated sectors, pending sectors, temperature)
#         per drive (sda, sdb, sdc), RAID array state (/dev/md1), disk usage,
#         and UPS/NUT readability and replace-battery.
# Writes alerts and all-clears to LOG_FILE. Email via SSH->WBU to be wired up later.
# No email if all healthy.

HOST="FleetNAS"
LOG_FILE="/var/log/nas-health-monitor.log"
STATE_FILE="/tmp/nas-monitor-state.tmp"
NOW=$(date +%s)
ALERT_INTERVAL=$((30 * 60))

DRIVES=(sda sdb sdc)
MDADM=/sbin/mdadm
RAID_DEV=/dev/md1
DISK_THRESHOLD=85
TEMP_THRESHOLD=45
SMART_FAIL_THRESHOLD=2   # consecutive failures before alerting (anti-flap)
UPS_NAME="ups0"
UPS_HOST="localhost"
UPS_FAIL_THRESHOLD=2

# --- Load state (defaults to zero/inactive if file absent) ---
DISK_LAST_ALERT=0;  DISK_ACTIVE=0
RAID_LAST_ALERT=0;  RAID_ACTIVE=0
UPS_UNREADABLE_LAST_ALERT=0;      UPS_UNREADABLE_ACTIVE=0; UPS_UNREADABLE_STREAK=0
UPS_REPLACE_BATTERY_LAST_ALERT=0; UPS_REPLACE_BATTERY_ACTIVE=0

for d in "${DRIVES[@]}"; do
    eval "REALLOC_${d}_LAST_ALERT=0; REALLOC_${d}_ACTIVE=0; REALLOC_${d}_STREAK=0"
    eval "PENDING_${d}_LAST_ALERT=0; PENDING_${d}_ACTIVE=0; PENDING_${d}_STREAK=0"
    eval "TEMP_${d}_LAST_ALERT=0;    TEMP_${d}_ACTIVE=0;    TEMP_${d}_STREAK=0"
done

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# --- Helpers ---
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

# --- Check 1: SMART attributes per drive ---
declare -A DRIVE_REALLOC DRIVE_PENDING DRIVE_TEMP
for d in "${DRIVES[@]}"; do
    SMART_OUT=$(smartctl -A /dev/$d 2>/dev/null)
    DRIVE_REALLOC[$d]=$(echo "$SMART_OUT" | awk '$2=="Reallocated_Sector_Ct" {print $10+0}')
    DRIVE_PENDING[$d]=$(echo "$SMART_OUT" | awk '$2=="Current_Pending_Sector" {print $10+0}')
    DRIVE_TEMP[$d]=$(echo "$SMART_OUT"    | awk '$2=="Temperature_Celsius"    {print $10+0}')
    # Default to 0 if smartctl returned nothing
    DRIVE_REALLOC[$d]=${DRIVE_REALLOC[$d]:-0}
    DRIVE_PENDING[$d]=${DRIVE_PENDING[$d]:-0}
    DRIVE_TEMP[$d]=${DRIVE_TEMP[$d]:-0}
done

# --- Check 2: RAID array state ---
RAID_STATE=$(sudo $MDADM --detail $RAID_DEV 2>/dev/null | awk '/State :/ && !/RaidDevice/ {print $3, $4, $5}')
RAID_TRIGGERED=0
# Alert on degraded or failed; suppress during recovery (expected during rebuild).
# A recovering array is still at risk but the operator already knows — alert only
# if degraded is NOT accompanied by a rebuild in progress.
case "$RAID_STATE" in
    *failed*)    RAID_TRIGGERED=1 ;;
    *degraded*)
        # degraded+recovering = rebuild in progress, don't alert
        [[ "$RAID_STATE" != *recovering* ]] && RAID_TRIGGERED=1
        ;;
    clean*|active*) RAID_TRIGGERED=0 ;;
    *) RAID_TRIGGERED=1 ;;  # unexpected state — alert
esac

# --- Check 3: disk usage ---
DISK_OVER=$(df -h | awk -v t="$DISK_THRESHOLD" \
    'NR>1 && $1 !~ /^\/dev\/loop/ { gsub(/%/,"",$5); if ($5+0 > t+0) print $0 }')
DISK_TRIGGERED=0
[ -n "$DISK_OVER" ] && DISK_TRIGGERED=1

# --- Check 4: UPS / NUT ---
UPS_OUT=$(upsc "${UPS_NAME}@${UPS_HOST}" 2>/dev/null)
UPS_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
UPS_CHARGE=$(printf '%s\n' "$UPS_OUT"  | awk -F': ' '$1=="battery.charge"{print $2}')

UPS_UNREADABLE_TRIGGERED=0
[ -z "$UPS_STATUS" ] && UPS_UNREADABLE_TRIGGERED=1

UPS_REPLACE_BATTERY_TRIGGERED=0
case " $UPS_STATUS " in *" RB "*) UPS_REPLACE_BATTERY_TRIGGERED=1 ;; esac

# --- Evaluate conditions ---
ALERT_BODY=""
CLEAR_BODY=""

# SMART: reallocated sectors and pending sectors per drive (streak-based)
for d in "${DRIVES[@]}"; do
    realloc=${DRIVE_REALLOC[$d]}
    pending=${DRIVE_PENDING[$d]}
    temp=${DRIVE_TEMP[$d]}

    # Reallocated sectors
    trig=0; [ "${realloc}" -gt 0 ] && trig=1
    last=$(eval echo \$REALLOC_${d}_LAST_ALERT)
    active=$(eval echo \$REALLOC_${d}_ACTIVE)
    streak=$(eval echo \$REALLOC_${d}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $SMART_FAIL_THRESHOLD)"
    eval "REALLOC_${d}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "REALLOC_${d}_LAST_ALERT=$NOW; REALLOC_${d}_ACTIVE=1"
            ALERT_BODY+="=== SMART: REALLOCATED SECTORS on /dev/${d} ===\n"
            ALERT_BODY+="Reallocated_Sector_Ct = ${realloc}  (threshold: > 0)\n"
            ALERT_BODY+="This drive has remapped bad sectors. Monitor closely; growing count means imminent failure.\n\n"
            ;;
        clear)   eval "REALLOC_${d}_ACTIVE=0"
                 CLEAR_BODY+="  - /dev/${d} reallocated sector count back to 0\n" ;;
        suppress) eval "REALLOC_${d}_ACTIVE=1" ;;
        wait|ok)  eval "REALLOC_${d}_ACTIVE=0" ;;
    esac

    # Pending sectors
    trig=0; [ "${pending}" -gt 0 ] && trig=1
    last=$(eval echo \$PENDING_${d}_LAST_ALERT)
    active=$(eval echo \$PENDING_${d}_ACTIVE)
    streak=$(eval echo \$PENDING_${d}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $SMART_FAIL_THRESHOLD)"
    eval "PENDING_${d}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "PENDING_${d}_LAST_ALERT=$NOW; PENDING_${d}_ACTIVE=1"
            ALERT_BODY+="=== SMART: PENDING SECTORS on /dev/${d} ===\n"
            ALERT_BODY+="Current_Pending_Sector = ${pending}  (threshold: > 0)\n"
            ALERT_BODY+="Sectors the drive cannot read and is waiting to reallocate. Data at risk.\n\n"
            ;;
        clear)   eval "PENDING_${d}_ACTIVE=0"
                 CLEAR_BODY+="  - /dev/${d} pending sector count back to 0\n" ;;
        suppress) eval "PENDING_${d}_ACTIVE=1" ;;
        wait|ok)  eval "PENDING_${d}_ACTIVE=0" ;;
    esac

    # Temperature
    trig=0; [ "${temp}" -gt "$TEMP_THRESHOLD" ] && trig=1
    last=$(eval echo \$TEMP_${d}_LAST_ALERT)
    active=$(eval echo \$TEMP_${d}_ACTIVE)
    streak=$(eval echo \$TEMP_${d}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $SMART_FAIL_THRESHOLD)"
    eval "TEMP_${d}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "TEMP_${d}_LAST_ALERT=$NOW; TEMP_${d}_ACTIVE=1"
            ALERT_BODY+="=== SMART: HIGH TEMPERATURE on /dev/${d} ===\n"
            ALERT_BODY+="Temperature = ${temp}°C  (threshold: ${TEMP_THRESHOLD}°C)\n"
            ALERT_BODY+="Check NAS airflow and enclosure fan. WD Red Plus max rated: 65°C.\n\n"
            ;;
        clear)   eval "TEMP_${d}_ACTIVE=0"
                 CLEAR_BODY+="  - /dev/${d} temperature back below ${TEMP_THRESHOLD}°C (now ${temp}°C)\n" ;;
        suppress) eval "TEMP_${d}_ACTIVE=1" ;;
        wait|ok)  eval "TEMP_${d}_ACTIVE=0" ;;
    esac
done

# RAID array state (no streak — a non-clean array is immediately actionable)
case "$(check_condition $RAID_TRIGGERED $RAID_LAST_ALERT $RAID_ACTIVE)" in
    alert)
        RAID_LAST_ALERT=$NOW; RAID_ACTIVE=1
        ALERT_BODY+="=== RAID ARRAY NOT CLEAN: ${RAID_DEV} ===\n"
        ALERT_BODY+="State reported as: '${RAID_STATE}'\n"
        ALERT_BODY+="$(sudo $MDADM --detail $RAID_DEV 2>/dev/null)\n\n"
        ;;
    clear)   RAID_ACTIVE=0; CLEAR_BODY+="  - ${RAID_DEV} is clean again\n" ;;
    suppress) RAID_ACTIVE=1 ;;
    ok)       RAID_ACTIVE=0 ;;
esac

# Disk usage
case "$(check_condition $DISK_TRIGGERED $DISK_LAST_ALERT $DISK_ACTIVE)" in
    alert)
        DISK_LAST_ALERT=$NOW; DISK_ACTIVE=1
        ALERT_BODY+="=== DISK USAGE ABOVE ${DISK_THRESHOLD}% ===\n${DISK_OVER}\n\n"
        ;;
    clear)   DISK_ACTIVE=0; CLEAR_BODY+="  - disk usage returned to normal\n" ;;
    suppress) DISK_ACTIVE=1 ;;
    ok)       DISK_ACTIVE=0 ;;
esac

# UPS unreadable (streak-based)
read verdict new_streak <<< "$(check_condition_streak $UPS_UNREADABLE_TRIGGERED $UPS_UNREADABLE_LAST_ALERT $UPS_UNREADABLE_ACTIVE $UPS_UNREADABLE_STREAK $UPS_FAIL_THRESHOLD)"
UPS_UNREADABLE_STREAK=$new_streak
case "$verdict" in
    alert)
        UPS_UNREADABLE_LAST_ALERT=$NOW; UPS_UNREADABLE_ACTIVE=1
        ALERT_BODY+="=== UPS UNREADABLE ===\n"
        ALERT_BODY+="upsc ${UPS_NAME}@${UPS_HOST} returned nothing for ${new_streak} consecutive checks (~$((new_streak * 5)) min).\n"
        ALERT_BODY+="Check:\n"
        ALERT_BODY+="  1. upsc ${UPS_NAME}@${UPS_HOST}          -- manual read\n"
        ALERT_BODY+="  2. systemctl status nut-server           -- may say active with dead driver\n"
        ALERT_BODY+="  3. journalctl -u nut-server -n 50\n"
        ALERT_BODY+="  4. sudo systemctl restart nut-server\n\n"
        ;;
    clear)   UPS_UNREADABLE_ACTIVE=0; CLEAR_BODY+="  - UPS readable again (${UPS_STATUS}, ${UPS_CHARGE}%)\n" ;;
    suppress) UPS_UNREADABLE_ACTIVE=1 ;;
    wait|ok)  UPS_UNREADABLE_ACTIVE=0 ;;
esac

# UPS replace-battery (no streak — sticky fault)
case "$(check_condition $UPS_REPLACE_BATTERY_TRIGGERED $UPS_REPLACE_BATTERY_LAST_ALERT $UPS_REPLACE_BATTERY_ACTIVE)" in
    alert)
        UPS_REPLACE_BATTERY_LAST_ALERT=$NOW; UPS_REPLACE_BATTERY_ACTIVE=1
        ALERT_BODY+="=== UPS REPLACE BATTERY ===\n"
        ALERT_BODY+="${UPS_NAME} reports RB (status: ${UPS_STATUS}, charge: ${UPS_CHARGE}%).\n"
        ALERT_BODY+="Runtime during next outage may be far shorter than expected.\n\n"
        ;;
    clear)   UPS_REPLACE_BATTERY_ACTIVE=0; CLEAR_BODY+="  - UPS no longer reporting replace-battery\n" ;;
    suppress) UPS_REPLACE_BATTERY_ACTIVE=1 ;;
    ok)       UPS_REPLACE_BATTERY_ACTIVE=0 ;;
esac

# --- Educational footer ---
FOOTER="------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

REALLOCATED SECTORS (ID 5):
The drive has found a bad sector and remapped it to a spare. Any non-zero
value means the drive has had a physical read failure. A stable count is
a yellow flag; a growing count means the drive is actively deteriorating
and should be replaced.

What to do:
  1. smartctl -a /dev/sdX        -- full attribute dump
  2. smartctl -t short /dev/sdX  -- run a short self-test
  3. sudo /sbin/mdadm --detail /dev/md1  -- check array state
  4. Replace the drive if count is growing or pending sectors also > 0

PENDING SECTORS (ID 197):
Sectors the drive cannot currently read and is queuing for reallocation.
These represent data that may already be unreadable. Combined with
reallocated sectors, this is a strong indicator of imminent failure.

What to do:
  1. smartctl -a /dev/sdX
  2. smartctl -t long /dev/sdX   -- full surface scan (~13 hours on 8TB)
  3. Replace drive immediately if count is non-zero and growing

HIGH TEMPERATURE (>${TEMP_THRESHOLD}°C):
WD Red Plus drives are rated 0–65°C. Sustained temperatures above
${TEMP_THRESHOLD}°C shorten drive life. Normal operating range for this NAS is 30–42°C.

What to do:
  1. Check NAS enclosure fan is spinning
  2. Check ambient temperature in the room
  3. Ensure drives are not packed too tightly in bays

RAID ARRAY NOT CLEAN:
The RAID5 array on ${RAID_DEV} is not in 'clean' state. Possible states:
  degraded   -- one drive has failed or been removed; NO redundancy
  recovering -- rebuilding after a drive replacement (can take 12-24h)
  failed     -- multiple drives lost; data may be unrecoverable

What to do:
  1. sudo /sbin/mdadm --detail /dev/md1   -- full array status
  2. cat /proc/mdstat                     -- quick overview
  3. smartctl -a /dev/sdX                 -- check each drive
  4. If degraded: replace failed drive and let array rebuild
  5. Do NOT power cycle during a rebuild

DISK USAGE ABOVE ${DISK_THRESHOLD}%:
  1. df -h                  -- see which filesystem is full
  2. du -sh /volume1/*      -- find large directories

UPS UNREADABLE:
upsc cannot reach the NUT driver. The UPS provides no shutdown signal
while this is broken.

  1. upsc ${UPS_NAME}@${UPS_HOST}
  2. systemctl status nut-server
  3. journalctl -u nut-server -n 50
  4. sudo systemctl restart nut-server
------------------------------------------------------------------------"

# --- Save state ---
{
    echo "DISK_LAST_ALERT=$DISK_LAST_ALERT"
    echo "DISK_ACTIVE=$DISK_ACTIVE"
    echo "RAID_LAST_ALERT=$RAID_LAST_ALERT"
    echo "RAID_ACTIVE=$RAID_ACTIVE"
    echo "UPS_UNREADABLE_LAST_ALERT=$UPS_UNREADABLE_LAST_ALERT"
    echo "UPS_UNREADABLE_ACTIVE=$UPS_UNREADABLE_ACTIVE"
    echo "UPS_UNREADABLE_STREAK=$UPS_UNREADABLE_STREAK"
    echo "UPS_REPLACE_BATTERY_LAST_ALERT=$UPS_REPLACE_BATTERY_LAST_ALERT"
    echo "UPS_REPLACE_BATTERY_ACTIVE=$UPS_REPLACE_BATTERY_ACTIVE"
    for d in "${DRIVES[@]}"; do
        for k in REALLOC_${d}_LAST_ALERT REALLOC_${d}_ACTIVE REALLOC_${d}_STREAK \
                 PENDING_${d}_LAST_ALERT PENDING_${d}_ACTIVE PENDING_${d}_STREAK \
                 TEMP_${d}_LAST_ALERT    TEMP_${d}_ACTIVE    TEMP_${d}_STREAK; do
            echo "$k=$(eval echo \$$k)"
        done
    done
} > "$STATE_FILE"

# --- Send via SSH to WBU msmtp, and write to local log ---
TO="dennyrgood@yahoo.com"
WBU="dhm@192.168.178.242"

if [ -n "$ALERT_BODY" ]; then
    MSG=$(printf "To: %s\nSubject: [%s] HEALTH ALERT -- %s\n\n%b\n%s\n" \
        "$TO" "$HOST" "$(date '+%Y-%m-%d %H:%M' -u)" "$ALERT_BODY" "$FOOTER")
    echo "$MSG" | ssh -o BatchMode=yes "$WBU" "sudo msmtp --account=icloud $TO" 2>/dev/null
    {
        echo "===== [${HOST}] HEALTH ALERT -- $(date '+%Y-%m-%d %H:%M UTC' -u) ====="
        echo -e "$ALERT_BODY"
        echo "$FOOTER"
        echo ""
    } >> "$LOG_FILE"
fi

if [ -n "$CLEAR_BODY" ]; then
    MSG=$(printf "To: %s\nSubject: [%s] ALL CLEAR -- %s\n\nThe following conditions have resolved:\n\n%b\n" \
        "$TO" "$HOST" "$(date '+%Y-%m-%d %H:%M' -u)" "$CLEAR_BODY")
    echo "$MSG" | ssh -o BatchMode=yes "$WBU" "sudo msmtp --account=icloud $TO" 2>/dev/null
    {
        echo "===== [${HOST}] ALL CLEAR -- $(date '+%Y-%m-%d %H:%M UTC' -u) ====="
        echo "The following conditions have resolved:"
        echo ""
        echo -e "$CLEAR_BODY"
        echo ""
    } >> "$LOG_FILE"
fi
