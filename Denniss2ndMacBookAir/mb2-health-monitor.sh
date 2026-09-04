#!/opt/homebrew/bin/bash
# Created: 2026-08-30 UTC — denniss-2nd-macbook-air (mb2) service health monitor, modeled
# on DennissMacBookAir/mb-health-monitor.sh (itself modeled on
# MathesMacMini/mathes-mac-mini-health-monitor.sh) but scoped to what actually runs on
# THIS box. mb2 is NOT a mirror of mb: as of 2026-08-30, `launchmgr status` showed
# com.dennis.search-adv-web, com.dennis.search-shows-web, and com.dennis.tmdb-explorer
# loaded here too, all permanently exit-78 (EX_CONFIG) with empty logs and no process —
# their ProgramArguments pointed at `.venv/bin/python` under repo subdirs that were never
# set up on this box (no venv present at all). Those three were confirmed dead, unloaded,
# and their plists removed from ~/Library/LaunchAgents on this box (never wire them back in
# here without first creating the matching .venv on mb2). No comfy-fleet-http/-scan here
# either — that pair only runs on mb.
#
# Services covered here (all launchd KeepAlive, confirmed actually running 2026-08-30):
#   fleet-metrics-server (9100, serves this box's own heartbeat/metrics files)
#   heartbeat-writer    (writes those files — no HTTP endpoint of its own)
#   travel-http         (5030, static file server for the travel site)
#
# Run via launchd every 5 min (see com.dennis.mb2-health-monitor.plist). Alerts on
# first detection and every 30 min while a condition persists; sends all-clear when
# it resolves; silent when everything's healthy. Missing vs down distinction per
# service (mirrors mb/mmm/WBU): missing = process not found (crashed/quit), down =
# process running but its own HTTP endpoint isn't answering (hung).

HOST="denniss-2nd-macbook-air"
TO="dennyrgood@yahoo.com"
MSMTP="/opt/homebrew/bin/msmtp"
STATE_FILE="/tmp/denniss-2nd-macbook-air-monitor-state.tmp"
NOW=$(date +%s)
ALERT_INTERVAL=$((30 * 60))
FAIL_THRESHOLD=2   # consecutive 5-min samples before alerting (anti-flap on restarts)

# HEARTBEAT_WRITER has no HTTP endpoint of its own — its "down" state comes from the
# freshness check below instead of check_service's usual curl. METRICS_SERVER's own
# liveness proof IS this box's own heartbeat file being served, so that doubles as
# its check URL.
METRICS_SERVER_PROC_PATTERN="fleet_metrics_server.py"
METRICS_SERVER_URL="http://127.0.0.1:9100/heartbeat_${HOST}.txt"
HEARTBEAT_WRITER_PROC_PATTERN="onedrive_heartbeat_writer_all_macs.py"
HEARTBEAT_FILE="$HOME/fleet_monitor/heartbeat_${HOST}.txt"
HEARTBEAT_STALE_SECS=600   # writer heartbeats every 150s — 4x margin before alerting
TRAVEL_HTTP_PROC_PATTERN="http.server 5030"
TRAVEL_HTTP_URL="http://127.0.0.1:5030/"

# --- Load state (defaults to zero/inactive if file absent) ---
for svc in METRICS_SERVER HEARTBEAT_WRITER TRAVEL_HTTP; do
    eval "MISSING_${svc}_LAST_ALERT=0; MISSING_${svc}_ACTIVE=0; MISSING_${svc}_STREAK=0"
    eval "DOWN_${svc}_LAST_ALERT=0;    DOWN_${svc}_ACTIVE=0;    DOWN_${svc}_STREAK=0"
done

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# --- Check: all services (process presence, then HTTP health if present) ---
declare -A MISSING_TRIGGERED DOWN_TRIGGERED
check_service() {
    local svc=$1 pattern=$2 url=$3
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        MISSING_TRIGGERED[$svc]=1
        DOWN_TRIGGERED[$svc]=0
    else
        MISSING_TRIGGERED[$svc]=0
        if [ -z "$url" ]; then
            # No HTTP endpoint for this one (HEARTBEAT_WRITER) — "down" is decided
            # by the freshness check layered on below instead.
            DOWN_TRIGGERED[$svc]=0
        else
            CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
            if [ "$CODE" = "200" ]; then
                DOWN_TRIGGERED[$svc]=0
            else
                DOWN_TRIGGERED[$svc]=1
            fi
        fi
    fi
}
check_service METRICS_SERVER "$METRICS_SERVER_PROC_PATTERN" "$METRICS_SERVER_URL"
check_service HEARTBEAT_WRITER "$HEARTBEAT_WRITER_PROC_PATTERN" ""
check_service TRAVEL_HTTP "$TRAVEL_HTTP_PROC_PATTERN" "$TRAVEL_HTTP_URL"

# --- Check: heartbeat-writer freshness (only meaningful if the basic check above
# didn't already find it missing) — same shape as mb/mmm's version: no HTTP endpoint
# to probe, so a hang (process alive, stuck mid-loop) can only be caught by checking
# whether HEARTBEAT_FILE is actually still being updated. ---
DOWN_DETAIL_HEARTBEAT_WRITER=""
if [ "${MISSING_TRIGGERED[HEARTBEAT_WRITER]}" -eq 0 ]; then
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        DOWN_TRIGGERED[HEARTBEAT_WRITER]=1
        DOWN_DETAIL_HEARTBEAT_WRITER="${HEARTBEAT_FILE} does not exist yet.\n"
    else
        HB_AGE=$(( NOW - $(stat -f %m "$HEARTBEAT_FILE") ))
        if [ "$HB_AGE" -gt "$HEARTBEAT_STALE_SECS" ]; then
            DOWN_TRIGGERED[HEARTBEAT_WRITER]=1
            DOWN_DETAIL_HEARTBEAT_WRITER="${HEARTBEAT_FILE} last written $((HB_AGE / 60))m ago (threshold $((HEARTBEAT_STALE_SECS / 60))m).\n"
        fi
    fi
