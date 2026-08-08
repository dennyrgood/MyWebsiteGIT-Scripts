#!/opt/homebrew/bin/bash
# Created: 2026-08-04 UTC — mathes-mac-mini system health monitor, modeled on
# WorkBenchUnix/wbu-health-monitor.sh but scoped to what actually runs on this box:
# Plex Media Server and Syncthing (both regular macOS GUI apps, not true launchd
# services — launchd only tracks them under an ad-hoc "application.<bundleid>.<pid>"
# label it assigns to any GUI app launch, not a plist we control). Also checks disk
# usage on the Plex source volumes. Deliberately does NOT port WBU's iowait/D-state
# checks — those are Linux storage-subsystem signals tied to Docker/rsync-to-USB
# failure modes with no clean macOS equivalent for a desktop internal SSD.
#
# Run via cron every 5 min. Alerts on first detection and every 30 min while a
# condition persists; sends all-clear when it resolves; silent when everything's
# healthy. Missing vs down distinction per service (mirrors WBU's docker
# missing-vs-unhealthy split): missing = process not found (crashed/quit), down =
# process running but the app's own HTTP API isn't answering (hung).
#
# 2026-08-08: added NUT/UPS checks (this box's own upsmon client) — see the dated
# comment further down for what and why.

HOST="mathes-mac-mini"
TO="dennyrgood@yahoo.com"
MSMTP="/opt/homebrew/bin/msmtp"
STATE_FILE="/tmp/mathes-mac-mini-monitor-state.tmp"
NOW=$(date +%s)
ALERT_INTERVAL=$((30 * 60))

DISK_THRESHOLD=85
DISK_VOLUMES=(/Volumes/MacMiniExt4g /Volumes/Expansion)
FAIL_THRESHOLD=2   # consecutive 5-min samples before alerting (anti-flap on app restarts)

PLEX_PROC_PATTERN="Plex Media Server.app/Contents/MacOS/Plex Media Server"
PLEX_URL="http://127.0.0.1:32400/identity"
SYNCTHING_PROC_PATTERN="Syncthing.app/Contents/MacOS/Syncthing"
SYNCTHING_URL="http://127.0.0.1:8384/rest/noauth/health"
# Reused from Status/config.py (SYNCTHING_CONFIG["mathes-mac-mini"]) — same key the
# fleet status checker already uses against this box. Lets the monitor inspect actual
# per-folder sync state (Status/checkers/syncthing_checker.py's approach), not just
# process-alive: a folder stuck in Syncthing's "error" state still answers
# /rest/noauth/health with 200, so that alone would miss a real sync failure.
SYNCTHING_API_KEY="rPDLKezk4ppcf6sYDwdmLwtv3jx3ZUvg"
# Pull errors ("failed items") on an otherwise-idle folder are usually benign/transient
# (locked/permission-denied/deleted files) — only escalate past this many, matching the
# threshold syncthing_checker.py already uses for the same reason.
SYNCTHING_PULL_ERR_THRESHOLD=5

# 2026-08-08: NUT/UPS client checks, added once the Mac Mini's NUT client (netclient
# only, monitoring ups0 on the NAS) was verified end to end — see the UPS/NUT setup
# guide, Section 7, and scripts repo launchdaemons/. Modeled on
# WorkBenchUnix/wbu-health-monitor.sh's UPS check, but this box is a client, not a
# server, so it needs one extra check WBU's doesn't: see the comment above the check
# block below for why.
UPSC="/opt/homebrew/bin/upsc"          # absolute path — launchd's environment has no /opt/homebrew on PATH
UPS_NAME="ups0"
UPS_HOST="192.168.178.123"             # FleetNAS; ignorelb + override.battery.charge.low=15 there IS this
                                        # box's LOWBATT threshold — no local upssched timer exists here
UPS_FAIL_THRESHOLD=2                   # consecutive 5-min samples before alerting (anti-flap)
UPSMON_PROC_PATTERN="/opt/homebrew/sbin/upsmon"

