#!/bin/bash
# /home/dhm/repos/scripts/WorkBenchUnix/nightly_summary.sh
# 2026-07-01 20:00 UTC
# Daily health summary email — tails all backup logs, checks health monitor
# freshness and active alerts, sends via msmtp.
# 2026-07-03 09:00 UTC — added TLDR block
# 2026-07-03 09:30 UTC — switched grep -v to -vE for alternation
# 2026-07-03 11:00 UTC — replaced fragile word-scan STATUS check with per-log success-string check
# 2026-07-05 HH:MM UTC — added 6-hour staleness check for CWHU sync log
# 2026-07-12 UTC — renamed subject "Backup Summary" -> "Health Summary".
#                  Added wbu-health-monitor watchdog: freshness (>15 min = NOT OK),
#                  active alerts by name in TLDR, state file dumped at bottom.
#                  Corrected header path from /srv/immich/scripts/ to actual cron location.
# 2026-07-23 UTC — added system-health section after an unrecoverable rcu_preempt
#                  stall + hard reset: (1) NVMe SMART one-liner, (2) unclean-reboot
#                  post-mortem (auto-dumps the prior boot's rcu/oom/lockup/error
#                  lines, keyed by explicit boot ID to dodge post-crash clock skew),
#                  (3) kernel crash-capture (/sys/fs/pstore) dump. Each contributes
#                  a TLDR line and can flip STATUS to NOT OK. Pairs with the
#                  kernel.panic_on_rcu_stall sysctl (99-wbu-crash-capture.conf).
# 2026-08-03 UTC — added the two daily FleetNAS Immich backups (db 05:00, images
#                  05:20, both well finished by the 06:30 send). Unlike the
#                  Friday-only Mac Mini logs these are daily, so they get the
#                  full treatment: tail + TLDR line, success-string check, and a
#                  24h staleness check that catches a missed night on the very
#                  next email.
# 2026-08-03 UTC — every TLDR log line now carries a relative age "[3d ago]". The
#                  subject gate reports only the single highest-priority failure,
#                  so a stale log was invisible whenever another check won the
#                  gate — which is exactly what happened on the first FleetNAS
#                  email: a 3-day-old db log displayed its cheerful "complete"
#                  last line while the images check owned the subject.

TO="dennyrgood@yahoo.com"
LINES=5
MONITOR_STATE="/tmp/wbu-monitor-state.tmp"
MONITOR_STALE_SECS=900   # 15 minutes; cron runs monitor every 5 min

MACMINI_DB=$(ls -1t /home/dhm/.cache/export-sync/macmini_db_*.log 2>/dev/null | head -1)
MACMINI_IMG=$(ls -1t /home/dhm/.cache/export-sync/macmini_images_*.log 2>/dev/null | head -1)
CWHU_SYNC=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_log_*.txt 2>/dev/null | head -1)
CWHU_ERRORS=$(ls -1t /home/dhm/.cache/cwhu-warm-sync/sync_errors_*.txt 2>/dev/null | head -1)
# FleetNAS logs are per-run and timestamped, so pick the newest of each. The `:-`
# fallback matters: these strings are used as EXPECTED/LABEL array keys below, and
# an empty key would collide between the two and print an empty name in the subject.
FLEETNAS_DB=$(ls -1t /home/dhm/.cache/fleetnas-sync/fleetnas_db_*.log 2>/dev/null | head -1)
FLEETNAS_DB=${FLEETNAS_DB:-/home/dhm/.cache/fleetnas-sync/fleetnas_db_NONE.log}
FLEETNAS_IMG=$(ls -1t /home/dhm/.cache/fleetnas-sync/fleetnas_images_*.log 2>/dev/null | head -1)
FLEETNAS_IMG=${FLEETNAS_IMG:-/home/dhm/.cache/fleetnas-sync/fleetnas_images_NONE.log}
EXPORT_ARCHIVE=$(cat /home/dhm/.cache/immich-export/export_archive.log 2>/dev/null | wc -l > /dev/null; echo /home/dhm/.cache/immich-export/export_archive.log)

