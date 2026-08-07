#!/bin/bash
# ~/repos/scripts/FleetNAS/nas-nightly-summary.sh
# 2026-08-07: FIXED: smartctl was called as a bare command but lives in /sbin,
#             which is not on root's cron PATH. Every drive therefore reported
#             health= realloc=0 pending=0 temp=0, and the empty health string
#             failed the != "PASSED" test, so all 3 drives were flagged with a
#             misleading "SMART drive error" subject EVERY night. Now uses an
#             absolute SMARTCTL path, matching the existing MDADM constant.
# 2026-08-07: "SMART unreadable" is now its own state with its own subject
#             reason, distinct from a drive that is genuinely failing.
# 2026-08-07: email cleanup — DISK USAGE filtered to real filesystems with the
#             /volume1 + /home duplicate collapsed; monitor state file and health
#             log summarised instead of dumped whole; added per-drive model /
#             serial / power-on-hours and a rebuild ETA; subject line now picks
#             the most severe issue rather than the last one tested, and an
#             in-progress rebuild is surfaced in the subject.
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
# Absolute paths: root's cron PATH is /usr/bin:/bin and both live in /sbin.
MDADM=/sbin/mdadm
SMARTCTL=/sbin/smartctl
RAID_DEV=/dev/md1
UPS_NAME="ups0"
UPS_HOST="localhost"
MONITOR_STATE="/tmp/nas-monitor-state.tmp"
MONITOR_STALE_SECS=900   # 15 min; cron runs monitor every 5 min
HEALTH_LOG="/var/log/nas-health-monitor.log"

BODY=""

# Issues are collected by severity so the subject line reports the WORST
# problem, not whichever test happened to run last.
ISSUES_CRIT=(); ISSUES_WARN=(); ISSUES_INFO=()
add_issue() {
    case "$1" in
        crit) ISSUES_CRIT+=("$2") ;;   # data at risk right now
        warn) ISSUES_WARN+=("$2") ;;   # needs attention / monitoring is blind
        info) ISSUES_INFO+=("$2") ;;   # expected but noteworthy, e.g. a rebuild
    esac
}

# Read SMART for one drive into SM_* globals.
#   SM_STATE  = ok | unreadable      SM_REASON = why, when unreadable
# A failed read is never defaulted to 0 — that is what made every drive look
# both healthy and broken at the same time.
read_smart() {
    local d=$1 out rc
    SM_STATE="unreadable"; SM_REASON=""
    SM_HEALTH=""; SM_REALLOC=""; SM_PENDING=""; SM_TEMP=""
    SM_MODEL=""; SM_SERIAL=""; SM_HOURS=""

    if [ ! -x "$SMARTCTL" ]; then
        SM_REASON="smartctl not found or not executable at ${SMARTCTL}"
        return
    fi

    out=$("$SMARTCTL" -i -H -A "/dev/$d" 2>&1); rc=$?
    # smartctl exit bits: 1=usage, 2=device open failed, 4=ATA/SMART command
    # failed OR bad checksum in a SMART structure. These WD80EFPX drives ALWAYS
    # set bit 4 ("invalid SMART checksum" on the thresholds table) while serving
    # perfectly good data, so rc!=0 must not mean unreadable. Only bit 2 does.
    if [ $(( rc & 2 )) -ne 0 ]; then
        SM_REASON="smartctl could not open /dev/${d} (exit ${rc})"
        return
    fi

    SM_HEALTH=$(printf '%s\n' "$out" | awk '/SMART overall-health/{print $NF}')
    # Match on attribute name, falling back to attribute ID for drives whose
    # vendor names differ.
    SM_REALLOC=$(printf '%s\n' "$out" | awk '$2=="Reallocated_Sector_Ct"{print $10+0; exit} $1==5{r=$10+0} END{if(r!="")print r}')
    SM_PENDING=$(printf '%s\n' "$out" | awk '$2=="Current_Pending_Sector"{print $10+0; exit} $1==197{r=$10+0} END{if(r!="")print r}')
    SM_TEMP=$(printf '%s\n' "$out"    | awk '$2 ~ /^(Temperature_Celsius|Airflow_Temperature_Cel|Temperature_Internal)$/{print $10+0; exit} ($1==194||$1==190){r=$10+0} END{if(r!="")print r}')
    SM_HOURS=$(printf '%s\n' "$out"   | awk '$2=="Power_On_Hours"{print $10+0; exit} $1==9{r=$10+0} END{if(r!="")print r}')
    SM_MODEL=$(printf '%s\n' "$out"   | awk -F': *' '/^Device Model:/{print $2; exit}')
    SM_SERIAL=$(printf '%s\n' "$out"  | awk -F': *' '/^Serial Number:/{print $2; exit}')

    if [ -z "$SM_HEALTH" ] || [ -z "$SM_REALLOC" ] || [ -z "$SM_PENDING" ] || [ -z "$SM_TEMP" ]; then
        SM_REASON="smartctl ran (exit ${rc}) but its output could not be parsed for /dev/${d}"
        return
    fi
    SM_STATE="ok"
}