# --- Load state (defaults to zero/inactive if file absent) ---
DISK_LAST_ALERT=0; DISK_ACTIVE=0
UPS_UNREADABLE_LAST_ALERT=0;      UPS_UNREADABLE_ACTIVE=0; UPS_UNREADABLE_STREAK=0
UPS_REPLACE_BATTERY_LAST_ALERT=0; UPS_REPLACE_BATTERY_ACTIVE=0
UPSMON_MISSING_LAST_ALERT=0;      UPSMON_MISSING_ACTIVE=0; UPSMON_MISSING_STREAK=0
for svc in PLEX SYNCTHING; do
    eval "MISSING_${svc}_LAST_ALERT=0; MISSING_${svc}_ACTIVE=0; MISSING_${svc}_STREAK=0"
    eval "DOWN_${svc}_LAST_ALERT=0;    DOWN_${svc}_ACTIVE=0;    DOWN_${svc}_STREAK=0"
done

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# --- Check: disk usage on Plex volumes ---
DISK_OVER=""
for v in "${DISK_VOLUMES[@]}"; do
    LINE=$(df -h "$v" 2>/dev/null | awk -v t="$DISK_THRESHOLD" 'NR==2 { gsub(/%/,"",$5); if ($5+0 > t+0) print $0 }')
    [ -n "$LINE" ] && DISK_OVER+="$LINE\n"
done
DISK_TRIGGERED=0
[ -n "$DISK_OVER" ] && DISK_TRIGGERED=1

# --- Check: NUT/UPS ---
# Two independent things can go wrong here, and checking only one hides the other:
#   1. `upsc ups0@192.168.178.123` fails outright — the NAS or the network path to it
#      is broken. Same class of failure WBU's own monitor watches for.
#   2. `upsc` succeeds, but the LOCAL com.dennis.mmm-nut-upsmon daemon isn't running.
#      This is the client-only failure mode WBU's template doesn't need: `upsc` here
#      opens its own fresh connection straight to the NAS's upsd, completely bypassing
#      our local upsmon — so a dead local daemon and a healthy one look IDENTICAL to
#      it. Only a direct process check catches this. If it's not running, this box has
#      no shutdown protection at all even though the NAS/network look perfectly fine.
UPS_OUT=$("$UPSC" "${UPS_NAME}@${UPS_HOST}" 2>/dev/null)
UPS_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
UPS_CHARGE=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="battery.charge"{print $2}')

UPS_UNREADABLE_TRIGGERED=0
[ -z "$UPS_STATUS" ] && UPS_UNREADABLE_TRIGGERED=1

# RB = replace battery — the only UPS fault that warns in advance rather than after
# the fact. No streak: it's a sticky fault, not a transient.
UPS_REPLACE_BATTERY_TRIGGERED=0
case " $UPS_STATUS " in *" RB "*) UPS_REPLACE_BATTERY_TRIGGERED=1 ;; esac

UPSMON_MISSING_TRIGGERED=0
pgrep -f "$UPSMON_PROC_PATTERN" >/dev/null 2>&1 || UPSMON_MISSING_TRIGGERED=1

# Deliberately NOT alerting on OB (on battery) — same reasoning as WBU: a brief mains
# flicker would page for nothing, and this box has no upssched timer to interact with
# anyway (it relies directly on the NAS's LOWBATT). Worth a nightly mention, not a
# real-time page — see nightly_summary.sh.

# --- Check: Plex + Syncthing (process presence, then HTTP health if present) ---
declare -A MISSING_TRIGGERED DOWN_TRIGGERED
DOWN_DETAIL_SYNCTHING=""
check_service() {
    local svc=$1 pattern=$2 url=$3
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        MISSING_TRIGGERED[$svc]=1
        DOWN_TRIGGERED[$svc]=0
    else
        MISSING_TRIGGERED[$svc]=0
        CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
        if [ "$CODE" = "200" ]; then
            DOWN_TRIGGERED[$svc]=0
        else
            DOWN_TRIGGERED[$svc]=1
        fi
    fi
}
check_service PLEX "$PLEX_PROC_PATTERN" "$PLEX_URL"
check_service SYNCTHING "$SYNCTHING_PROC_PATTERN" "$SYNCTHING_URL"

