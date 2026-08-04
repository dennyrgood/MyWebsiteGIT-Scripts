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

# --- Load state (defaults to zero/inactive if file absent) ---
DISK_LAST_ALERT=0; DISK_ACTIVE=0
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
------------------------------------------------------------------------"

# --- Save state ---
{
    echo "DISK_LAST_ALERT=$DISK_LAST_ALERT"
    echo "DISK_ACTIVE=$DISK_ACTIVE"
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