# --- SMART snapshot per drive ---
SMART_TLDR=""
SMART_UNREADABLE_N=0
SMART_FAILING_N=0
BODY+="=== SMART DRIVE HEALTH ===\n"
for d in "${DRIVES[@]}"; do
    read_smart "$d"

    if [ "$SM_STATE" != "ok" ]; then
        # Distinct from both healthy and failing: we do not know.
        SMART_UNREADABLE_N=$(( SMART_UNREADABLE_N + 1 ))
        SMART_TLDR+="  ❓ /dev/${d}: SMART UNREADABLE — condition unknown\n"
        BODY+="  /dev/${d}: SMART UNREADABLE  ❓\n"
        BODY+="      ${SM_REASON}\n"
        continue
    fi

    LINE="  /dev/${d}: health=${SM_HEALTH} realloc=${SM_REALLOC} pending=${SM_PENDING} temp=${SM_TEMP}°C"
    if [ "$SM_REALLOC" -gt 0 ] || [ "$SM_PENDING" -gt 0 ] || [ "$SM_HEALTH" != "PASSED" ]; then
        SMART_FAILING_N=$(( SMART_FAILING_N + 1 ))
        SMART_TLDR+="  ⚠️ /dev/${d}: health=${SM_HEALTH} realloc=${SM_REALLOC} pending=${SM_PENDING} temp=${SM_TEMP}°C\n"
        BODY+="${LINE}  ⚠️\n"
    else
        SMART_TLDR+="  /dev/${d}: health=${SM_HEALTH} realloc=${SM_REALLOC} pending=${SM_PENDING} temp=${SM_TEMP}°C ✓\n"
        BODY+="${LINE}  ✓\n"
    fi
    BODY+="      $(printf '%-22s %-14s %s' "${SM_MODEL:-unknown model}" "${SM_SERIAL:-no serial}" "power-on ${SM_HOURS:-?}h ($(( ${SM_HOURS:-0} / 24 ))d)")\n"
done
BODY+="\n"

[ "$SMART_FAILING_N"    -gt 0 ] && add_issue crit "SMART drive error"
[ "$SMART_UNREADABLE_N" -gt 0 ] && add_issue warn "SMART unreadable on ${SMART_UNREADABLE_N} drive(s)"

# --- RAID array state ---
RAID_UNREADABLE=0
RAID_UNREADABLE_REASON=""
if [ ! -x "$MDADM" ]; then
    RAID_DETAIL=""
    RAID_UNREADABLE=1
    RAID_UNREADABLE_REASON="mdadm not found or not executable at ${MDADM}"
else
    RAID_DETAIL=$(sudo $MDADM --detail $RAID_DEV 2>/dev/null)
    if [ -z "$RAID_DETAIL" ]; then
        RAID_UNREADABLE=1
        RAID_UNREADABLE_REASON="${MDADM} --detail ${RAID_DEV} returned nothing"
    fi