LOGS=(
    # "/var/log/immich-backup-c.log"  # 2026-07-22: backup-c drive retired (repeat failures), cron disabled — see WorkBenchUnix/backup_immich.sh comment
    "/var/log/immich-dump-for-cwhu.log"
    "/var/log/immich-restic.log"
    "/var/log/syncthing-offsite.log"
    "$MACMINI_DB"
    "$MACMINI_IMG"
    "$CWHU_SYNC"
    "$CWHU_ERRORS"
    "$FLEETNAS_DB"
    "$FLEETNAS_IMG"
    "/home/dhm/.cache/immich-export/export_archive.log"
    "/home/dhm/.cache/immich-export/export_flat_to_amsterdamdesktop.log"
    "/home/dhm/.cache/immich-export/export_multi_to_amsterdamdesktop.log"
    "/home/dhm/.cache/immich-export/export_flat_to_macmini.log"
    "/home/dhm/.cache/immich-export/export_multi_to_macmini.log"
)

BODY=""
for LOG in "${LOGS[@]}"; do
    BODY+="=== $LOG ===\n"
    if [ -f "$LOG" ]; then
        BODY+="$(tail -$LINES $LOG)\n"
    else
        BODY+="(file not found)\n"
    fi
    BODY+="\n"
done

# --- Append health monitor state file to bottom of body ---
BODY+="=== $MONITOR_STATE ===\n"
if [ -f "$MONITOR_STATE" ]; then
    BODY+="$(cat "$MONITOR_STATE")\n"
else
    BODY+="(file not found)\n"
fi
BODY+="\n"

# --- Evaluate health monitor freshness ---
# Empty MONITOR_FRESH_LINE means healthy (nothing to add to TLDR beyond the OK line).
MONITOR_FRESH_LINE=""
MONITOR_FRESH_BAD=0
if [ -f "$MONITOR_STATE" ]; then
    MONITOR_AGE=$(( $(date +%s) - $(stat -c %Y "$MONITOR_STATE") ))
    if [ "$MONITOR_AGE" -gt "$MONITOR_STALE_SECS" ]; then
        MONITOR_FRESH_LINE="  wbu-health-monitor: ⚠️ stale (last-run $((MONITOR_AGE / 60))m ago; threshold $((MONITOR_STALE_SECS / 60))m)"
        MONITOR_FRESH_BAD=1
    else
        MONITOR_FRESH_LINE="  wbu-health-monitor: last-run $((MONITOR_AGE / 60))m ago ✓"
    fi
else
    MONITOR_FRESH_LINE="  wbu-health-monitor: ⚠️ state file missing ($MONITOR_STATE)"
    MONITOR_FRESH_BAD=1
fi

# --- Extract active alerts from state file ---
# Any line matching *_ACTIVE=1 means that condition is currently firing.
MONITOR_ACTIVE_LINE=""
MONITOR_ACTIVE_BAD=0
if [ -f "$MONITOR_STATE" ]; then
    ACTIVE_ALERTS=$(grep '_ACTIVE=1$' "$MONITOR_STATE" | sed 's/_ACTIVE=1$//' | paste -sd', ' -)
    if [ -n "$ACTIVE_ALERTS" ]; then
        MONITOR_ACTIVE_LINE="  wbu-health-monitor: ⚠️ active alerts: ${ACTIVE_ALERTS}"
        MONITOR_ACTIVE_BAD=1
    else
        MONITOR_ACTIVE_LINE="  wbu-health-monitor: no active alerts ✓"
    fi
fi

# ============================================================================
# System-health checks (added 2026-07-23). This script runs from root's crontab,
# so `nvme`, /sys/fs/pstore, and full journalctl are all readable here.
# Each block sets: a *_BAD flag (feeds STATUS), a *_TLDR line, and appends detail
# to BODY. None use `set -e`; a failing probe degrades to "(unavailable)".
# ============================================================================