# --- Check: Syncthing per-folder sync state (only meaningful if the basic check above
# didn't already find it missing/down) — catches a folder stuck in "error" state or
# excessive pull errors, which /rest/noauth/health alone would not detect. ---
if [ "${MISSING_TRIGGERED[SYNCTHING]}" -eq 0 ] && [ "${DOWN_TRIGGERED[SYNCTHING]}" -eq 0 ]; then
    ST_BASE="http://127.0.0.1:8384"
    ST_CONFIG=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" --max-time 5 "$ST_BASE/rest/config" 2>/dev/null)
    if [ -z "$ST_CONFIG" ]; then
        DOWN_TRIGGERED[SYNCTHING]=1
        DOWN_DETAIL_SYNCTHING="Could not reach $ST_BASE/rest/config to inspect folder state.\n"
    else
        ST_ERROR_FOLDERS=0
        ST_PULL_ERRS=0
        while IFS=$'\t' read -r fid label; do
            [ -z "$fid" ] && continue
            DB=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" --max-time 5 \
                 --get --data-urlencode "folder=$fid" "$ST_BASE/rest/db/status" 2>/dev/null)
            STATE=$(echo "$DB" | jq -r '.state // "unknown"' 2>/dev/null)
            PE=$(echo "$DB" | jq -r '.pullErrors // 0' 2>/dev/null)
            if [ "$STATE" = "error" ]; then
                ST_ERROR_FOLDERS=$((ST_ERROR_FOLDERS + 1))
                DOWN_DETAIL_SYNCTHING+="Folder '${label:-$fid}' is in error state.\n"
            elif [ "${PE:-0}" -gt 0 ] 2>/dev/null; then
                ST_PULL_ERRS=$((ST_PULL_ERRS + PE))
            fi
        done < <(echo "$ST_CONFIG" | jq -r '.folders[] | [.id, .label] | @tsv' 2>/dev/null)

        if [ "$ST_ERROR_FOLDERS" -gt 0 ]; then
            DOWN_TRIGGERED[SYNCTHING]=1
        elif [ "$ST_PULL_ERRS" -gt "$SYNCTHING_PULL_ERR_THRESHOLD" ]; then
            DOWN_TRIGGERED[SYNCTHING]=1
            DOWN_DETAIL_SYNCTHING+="${ST_PULL_ERRS} failed items across folders (threshold ${SYNCTHING_PULL_ERR_THRESHOLD}).\n"
        fi
    fi
fi

# --- Evaluate each condition: alert / suppress / clear / ok ---
check_condition() {
    local triggered=$1 last_alert=$2 was_active=$3
    if [ "$triggered" -eq 1 ]; then
        if [ "$was_active" -eq 0 ] || [ $(( NOW - last_alert )) -ge $ALERT_INTERVAL ]; then
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
            if [ "$was_active" -eq 0 ] || [ $(( NOW - last_alert )) -ge $ALERT_INTERVAL ]; then
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

# Disk
case "$(check_condition $DISK_TRIGGERED $DISK_LAST_ALERT $DISK_ACTIVE)" in
    alert)
        DISK_LAST_ALERT=$NOW; DISK_ACTIVE=1
        ALERT_BODY+="=== DISK USAGE ABOVE ${DISK_THRESHOLD}% ===\n$(echo -e "$DISK_OVER")\n\n"
        ;;
    clear)   DISK_ACTIVE=0; CLEAR_BODY+="  - disk usage returned to normal\n" ;;
    suppress) DISK_ACTIVE=1 ;;
    ok)       DISK_ACTIVE=0 ;;
esac