fi
# xargs squeezes the trailing blanks left by single-word states like 'clean'.
RAID_STATE=$(printf '%s\n' "$RAID_DETAIL" | awk '/State :/ && !/RaidDevice/ {print $3, $4, $5}' | xargs)
RAID_PCT=$(printf '%s\n' "$RAID_DETAIL" | awk -F': *' '/Rebuild Status/{print $2; exit}')
# mdadm reports percent complete but not a finish time; /proc/mdstat has both.
RAID_ETA=$(awk '/(recovery|resync|reshape) *=/{for(i=1;i<=NF;i++){if($i~/^finish=/)f=substr($i,8); if($i~/^speed=/)s=substr($i,7)}; if(f!="")printf "ETA %s, %s", f, s; exit}' /proc/mdstat 2>/dev/null)

RAID_TLDR=""
if [ "$RAID_UNREADABLE" -eq 1 ]; then
    add_issue crit "RAID state unreadable"
    RAID_TLDR="  ❓ RAID: UNREADABLE — ${RAID_UNREADABLE_REASON}"
else
    case "$RAID_STATE" in
        *failed*)
            add_issue crit "RAID array FAILED"
            RAID_TLDR="  ⚠️ RAID: FAILED — ${RAID_STATE}"
            ;;
        *degraded*)
            if [[ "$RAID_STATE" == *recovering* ]]; then
                # A rebuild is exactly the window in which a second drive
                # failure destroys the array, so it belongs in the subject
                # even though it is an expected, self-resolving state.
                add_issue info "RAID rebuilding${RAID_PCT:+ ${RAID_PCT}}"
                RAID_TLDR="  🔄 RAID: rebuilding — ${RAID_STATE}"
                [ -n "$RAID_PCT" ] && RAID_TLDR+=" (${RAID_PCT}"
                [ -n "$RAID_PCT" ] && [ -n "$RAID_ETA" ] && RAID_TLDR+=", ${RAID_ETA}"
                [ -n "$RAID_PCT" ] && RAID_TLDR+=")"
                RAID_TLDR+=" — NO REDUNDANCY until complete"
            else
                add_issue crit "RAID array DEGRADED"
                RAID_TLDR="  ⚠️ RAID: DEGRADED — ${RAID_STATE}"
            fi
            ;;
        clean*|active*)
            RAID_TLDR="  RAID: ${RAID_STATE} ✓"
            ;;
        *)
            add_issue crit "RAID unexpected state"
            RAID_TLDR="  ⚠️ RAID: unexpected state — ${RAID_STATE}"
            ;;
    esac
fi
BODY+="=== RAID ARRAY (${RAID_DEV}) ===\n"
if [ "$RAID_UNREADABLE" -eq 1 ]; then
    BODY+="${RAID_UNREADABLE_REASON}\nThe array's condition is UNKNOWN — this is not the same as clean.\n\n"
else
    BODY+="${RAID_DETAIL}\n"
    [ -n "$RAID_ETA" ] && BODY+="\nRebuild: ${RAID_PCT} — ${RAID_ETA}\n"
    BODY+="\n"
fi