# --- NVMe SMART health (#3) ---
# Text output is parsed (not JSON) because the critical_warning field type varies
# across nvme-cli versions; the human-readable "key : value" layout is stable.
NVME_DEV="/dev/nvme0"
SMART_BAD=0
SMART_TLDR="  nvme-smart: (unavailable)"
SMART_BLOCK="(nvme smart-log unavailable)"
if command -v nvme >/dev/null 2>&1 && [ -e "$NVME_DEV" ]; then
    SMART_TXT=$(nvme smart-log "$NVME_DEV" 2>/dev/null)
    if [ -n "$SMART_TXT" ]; then
        smart_get() { echo "$SMART_TXT" | awk -F: -v k="$1" 'index($0,k)==1 {gsub(/^[ \t]+/,"",$2); print $2; exit}'; }
        cw=$(smart_get "critical_warning")
        pu=$(smart_get "percentage_used")
        asp=$(smart_get "available_spare")
        aspt=$(smart_get "available_spare_threshold")
        me=$(smart_get "media_errors")
        us=$(smart_get "unsafe_shutdowns")
        # Normalize to bare integers for comparison (strip %, hex prefixes, words).
        cwn=$(echo "$cw"  | grep -oE '[0-9]+' | head -1); cwn=${cwn:-0}
        pun=$(echo "$pu"  | grep -oE '[0-9]+' | head -1); pun=${pun:-0}
        aspn=$(echo "$asp" | grep -oE '[0-9]+' | head -1); aspn=${aspn:-100}
        asptn=$(echo "$aspt" | grep -oE '[0-9]+' | head -1); asptn=${asptn:-0}
        men=$(echo "$me"  | grep -oE '[0-9]+' | head -1); men=${men:-0}
        [ "$cwn" -ne 0 ]        && SMART_BAD=1   # any critical warning bit set
        [ "$men" -gt 0 ]        && SMART_BAD=1   # media/data-integrity errors
        [ "$pun" -ge 90 ]       && SMART_BAD=1   # endurance nearly exhausted
        [ "$aspn" -le "$asptn" ] && SMART_BAD=1  # spare blocks at/below threshold
        SMART_TLDR="  nvme-smart: crit_warn=${cwn} used=${pun}% spare=${aspn}% media_err=${men} unsafe_shutdowns=${us}"
        [ "$SMART_BAD" -eq 1 ] && SMART_TLDR="⚠️${SMART_TLDR}" || SMART_TLDR="${SMART_TLDR} ✓"
        SMART_BLOCK="critical_warning:        ${cw}\npercentage_used:         ${pu}\navailable_spare:         ${asp} (threshold ${aspt})\nmedia_errors:            ${me}\nunsafe_shutdowns:        ${us}"
    fi
fi
BODY+="=== NVMe SMART ($NVME_DEV) ===\n${SMART_BLOCK}\n\n"

# --- Kernel crash capture / pstore (#1, reporting half) ---
# With kernel.panic_on_rcu_stall=1 (99-wbu-crash-capture.conf), a stall/panic
# writes a backtrace here that survives the reboot. Anything present == a crash
# was captured and should be reviewed.
PSTORE_DIR="/sys/fs/pstore"
PSTORE_BAD=0
PSTORE_TLDR="  pstore: empty ✓"
PSTORE_BLOCK="(none — no kernel crash captured)"
if [ -d "$PSTORE_DIR" ]; then
    PS_FILES=$(ls -1 "$PSTORE_DIR" 2>/dev/null)
    if [ -n "$PS_FILES" ]; then
        PSTORE_BAD=1
        PS_N=$(echo "$PS_FILES" | grep -c .)
        PSTORE_TLDR="⚠️  pstore: ${PS_N} captured crash record(s) — a kernel panic/oops was recorded"
        PSTORE_BLOCK="Records present:\n${PS_FILES}\n"
        PS_NEWEST=$(ls -1t "$PSTORE_DIR"/dmesg-* 2>/dev/null | head -1)
        if [ -n "$PS_NEWEST" ]; then
            PSTORE_BLOCK+="\n--- ${PS_NEWEST} (tail) ---\n$(tail -40 "$PS_NEWEST" 2>/dev/null)\n"
        fi
        PSTORE_BLOCK+="\nAfter reviewing, clear with:  sudo rm -f ${PSTORE_DIR}/*"
    fi
fi
BODY+="=== Kernel crash capture ($PSTORE_DIR) ===\n${PSTORE_BLOCK}\n\n"