# UPS unreadable (streak-based: a daemon restart during install.sh/kickstart makes
# upsc/the daemon blip briefly — same reasoning as WBU's identical threshold)
read verdict new_streak <<< "$(check_condition_streak $UPS_UNREADABLE_TRIGGERED $UPS_UNREADABLE_LAST_ALERT $UPS_UNREADABLE_ACTIVE $UPS_UNREADABLE_STREAK $UPS_FAIL_THRESHOLD)"
UPS_UNREADABLE_STREAK=$new_streak
case "$verdict" in
    alert)
        UPS_UNREADABLE_LAST_ALERT=$NOW; UPS_UNREADABLE_ACTIVE=1
        ALERT_BODY+="=== UPS UNREADABLE ===\n"
        ALERT_BODY+="${UPSC} ${UPS_NAME}@${UPS_HOST} returned nothing for ${new_streak} consecutive checks (~$((new_streak * 5)) min).\n"
        ALERT_BODY+="This Mac Mini has NO shutdown signal while this is broken.\n\n"
        ALERT_BODY+="Check, in order:\n"
        ALERT_BODY+="  1. Is the Mac Mini's network (Wi-Fi/Ethernet) actually up?\n"
        ALERT_BODY+="  2. Is the NAS (192.168.178.123) reachable at all — ping it.\n"
        ALERT_BODY+="  3. ssh dhm@192.168.178.123 and check upsd is running there.\n\n"
        ;;
    clear)   UPS_UNREADABLE_ACTIVE=0; CLEAR_BODY+="  - UPS readable again (${UPS_STATUS}, ${UPS_CHARGE}%)\n" ;;
    suppress) UPS_UNREADABLE_ACTIVE=1 ;;
    wait|ok) UPS_UNREADABLE_ACTIVE=0 ;;
esac

# UPS replace-battery
case "$(check_condition $UPS_REPLACE_BATTERY_TRIGGERED $UPS_REPLACE_BATTERY_LAST_ALERT $UPS_REPLACE_BATTERY_ACTIVE)" in
    alert)
        UPS_REPLACE_BATTERY_LAST_ALERT=$NOW; UPS_REPLACE_BATTERY_ACTIVE=1
        ALERT_BODY+="=== UPS REPLACE BATTERY ===\n"
        ALERT_BODY+="${UPS_NAME} reports RB (status: ${UPS_STATUS}, charge: ${UPS_CHARGE}%).\n"
        ALERT_BODY+="This is a fleet-wide fault (UPS #1, on the NAS) — it also affects the\n"
        ALERT_BODY+="router, switch and NAS itself, not just this Mac Mini.\n\n"
        ;;
    clear)   UPS_REPLACE_BATTERY_ACTIVE=0; CLEAR_BODY+="  - UPS no longer reporting replace-battery\n" ;;
    suppress) UPS_REPLACE_BATTERY_ACTIVE=1 ;;
    ok)       UPS_REPLACE_BATTERY_ACTIVE=0 ;;
esac

# Local upsmon daemon missing (streak-based, same threshold — a `kickstart -k` restart
# or an OS-update daemon reset shouldn't page on the first sample)
read verdict new_streak <<< "$(check_condition_streak $UPSMON_MISSING_TRIGGERED $UPSMON_MISSING_LAST_ALERT $UPSMON_MISSING_ACTIVE $UPSMON_MISSING_STREAK $UPS_FAIL_THRESHOLD)"
UPSMON_MISSING_STREAK=$new_streak
case "$verdict" in
    alert)
        UPSMON_MISSING_LAST_ALERT=$NOW; UPSMON_MISSING_ACTIVE=1
        ALERT_BODY+="=== LOCAL UPSMON DAEMON MISSING ===\n"
        ALERT_BODY+="No process matching '${UPSMON_PROC_PATTERN}' for ${new_streak} consecutive checks (~$((new_streak * 5)) min).\n"
        ALERT_BODY+="The NAS/UPS may look perfectly healthy above — this box still has NO\n"
        ALERT_BODY+="shutdown protection while its own upsmon isn't running.\n\n"
        ALERT_BODY+="Check: sudo launchctl print system/com.dennis.mmm-nut-upsmon\n\n"
        ;;
    clear)   UPSMON_MISSING_ACTIVE=0; CLEAR_BODY+="  - local upsmon daemon is back\n" ;;
    suppress) UPSMON_MISSING_ACTIVE=1 ;;
    wait|ok) UPSMON_MISSING_ACTIVE=0 ;;