# --- Disk usage ---
# Only real, writable filesystems. The pseudo-filesystems (udev, tmpfs, overlay,
# efivarfs) and the read-only squashfs loop mounts that back the UGREEN OS are
# all either meaningless or permanently 100% full, so they were pure noise.
# /volume1 and /home are the same LVM volume mounted twice; collapse them into
# one row listing both mountpoints rather than printing the device twice.
real_filesystems() {
    df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
      | awk 'NR>1 && $1 ~ /^\/dev\// && $1 !~ /^\/dev\/loop/'
}
DISK_TABLE=$(real_filesystems | awk '
    { if (!($1 in seen)) { seen[$1]=1; order[++n]=$1; row[$1]=$1" "$2" "$3" "$4" "$5; mnt[$1]=$6 }
      else { mnt[$1]=mnt[$1]", "$6 } }
    END { printf "  %-46s %6s %6s %6s %5s  %s\n","FILESYSTEM","SIZE","USED","AVAIL","USE%","MOUNTED ON"
          for (i=1;i<=n;i++) { split(row[order[i]],f," ")
              printf "  %-46s %6s %6s %6s %5s  %s\n", f[1],f[2],f[3],f[4],f[5],mnt[order[i]] } }')
DISK_OVER=$(real_filesystems | awk '{ gsub(/%/,"",$5); if ($5+0 > 85) print "      "$1" "$5"% full, mounted on "$6 }')
DISK_USAGE=$(real_filesystems | awk '$6=="/volume1" {print $3"/"$2" ("$5")"; exit}')
DISK_TLDR="  disk /volume1: ${DISK_USAGE:-unknown} ✓"
if [ -n "$DISK_OVER" ]; then
    add_issue warn "disk usage above 85%"
    DISK_TLDR="  ⚠️ disk usage above 85%:\n${DISK_OVER}"
fi
BODY+="=== DISK USAGE ===\n${DISK_TABLE}\n\n"

# --- UPS status ---
UPS_OUT=$(upsc "${UPS_NAME}@${UPS_HOST}" 2>/dev/null)
UPS_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
UPS_CHARGE=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="battery.charge"{print $2}')
UPS_LOAD=$(printf '%s\n'   "$UPS_OUT" | awk -F': ' '$1=="ups.load"{print $2}')
UPS_TLDR="  ups: ${UPS_STATUS} charge=${UPS_CHARGE}% load=${UPS_LOAD}%"
if [ -z "$UPS_STATUS" ]; then
    add_issue warn "UPS unreadable"
    UPS_TLDR="  ⚠️ ups: unreadable (upsc ${UPS_NAME}@${UPS_HOST} returned nothing)"
else
    case " $UPS_STATUS " in
        *" RB "*) add_issue crit "UPS replace battery"
                  UPS_TLDR="  ⚠️ ups: ${UPS_STATUS} charge=${UPS_CHARGE}% — REPLACE BATTERY" ;;
        *)        UPS_TLDR+=" ✓" ;;
    esac
fi
BODY+="=== UPS (${UPS_NAME}@${UPS_HOST}) ===\n${UPS_OUT}\n\n"

# --- Health monitor freshness ---
MONITOR_FRESH_LINE=""
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        add_issue warn "health monitor stale"
        MONITOR_FRESH_LINE="  ⚠️ nas-health-monitor: stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)"
    else
        MONITOR_FRESH_LINE="  nas-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓"
    fi
else
    add_issue warn "health monitor state file missing"
    MONITOR_FRESH_LINE="  ⚠️ nas-health-monitor: state file missing ($MONITOR_STATE)"
fi

# --- Health monitor active alerts ---
MONITOR_ACTIVE_LINE=""
ACTIVE_ALERTS=""
if [ -f "$MONITOR_STATE" ]; then
    ACTIVE_ALERTS=$(grep '_ACTIVE=1$' "$MONITOR_STATE" | sed 's/_ACTIVE=1$//' | paste -sd', ' -)
    if [ -n "$ACTIVE_ALERTS" ]; then
        add_issue warn "active health alerts"
        MONITOR_ACTIVE_LINE="  ⚠️ nas-health-monitor: active alerts: ${ACTIVE_ALERTS}"
    else
        MONITOR_ACTIVE_LINE="  nas-health-monitor: no active alerts ✓"
    fi
fi