# --- Unclean-reboot post-mortem (#2) ---
# If the PREVIOUS boot ended within the last 24h WITHOUT a clean-shutdown marker,
# dump its kernel crash signatures + last error-priority lines. Keyed by explicit
# boot ID (not `-b -1`) because post-crash clock skew can make the relative offset
# resolve to the wrong boot.
REBOOT_BAD=0
REBOOT_TLDR="  last-reboot: none/clean in last 24h ✓"
REBOOT_BLOCK="(no unclean reboot detected in the last 24h)"
PREV_BOOT_ID=$(journalctl --list-boots --no-pager 2>/dev/null | awk '$1=="-1"{print $2; exit}')
if [ -n "$PREV_BOOT_ID" ]; then
    PREV_LAST_EPOCH=$(journalctl --boot="$PREV_BOOT_ID" --no-pager -n1 -o short-unix 2>/dev/null | awk '{print int($1)}')
    NOW_EPOCH=$(date +%s)
    if [ -n "$PREV_LAST_EPOCH" ] && [ $(( NOW_EPOCH - PREV_LAST_EPOCH )) -lt 86400 ]; then
        PREV_TAIL=$(journalctl --boot="$PREV_BOOT_ID" --no-pager 2>/dev/null | tail -25)
        if ! echo "$PREV_TAIL" | grep -qE "systemd-shutdown|Reached target.*(Shutdown|Reboot|Power-Off|Halt)|Deactivated swap|Unmounted"; then
            REBOOT_BAD=1
            SIGS=$(journalctl --boot="$PREV_BOOT_ID" -k --no-pager 2>/dev/null | grep -iE "rcu.*stall|soft lockup|hung_task|blocked for more than|invoked oom-killer|Out of memory|Kernel panic|I/O error|EXT4-fs error|mce:|Hardware Error" | tail -15)
            ERRS=$(journalctl --boot="$PREV_BOOT_ID" -p err --no-pager 2>/dev/null | tail -15)
            REBOOT_TLDR="⚠️  last-reboot: UNCLEAN shutdown detected (prev boot ended $(date -d @${PREV_LAST_EPOCH} '+%Y-%m-%d %H:%M'))"
            REBOOT_BLOCK="Previous boot ${PREV_BOOT_ID} ended UNCLEANLY at $(date -d @${PREV_LAST_EPOCH} '+%Y-%m-%d %H:%M') (no clean-shutdown marker in its final entries).\n\n"
            REBOOT_BLOCK+="--- kernel crash signatures (rcu/lockup/oom/io/mce) ---\n${SIGS:-(none found)}\n\n"
            REBOOT_BLOCK+="--- last 15 error-priority lines from that boot ---\n${ERRS:-(none)}"
        fi
    fi
fi
BODY+="=== Unclean-reboot post-mortem ===\n${REBOOT_BLOCK}\n\n"

# --- UPS / NUT (added 2026-08-04) ---
# WBU became the NUT server for UPS #2 on 2026-08-04, and WorkBenchUnix,
# ChatWorkhorseUnix, ChatWorkhorse and ImageBeast all take their shutdown signal
# from it. Real-time faults — driver dead, replace-battery — are wbu-health-monitor's
# job and already surface through the active-alerts line above; this block is the
# nightly view instead: what the UPS says right now, and whether we ran on battery
# overnight.
#
# On-battery events are deliberately NOT a real-time alert. A brief flicker would
# page for nothing, and during a genuine outage the box may be shutting down before
# the mail leaves. But "we were on battery at 3am and you slept through it" is worth
# knowing over coffee, so it is counted here.
UPS_BAD=0
UPS_REASON=""
UPS_TLDR="  ups: (unavailable)"
UPS_BLOCK="(upsc returned nothing for ups2@localhost — see wbu-health-monitor alerts)"
UPS_OUT=$(upsc ups2@localhost 2>/dev/null)
if [ -n "$UPS_OUT" ]; then
    U_STATUS=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="ups.status"{print $2}')
    U_CHARGE=$(printf '%s\n' "$UPS_OUT" | awk -F': ' '$1=="battery.charge"{print $2}')
    U_LOAD=$(printf '%s\n'   "$UPS_OUT" | awk -F': ' '$1=="ups.load"{print $2}')
    # grep -c exits 1 on zero matches; || true keeps that from emptying the variable.
    ONBATT_N=$(journalctl -u nut-monitor --since '24 hours ago' --no-pager 2>/dev/null \
               | grep -c 'running on battery' || true)
    ONBATT_N=${ONBATT_N:-0}
    UPS_TLDR="  ups: ${U_STATUS} charge=${U_CHARGE}% load=${U_LOAD}% on-battery-events-24h=${ONBATT_N}"
    case " $U_STATUS " in
        *" OB "*) UPS_BAD=1; UPS_REASON="UPS on battery";      UPS_TLDR="⚠️${UPS_TLDR} — ON BATTERY NOW" ;;
        *" RB "*) UPS_BAD=1; UPS_REASON="UPS replace battery"; UPS_TLDR="⚠️${UPS_TLDR} — REPLACE BATTERY" ;;
        *)        if [ "$ONBATT_N" -gt 0 ]; then
                      UPS_TLDR="${UPS_TLDR} (ran on battery in the last 24h)"
                  else
                      UPS_TLDR="${UPS_TLDR} ✓"
                  fi ;;
    esac
    UPS_BLOCK="$UPS_OUT"