esac

# Plex + Syncthing
for svc in PLEX SYNCTHING; do
    # Missing (process not found)
    trig=${MISSING_TRIGGERED[$svc]}
    last=$(eval echo \$MISSING_${svc}_LAST_ALERT)
    active=$(eval echo \$MISSING_${svc}_ACTIVE)
    streak=$(eval echo \$MISSING_${svc}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $FAIL_THRESHOLD)"
    eval "MISSING_${svc}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "MISSING_${svc}_LAST_ALERT=$NOW; MISSING_${svc}_ACTIVE=1"
            ALERT_BODY+="=== ${svc} MISSING ===\n"
            ALERT_BODY+="No process matching '${svc}' found for ${new_streak} consecutive checks (~$((new_streak * 5)) min).\n\n"
            ;;
        clear)   eval "MISSING_${svc}_ACTIVE=0"
                 CLEAR_BODY+="  - ${svc} process is back\n" ;;
        suppress) eval "MISSING_${svc}_ACTIVE=1" ;;
        wait|ok) eval "MISSING_${svc}_ACTIVE=0" ;;
    esac

    # Down (process present, HTTP health check failing)
    trig=${DOWN_TRIGGERED[$svc]}
    last=$(eval echo \$DOWN_${svc}_LAST_ALERT)
    active=$(eval echo \$DOWN_${svc}_ACTIVE)
    streak=$(eval echo \$DOWN_${svc}_STREAK)
    read verdict new_streak <<< "$(check_condition_streak $trig $last $active $streak $FAIL_THRESHOLD)"
    eval "DOWN_${svc}_STREAK=$new_streak"
    case "$verdict" in
        alert)
            eval "DOWN_${svc}_LAST_ALERT=$NOW; DOWN_${svc}_ACTIVE=1"
            ALERT_BODY+="=== ${svc} NOT RESPONDING ===\n"
            if [ "$svc" = "SYNCTHING" ] && [ -n "$DOWN_DETAIL_SYNCTHING" ]; then
                ALERT_BODY+="Present for ${new_streak} consecutive checks (~$((new_streak * 5)) min):\n$(echo -e "$DOWN_DETAIL_SYNCTHING")\n\n"
            else
                ALERT_BODY+="Process is running but its HTTP API did not return 200 for ${new_streak} consecutive checks.\n\n"
            fi
            ;;
        clear)   eval "DOWN_${svc}_ACTIVE=0"
                 CLEAR_BODY+="  - ${svc} is responding again\n" ;;
        suppress) eval "DOWN_${svc}_ACTIVE=1" ;;
        wait|ok) eval "DOWN_${svc}_ACTIVE=0" ;;
    esac
done

# --- Educational footer ---
FOOTER="------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

DISK USAGE ABOVE ${DISK_THRESHOLD}%:
One of the Plex source volumes is nearly full. Plex/Syncthing can behave
oddly (failed writes, partial downloads) once a volume fills completely.