# --- Health monitor state: only the actionable parts ---
# The raw file is ~50 lines of zeros. What matters is which conditions are
# currently firing and which are part-way to firing (streak > 0 but below the
# alert threshold) — i.e. something starting to go wrong that has not paged yet.
BODY+="=== NAS HEALTH MONITOR STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    BODY+="  ${MONITOR_FRESH_LINE#  }\n"
    if [ -n "$ACTIVE_ALERTS" ]; then
        BODY+="  active alerts: ${ACTIVE_ALERTS}\n"
    else
        BODY+="  active alerts: none\n"
    fi
    PENDING_STREAKS=$(awk -F= '/_STREAK=/ && $2+0 > 0 {sub(/_STREAK/,"",$1); printf "  %s at %s consecutive failure(s)\n", $1, $2}' "$MONITOR_STATE")
    if [ -n "$PENDING_STREAKS" ]; then
        BODY+="  building toward an alert:\n${PENDING_STREAKS}\n"
    fi
    BODY+="  (full state: ${MONITOR_STATE})\n"
else
    BODY+="  (file not found: ${MONITOR_STATE})\n"
fi
BODY+="\n"

# --- Health monitor log: last 24h of events, headers only ---
# Every alert entry carries the same ~60-line educational footer, so dumping the
# whole log meant re-reading that footer once per alert ever recorded. Show the
# event headers and their alert sections from the last 24h; the footer is in the
# alert emails themselves and in the log on disk.
BODY+="=== NAS HEALTH MONITOR EVENTS (last 24h) ===\n"
if [ -f "$HEALTH_LOG" ]; then
    CUTOFF=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M' 2>/dev/null)
    RECENT=$(awk -v cutoff="$CUTOFF" '
        /^===== / {
            # header looks like: ===== [FleetNAS] TYPE -- YYYY-MM-DD HH:MM UTC =====
            show = 0
            if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/)) {
                ts = substr($0, RSTART, RLENGTH)
                if (cutoff == "" || ts >= cutoff) { show = 1; print "  " $0 }
            }
            next
        }
        show && (/^=== / || /^  - /) { print "    " $0 }
    ' "$HEALTH_LOG")
    if [ -n "$RECENT" ]; then
        BODY+="${RECENT}\n"
    else
        BODY+="  no alerts or all-clears logged in the last 24h ✓\n"
    fi
    BODY+="  (full log with remediation footers: ${HEALTH_LOG}, $(wc -l < "$HEALTH_LOG" | xargs) lines, $(du -h "$HEALTH_LOG" | cut -f1))\n"
else
    BODY+="  (file not found: ${HEALTH_LOG})\n"
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
# Report the most severe issue found, not whichever check ran last. The old
# sequential assignment let "disk usage above 85%" overwrite "RAID array
# problem" simply because it was tested later.
ALL_ISSUES=( "${ISSUES_CRIT[@]}" "${ISSUES_WARN[@]}" "${ISSUES_INFO[@]}" )
if   [ ${#ISSUES_CRIT[@]} -gt 0 ]; then EMOJI="⚠️";  REASON="${ISSUES_CRIT[0]}"
elif [ ${#ISSUES_WARN[@]} -gt 0 ]; then EMOJI="⚠️";  REASON="${ISSUES_WARN[0]}"
elif [ ${#ISSUES_INFO[@]} -gt 0 ]; then EMOJI="🔄"; REASON="${ISSUES_INFO[0]}"
else                                    EMOJI="✅"; REASON="all healthy"
fi
[ ${#ALL_ISSUES[@]} -gt 1 ] && REASON+=" (+$(( ${#ALL_ISSUES[@]} - 1 )) more)"

SUBJECT="${EMOJI} ${HOST} nightly $(date '+%Y-%m-%d') — ${REASON}"

# --- Send via SSH to WBU msmtp ---
# NAS_DRYRUN=1 prints the message instead of sending it, so changes to this
# script can be checked on the real box without emailing.
if [ "${NAS_DRYRUN:-0}" = "1" ]; then
    printf 'To: %s\nSubject: %s\n\n' "$TO" "$SUBJECT"
    echo -e "$BODY"
    exit 0
fi

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | ssh -o BatchMode=yes "$WBU" "sudo msmtp --account=icloud $TO"