else
    UPS_BAD=1
    UPS_REASON="UPS unreadable"
    UPS_TLDR="⚠️  ups: unreadable (upsc ups2@localhost returned nothing)"
fi
BODY+="=== UPS (ups2@localhost) ===\n${UPS_BLOCK}\n\n"

# --- Build TLDR (age + last line of each log, plus monitor watchdog lines) ---
# Age is shown because the last line alone can't be read for staleness: a log that
# ends in "... complete ===" looks green at a glance whether it ran an hour ago or
# last Tuesday. The STATUS gate below only ever surfaces ONE failure in the subject,
# so without an age here a stale log stays invisible whenever some other check wins
# that gate. No threshold judgement is applied per line — the logs have genuinely
# different expected cadences (daily, Friday-only, manual-only), so the age is
# reported plainly and the reader judges it.
fmt_age() {
    local secs=$1
    if   [ "$secs" -lt 3600 ];   then echo "$((secs / 60))m"
    elif [ "$secs" -lt 172800 ]; then echo "$((secs / 3600))h"   # keep hours up to 48h: "25h" says more than "1d"
    else echo "$((secs / 86400))d"
    fi
}

# --- Purpose-built TLDR lines for the two backup layers (2026-08-25) --------
# The generic loop below prints "<filename>: [age] <last line>", which is fine
# for a dozen mirror jobs but buries the two facts that now matter most: is the
# local repo verified, and is the off-site copy keeping up. These get named
# lines with a pass/fail glyph like the hardware checks above, and are skipped
# in the generic loop so they are not printed twice.
#
# On failure the line carries the REASON, not just a cross: both scripts log it
# as "PROBLEM:" or "FAILED:" on their way out, so the email says what broke
# without needing the full body below.
RESTIC_LOG="/var/log/immich-restic.log"
OFFSITE_LOG="/var/log/syncthing-offsite.log"

build_backup_tldr() {
    local log="$1" label="$2" marker="$3" detail_re="$4"
    local age detail reason
    if [ ! -f "$log" ]; then
        echo "  ${label}: never run (no $log)"
        return
    fi
    age=$(fmt_age $(( $(date +%s) - $(stat -c %Y "$log") )))
    if tail -5 "$log" | grep -q "$marker"; then
        detail=$(tail -5 "$log" | grep -oP "$detail_re" | tail -1)
        echo "  ${label}: [${age} ago] ${detail:-verified} ✓"
    else
        reason=$(tail -8 "$log" | grep -oP '(?<=PROBLEM: ).*|(?<=FAILED: ).*' | tail -1)
        echo "  ${label}: ⚠️ [${age} ago] ${reason:-did not complete}"
    fi
}

# The off-site line needs three states, not two. A tick means "a complete
# off-site copy exists"; an hourglass means "healthy, but not there yet". They
# are different facts and collapsing them into one tick overstates the
# protection actually in place -- at 4% seeded there is no off-site backup at
# all. The hourglass deliberately does NOT set OK=0: nothing is broken, so the
# subject line stays reserved for things that need acting on.
build_offsite_tldr() {
    local log="$OFFSITE_LOG" label="off-site (s3g)"
    local age line state detail reason
    if [ ! -f "$log" ]; then
        echo "  ${label}: never run (no $log)"
        return
    fi
    age=$(fmt_age $(( $(date +%s) - $(stat -c %Y "$log") )))
    line=$(tail -5 "$log" | grep -F "SYNCTHING OFFSITE OK" | tail -1)
    if [ -z "$line" ]; then
        reason=$(tail -8 "$log" | grep -oP '(?<=PROBLEM: ).*|(?<=FAILED: ).*' | tail -1)
        echo "  ${label}: ⚠️ [${age} ago] ${reason:-did not complete}"
        return
    fi
    state=$(printf '%s' "$line" | grep -oP '(?<=OK \[)[a-z]+(?=\])')
    detail=$(printf '%s' "$line" | grep -oP '(?<=\().*(?=\))')
    case "$state" in
        current)  echo "  ${label}: [${age} ago] ${detail} ✓" ;;
        seeding)  echo "  ${label}: ⏳ [${age} ago] ${detail}" ;;
        catchup)  echo "  ${label}: ⏳ [${age} ago] ${detail}" ;;
        # Older log lines predate the [state] token; report plainly rather
        # than guessing at a glyph.
        *)        echo "  ${label}: [${age} ago] ${detail:-ok}" ;;
    esac
}