fi

# --- Evaluate each condition: alert / suppress / clear / ok ---
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

for svc in METRICS_SERVER HEARTBEAT_WRITER TRAVEL_HTTP; do
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

    # Down (process present, HTTP health check failing). 2026-09-04 fix: only evaluate
    # this at all when the service isn't ALSO missing this round. check_service() sets
    # DOWN_TRIGGERED[$svc]=0 whenever the process is gone (there's nothing to curl), but
    # treating that as a real "down" reading of 0 fed a false "<svc> is responding
    # again" CLEAR_BODY line the moment a service went from down-but-running straight to
    # missing/crashed — the exact same run that also reports it MISSING. Skipping the
    # eval entirely when missing leaves DOWN_${svc}_ACTIVE/STREAK untouched (frozen, not
    # cleared), so a real recovery still gets correctly reported once the service is
    # actually back and healthy again.
    if [ "${MISSING_TRIGGERED[$svc]}" -eq 0 ]; then
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
                if [ "$svc" = "HEARTBEAT_WRITER" ] && [ -n "$DOWN_DETAIL_HEARTBEAT_WRITER" ]; then
                    ALERT_BODY+="Present for ${new_streak} consecutive checks (~$((new_streak * 5)) min):\n$(echo -e "$DOWN_DETAIL_HEARTBEAT_WRITER")\n\n"
                else
                    ALERT_BODY+="Process is running but its HTTP endpoint did not return 200 for ${new_streak} consecutive checks.\n\n"
                fi
                ;;
            clear)   eval "DOWN_${svc}_ACTIVE=0"
                     CLEAR_BODY+="  - ${svc} is responding again\n" ;;
            suppress) eval "DOWN_${svc}_ACTIVE=1" ;;
            wait|ok) eval "DOWN_${svc}_ACTIVE=0" ;;
        esac
    fi
done

# --- Educational footer ---
FOOTER="------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

<SVC> MISSING:
No process matching the service's launchd command was found — it quit or
crashed. Requires ${FAIL_THRESHOLD} consecutive checks (~$((FAIL_THRESHOLD * 5)) min) before
alerting, to ride out a normal restart. All of these are launchd KeepAlive
agents, so this firing at all usually means it's crash-looping faster than
launchd can win.

What to do:
  1. launchctl list | grep com.dennis
  2. launchctl kickstart -k gui/\$(id -u)/com.dennis.<label>
  3. Check that service's own log under ~/Library/Logs/ for why it exited.

<SVC> NOT RESPONDING:
The process is running but its own HTTP endpoint isn't answering — likely hung.

What to do:
  1. curl the service's URL (see the *_URL constants at the top of this script)
  2. If hung: launchctl kickstart -k gui/\$(id -u)/com.dennis.<label>

HEARTBEAT_WRITER MISSING:
No process matching '${HEARTBEAT_WRITER_PROC_PATTERN}' found — this box's own
fleet-status heartbeat/machine_info/metrics_history files have stopped
updating, which silently blinds the fleet dashboard to this box even though
everything else here may be fine.

What to do:
  1. launchctl kickstart -k gui/\$(id -u)/com.dennis.heartbeat-writer
  2. cat ~/Library/Logs/heartbeat_writer.log — look for why it exited

HEARTBEAT_WRITER NOT RESPONDING:
The process is running but ${HEARTBEAT_FILE} hasn't been updated within
${HEARTBEAT_STALE_SECS}s (it should tick every 150s) — likely hung mid-loop.

What to do:
  1. ls -la ${HEARTBEAT_FILE}   -- confirm how stale
  2. launchctl kickstart -k gui/\$(id -u)/com.dennis.heartbeat-writer

METRICS_SERVER MISSING / NOT RESPONDING:
No process matching '${METRICS_SERVER_PROC_PATTERN}', or it's running but not
serving this box's own heartbeat file over HTTP (127.0.0.1:9100). The fleet
checker pulls from here over Tailscale — either failure mode means the fleet
dashboard can't see this box, even if HEARTBEAT_WRITER itself is fine.

What to do:
  1. curl http://127.0.0.1:9100/heartbeat_${HOST}.txt
  2. launchctl kickstart -k gui/\$(id -u)/com.dennis.fleet-metrics-server
------------------------------------------------------------------------"

# --- Save state ---
{
    for svc in METRICS_SERVER HEARTBEAT_WRITER TRAVEL_HTTP; do
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

# --- Heartbeat (matches mb/mmm's rationale) ---
# Everything above is silent by design on a healthy run -- one line per run, always
# emitted, to plain stdout so com.dennis.mb2-health-monitor.plist's StandardOutPath
# gives positive proof the job ran vs. silently broke.
ACTIVE_COUNT=$(grep -c "_ACTIVE=1" "$STATE_FILE" 2>/dev/null || true)
ACTIVE_COUNT=${ACTIVE_COUNT:-0}
echo "$(date '+%Y-%m-%d %H:%M:%S') check complete — ${ACTIVE_COUNT} active alert(s)"