What to do:
  1. df -h ${DISK_VOLUMES[*]}    -- confirm which volume and how full
  2. du -sh /Volumes/.../* | sort -h | tail -20   -- find what's using space

PLEX / SYNCTHING MISSING:
No process matching the app's binary was found — it quit or crashed.
Requires ${FAIL_THRESHOLD} consecutive checks (~$((FAIL_THRESHOLD * 5)) min) before alerting, to ride
out a normal app restart/update.

What to do:
  1. open -a \"Plex Media Server\"   /   open -a \"Syncthing\"
  2. Check Console.app for crash reports under the app's name

PLEX / SYNCTHING NOT RESPONDING:
The process is running but its own HTTP API isn't answering (Plex:
32400/identity, Syncthing: 8384/rest/noauth/health) — likely hung.

What to do:
  1. curl http://127.0.0.1:32400/identity   /   curl http://127.0.0.1:8384/rest/noauth/health
  2. If hung: quit and relaunch the app (or reboot if it won't quit)

UPS UNREADABLE:
upsc could not reach ${UPS_NAME}@${UPS_HOST} (the NAS) for ${UPS_FAIL_THRESHOLD} consecutive
checks. This box has no shutdown signal at all until it clears.

What to do:
  1. Confirm this Mac Mini's own network is up.
  2. ping 192.168.178.123 — is the NAS reachable?
  3. ssh dhm@192.168.178.123 and check upsd/the nutdrv_qx driver are alive.

UPS REPLACE BATTERY:
${UPS_NAME} (UPS #1, on the NAS) reports RB — it believes its battery can no
longer hold a useful charge. Fleet-wide, not specific to this Mac Mini.

What to do:
  1. Check the physical UPS's own front-panel indicator.
  2. Plan a battery replacement — runtime during a real outage may be far
     shorter than expected.

LOCAL UPSMON DAEMON MISSING:
No process matching '${UPSMON_PROC_PATTERN}' for ${UPS_FAIL_THRESHOLD} consecutive checks.
The NAS and network can be perfectly healthy and this alert still fires —
it means THIS box's own shutdown-trigger process died, silently, which upsc
alone can't detect (see the comment in the script's NUT/UPS check).

What to do:
  1. sudo launchctl print system/com.dennis.mmm-nut-upsmon
  2. cat /Library/Logs/mmm_nut_upsmon.log — look for why it exited
  3. cd ~/repos/scripts/launchdaemons && sudo ./install.sh   -- reinstall
------------------------------------------------------------------------"

# --- Save state ---
{
    echo "DISK_LAST_ALERT=$DISK_LAST_ALERT"
    echo "DISK_ACTIVE=$DISK_ACTIVE"
    echo "UPS_UNREADABLE_LAST_ALERT=$UPS_UNREADABLE_LAST_ALERT"
    echo "UPS_UNREADABLE_ACTIVE=$UPS_UNREADABLE_ACTIVE"
    echo "UPS_UNREADABLE_STREAK=$UPS_UNREADABLE_STREAK"
    echo "UPS_REPLACE_BATTERY_LAST_ALERT=$UPS_REPLACE_BATTERY_LAST_ALERT"
    echo "UPS_REPLACE_BATTERY_ACTIVE=$UPS_REPLACE_BATTERY_ACTIVE"
    echo "UPSMON_MISSING_LAST_ALERT=$UPSMON_MISSING_LAST_ALERT"
    echo "UPSMON_MISSING_ACTIVE=$UPSMON_MISSING_ACTIVE"
    echo "UPSMON_MISSING_STREAK=$UPSMON_MISSING_STREAK"
    for svc in PLEX SYNCTHING; do
        for k in MISSING_${svc}_LAST_ALERT MISSING_${svc}_ACTIVE MISSING_${svc}_STREAK \
                 DOWN_${svc}_LAST_ALERT DOWN_${svc}_ACTIVE DOWN_${svc}_STREAK; do
            echo "$k=$(eval echo \$$k)"
        done
    done
} > "$STATE_FILE"

# --- Send alert email ---
if [ -n "$ALERT_BODY" ]; then
    {
        echo "Subject: [${HOST}] HEALTH ALERT -- $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo -e "$ALERT_BODY"
        echo "$FOOTER"
    } | "$MSMTP" -a icloud "$TO"
fi

# --- Send all-clear email ---
if [ -n "$CLEAR_BODY" ]; then
    {
        echo "Subject: [${HOST}] ALL CLEAR -- $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo "The following conditions have resolved:"
        echo ""
        echo -e "$CLEAR_BODY"
    } | "$MSMTP" -a icloud "$TO"
fi