RESTIC_TLDR=$(build_backup_tldr "$RESTIC_LOG" "restic backup" \
    "RESTIC BACKUP VERIFIED OK" 'snapshots retained.*')
OFFSITE_TLDR=$(build_offsite_tldr)

TLDR="============================= TLDR ===============================\n"
TLDR+="${REBOOT_TLDR}\n"
TLDR+="${PSTORE_TLDR}\n"
TLDR+="${SMART_TLDR}\n"
TLDR+="${UPS_TLDR}\n"
TLDR+="${RESTIC_TLDR}\n"
TLDR+="${OFFSITE_TLDR}\n"
NOW_TLDR=$(date +%s)
for LOG in "${LOGS[@]}"; do
    # Already reported above with a purpose-built line.
    case "$LOG" in "$RESTIC_LOG"|"$OFFSITE_LOG") continue ;; esac
    if [ -f "$LOG" ]; then
        AGE=$(fmt_age $(( NOW_TLDR - $(stat -c %Y "$LOG") )))
        TLDR+="  $(basename "$LOG"): [${AGE} ago] $(tail -1 "$LOG")\n"
    else
        TLDR+="  $(basename "$LOG"): (file not found)\n"
    fi
done
TLDR+="${MONITOR_FRESH_LINE}\n"
TLDR+="${MONITOR_ACTIVE_LINE}\n"
TLDR+="===================================================================\n\n"
BODY="${TLDR}${BODY}"

# --- Determine OK / NOT OK ---
# OK is the gate (1 = still healthy, checks below only fire while it's 1, so the
# highest-priority failure keeps the subject). REASON is the human phrase shown
# in the subject — deliberately NOT a raw filename. Emoji conveys pass/fail, so
# the subject reads: "<emoji> WorkBenchUnix nightly <date> — <REASON>".
OK=1
REASON="all healthy"

# --- Top-priority signals (2026-07-23): a real hardware/kernel fault — captured
# kernel crash, unclean reboot, or an NVMe SMART warning — outranks every softer
# warning (stale sync, backup-log strings, monitor freshness) for the SUBJECT
# line. Those are the headlines. Everything still appears in the TLDR/body
# regardless of what wins the subject. ---
if [ "$PSTORE_BAD" -eq 1 ]; then
    OK=0; REASON="kernel crash captured"
elif [ "$REBOOT_BAD" -eq 1 ]; then
    OK=0; REASON="unclean reboot in last 24h"
elif [ "$SMART_BAD" -eq 1 ]; then
    OK=0; REASON="NVMe SMART warning"
elif [ "$UPS_BAD" -eq 1 ]; then
    # Below the hardware/kernel headlines but above the log-string checks: an
    # unreadable UPS means this box and three others have no shutdown signal at all,
    # which outranks a stale backup log.
    OK=0; REASON="$UPS_REASON"
fi

# Check each log for its expected success string rather than scanning for bad words.
# sync_errors_*.txt is intentionally excluded — docker compose noise, no success string.
# Mac Mini logs are intentionally excluded — Friday-only, expected to be stale other days.
# Guarded on OK so it can't clobber a higher-priority fault above. LABEL maps each
# log to a human name so the subject never shows a raw timestamped filename.
declare -A EXPECTED=(
    # ["/var/log/immich-backup-c.log"]="Backup to /mnt/backup-c finished."  # 2026-07-22: backup-c drive retired (repeat failures), cron disabled
    ["/var/log/immich-dump-for-cwhu.log"]="Dump for CWHU complete."
    # Emitted only after backup AND forget AND check all succeed -- see
    # backup_immich_to_restic.sh. A finished-the-script banner would not do:
    # a corrupted blob or a failed integrity check must not read as success.
    ["/var/log/immich-restic.log"]="RESTIC BACKUP VERIFIED OK"
    # The restic marker above proves the LOCAL repo is good and says nothing
    # about the off-site copy. This one covers replication to s3g: daemon up,
    # s3g seen within 24h, no folder errors, and -- if data is still
    # outstanding -- actually moving. Deliberately NOT "100% synced": that
    # would fail nightly for days during a seed and train you to ignore it.
    ["/var/log/syncthing-offsite.log"]="SYNCTHING OFFSITE OK"
    ["$CWHU_SYNC"]="Warm-sync complete."
    ["$FLEETNAS_DB"]="Postgres dump sync to FleetNAS complete"
    # Deliberately NOT the trailing "=== Live image sync ... complete ===" banner:
    # that line prints even when the post-sync verification found drift, so it says
    # only "the script reached the end", not "the backup is good". The 0-differences
    # line is the real success signal. It sits 2 lines above the banner — inside the
    # tail -5 window the checker uses.
    ["$FLEETNAS_IMG"]="FleetNAS matches WBU exactly"
)
declare -A LABEL=(
    ["/var/log/immich-dump-for-cwhu.log"]="CWHU DB dump"
    ["/var/log/immich-restic.log"]="restic repo backup"
    ["/var/log/syncthing-offsite.log"]="off-site replication"
    ["$CWHU_SYNC"]="CWHU warm-sync"
    ["$FLEETNAS_DB"]="FleetNAS DB backup"
    ["$FLEETNAS_IMG"]="FleetNAS image backup"
)
if [ "$OK" -eq 1 ]; then
    for LOG in "${!EXPECTED[@]}"; do
        if [ ! -f "$LOG" ]; then
            OK=0; REASON="${LABEL[$LOG]:-$(basename "$LOG")} log missing"
            break
        fi
        if ! tail -5 "$LOG" | grep -q "${EXPECTED[$LOG]}"; then
            OK=0; REASON="${LABEL[$LOG]:-$(basename "$LOG")} did not complete"
            break
        fi
    done
fi

# --- Staleness check for CWHU sync log (lives on remote machine, can go stale) ---
# Also guarded so a fresh fault outranks a stale-sync warning in the subject.
if [ "$OK" -eq 1 ] && [ -f "$CWHU_SYNC" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CWHU_SYNC") ))
    if [ "$FILE_AGE" -gt 21600 ]; then  # 6 hours
        OK=0; REASON="CWHU warm-sync stale ($((FILE_AGE / 3600))h)"
    fi
fi

# --- Staleness check for the daily FleetNAS backups ---
# A success string alone can't tell "ran fine this morning" from "ran fine last
# Tuesday and the cron has been dead since" — the newest log still ends in success
# either way. 24h is the exact right threshold here: both jobs run ~05:00-05:20 and
# this email goes at 06:30, so a healthy log is ~1-1.5h old, and one missed night
# puts it at ~25h — caught on the very next email with margin to spare.
if [ "$OK" -eq 1 ]; then
    for LOG in "$FLEETNAS_DB" "$FLEETNAS_IMG" "/var/log/immich-restic.log" "/var/log/syncthing-offsite.log"; do
        [ -f "$LOG" ] || continue   # missing case already handled by the EXPECTED loop
        FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$LOG") ))
        if [ "$FILE_AGE" -gt 86400 ]; then
            OK=0; REASON="${LABEL[$LOG]:-$(basename "$LOG")} stale ($((FILE_AGE / 3600))h)"
            break
        fi
    done
fi

# --- Health monitor watchdog contributes to STATUS ---
# Only override if still OK; don't clobber a more specific existing failure.
if [ "$OK" -eq 1 ]; then
    if [ "$MONITOR_FRESH_BAD" -eq 1 ]; then
        OK=0; REASON="health monitor stale/missing"
    elif [ "$MONITOR_ACTIVE_BAD" -eq 1 ]; then
        OK=0; REASON="active health alerts"
    fi
fi

if [ "$OK" -eq 1 ]; then EMOJI="✅"; else EMOJI="⚠️"; fi
SUBJECT="${EMOJI} WorkBenchUnix nightly $(date '+%Y-%m-%d') — ${REASON}"

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo ""
    echo -e "$BODY"
} | msmtp --account=icloud "$TO"
