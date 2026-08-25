#!/bin/bash
# syncthing_offsite_status.sh — report on off-site replication of the restic
# repo to s3g, for the nightly summary email.
# Created: 2026-08-25.
#
# WHY THIS EXISTS
#   backup_immich_to_restic.sh proves the LOCAL repo is good. It says nothing
#   about whether the off-site copy exists. Without this, Syncthing could sit
#   disconnected for a fortnight and the nightly email would still be green,
#   which is precisely the false confidence the restic work was meant to end.
#
# WHAT COUNTS AS OK
#   Not "100% synced" -- during the initial ~90 GiB seed that would fail every
#   night for days, training you to ignore it. OK means: the daemon is up, s3g
#   has been seen recently, the folder has no errors, and -- if there is still
#   data outstanding -- it is actually MOVING. A connected-but-stalled transfer
#   is the failure mode that looks healthiest, so it is checked explicitly by
#   comparing outstanding bytes against the previous run.

set -u

DEVICE_ID="2U2VAWO-KDK4BX5-2W37CAZ-FA7R7BK-TTM3X4H-74YNQCQ-5JEV6RN-OHE2PQB"
DEVICE_NAME="s3g"
FOLDER_ID="immich-restic"
ST_CONFIG="/home/dhm/.local/state/syncthing/config.xml"

LOG="/var/log/syncthing-offsite.log"
STATE="/var/lib/syncthing-offsite.state"
LAST_SEEN_MAX_H=24          # hours since s3g last seen before this is a failure
# How long a backlog may persist before it stops being "seeding" and starts
# being "broken". Exceeding it FAILS the check, which turns the nightly email
# subject red -- this is the backstop against a transfer that creeps along
# forever without ever technically stalling.
#
# 3 days, not 14. The initial ~90GiB seed has an ETA around 8 hours, so this is
# already ~9x margin, and a large photo import adds far less. A limit set to a
# fortnight is not a safety margin, it is two weeks of not being told.
# Raise it only if a genuine import is repeatedly tripping it.
BACKLOG_MAX_DAYS=3

SUCCESS_MARKER="SYNCTHING OFFSITE OK"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

die() {
    log "PROBLEM: $*"
    log "=== syncthing off-site check ended WITHOUT success ==="
    exit 1
}

log "=== Checking off-site replication to $DEVICE_NAME ==="

systemctl is-active --quiet syncthing@dhm || die "syncthing@dhm is not running"

[ -r "$ST_CONFIG" ] || die "cannot read $ST_CONFIG"
KEY=$(grep -oPm1 '(?<=<apikey>)[^<]+' "$ST_CONFIG") || true
[ -n "${KEY:-}" ] || die "could not read API key from $ST_CONFIG"


# The GUI is plain HTTP or TLS depending on the "Use HTTPS for GUI" setting.
# Read it from the config rather than assuming. With TLS on, an http:// request
# returns a 307 redirect; curl -sf counts 3xx as success, so the body silently
# becomes redirect HTML instead of JSON and every later parse fails opaquely.
if grep -q '<gui[^>]*tls="true"' "$ST_CONFIG"; then
    GUI="https://127.0.0.1:8384"
    CURL_OPTS=(-sf -k)          # -k: Syncthing's GUI cert is self-signed
else
    GUI="http://127.0.0.1:8384"
    CURL_OPTS=(-sf)
fi

api() { curl "${CURL_OPTS[@]}" --max-time 15 -H "X-API-Key: $KEY" "$GUI$1" 2>/dev/null; }

# Confirm the API answers with JSON, not a redirect or a login page. Checking
# this once here turns a whole class of misconfiguration into one clear error.
PROBE=$(api /rest/system/status) || die "Syncthing API not responding on $GUI"
printf '%s' "$PROBE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null \
    || die "API at $GUI did not return JSON (auth failure, or wrong http/https scheme)"

# --- device connectivity -----------------------------------------------------
CONN_JSON=$(api /rest/system/connections) || die "could not query connections"
CONNECTED=$(printf '%s' "$CONN_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin).get('connections',{}).get('$DEVICE_ID',{})
print('yes' if d.get('connected') else 'no')
print(d.get('address') or '-')
print(d.get('type') or '-')
" 2>/dev/null) || die "could not parse connections"

IS_CONN=$(echo "$CONNECTED" | sed -n 1p)
ADDR=$(echo "$CONNECTED" | sed -n 2p)
CTYPE=$(echo "$CONNECTED" | sed -n 3p)
log "$DEVICE_NAME connected=$IS_CONN addr=$ADDR type=$CTYPE"

# lastSeen matters more than "connected right now": a laptop or a box on a
# flaky link is legitimately offline at 06:25 without anything being wrong.
STATS=$(api /rest/stats/device) || die "could not query device stats"
LAST_SEEN_H=$(printf '%s' "$STATS" | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin).get('$DEVICE_ID',{})
ls=d.get('lastSeen')
if not ls: print(-1)
else:
    t=datetime.datetime.fromisoformat(ls.replace('Z','+00:00'))
    now=datetime.datetime.now(datetime.timezone.utc)
    print(round((now-t).total_seconds()/3600,1))
" 2>/dev/null) || LAST_SEEN_H=-1
log "$DEVICE_NAME last seen ${LAST_SEEN_H}h ago"

# --- folder health -----------------------------------------------------------
FSTATUS=$(api "/rest/db/status?folder=$FOLDER_ID") || die "could not query folder status"
FOLDER_STATE=$(printf '%s' "$FSTATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('state','unknown'))
print(d.get('errors',0))
print(d.get('localBytes',0))
" 2>/dev/null)
FSTATE=$(echo "$FOLDER_STATE" | sed -n 1p)
FERRORS=$(echo "$FOLDER_STATE" | sed -n 2p)
LOCAL_GB=$(awk -v b="$(echo "$FOLDER_STATE" | sed -n 3p)" 'BEGIN{printf "%.1f", b/1073741824}')
log "folder '$FOLDER_ID' state=$FSTATE errors=$FERRORS localSize=${LOCAL_GB}GiB"

# --- how much is still outstanding -------------------------------------------
COMP=$(api "/rest/db/completion?folder=$FOLDER_ID&device=$DEVICE_ID") || die "could not query completion"
READ=$(printf '%s' "$COMP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(round(d.get('completion',0),2))
print(int(d.get('needBytes',0)))
" 2>/dev/null)
PCT=$(echo "$READ" | sed -n 1p)
NEED=$(echo "$READ" | sed -n 2p)
NEED_GB=$(awk -v b="$NEED" 'BEGIN{printf "%.2f", b/1073741824}')
log "replication to $DEVICE_NAME: ${PCT}% complete, ${NEED_GB}GiB outstanding"

# --- rate, ETA, and how long a backlog has persisted ----------------------
# Zero-progress is only the crudest failure. The subtler one is progress so
# slow the copy would never land, and the subtlest is a backlog that quietly
# becomes permanent after the seed is done. Tracking WHEN the backlog started
# -- rather than counting runs -- keeps this honest whether the script runs
# once a day from cron or ten times by hand.
PREV_NEED=""; PREV_AT=""; BACKLOG_SINCE=""; FIRST_COMPLETE=""; LAST_COMPLETE=""
if [ -r "$STATE" ]; then
    PREV_NEED=$(grep -oP '(?<=^NEED=)\d+' "$STATE" 2>/dev/null | head -1)
    PREV_AT=$(grep -oP '(?<=^AT=).+' "$STATE" 2>/dev/null | head -1)
    BACKLOG_SINCE=$(grep -oP '(?<=^BACKLOG_SINCE=).*' "$STATE" 2>/dev/null | head -1)
    # Whether a COMPLETE off-site copy has ever existed is a different fact
    # from how far along we are now. 4% during a first seed means there is no
    # off-site backup at all; 4% after a completed seed would mean a copy
    # exists and is briefly behind. Same number, very different exposure.
    FIRST_COMPLETE=$(grep -oP '(?<=^FIRST_COMPLETE=).*' "$STATE" 2>/dev/null | head -1)
    LAST_COMPLETE=$(grep -oP '(?<=^LAST_COMPLETE=).*' "$STATE" 2>/dev/null | head -1)
fi

NOW_EPOCH=$(date -u +%s)
STALLED=0
ETA_TXT=""

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$NEED" -eq 0 ]; then
    BACKLOG_SINCE=""
    LAST_COMPLETE="$NOW_ISO"
    [ -n "$FIRST_COMPLETE" ] || FIRST_COMPLETE="$NOW_ISO"
else
    [ -n "$BACKLOG_SINCE" ] || BACKLOG_SINCE="$NOW_ISO"
fi

if [ "$NEED" -gt 0 ] && [ -n "$PREV_NEED" ] && [ -n "$PREV_AT" ]; then
    PREV_EPOCH=$(date -u -d "$PREV_AT" +%s 2>/dev/null || echo 0)
    ELAPSED=$(( NOW_EPOCH - PREV_EPOCH ))
    MOVED=$(( PREV_NEED - NEED ))
    if [ "$MOVED" -le 0 ]; then
        STALLED=1
        log "WARNING: no progress since the previous check (${NEED_GB}GiB outstanding)"
    elif [ "$ELAPSED" -gt 0 ]; then
        RATE=$(awk -v m="$MOVED" -v e="$ELAPSED" 'BEGIN{printf "%.2f", m/e/1048576}')
        ETA_H=$(awk -v n="$NEED" -v m="$MOVED" -v e="$ELAPSED" \
                'BEGIN{ r=m/e; if(r>0) printf "%.1f", n/r/3600; else print "?" }')
        ETA_TXT=", ETA ~${ETA_H}h"
        log "progress: $(awk -v m="$MOVED" 'BEGIN{printf "%.2f", m/1073741824}')GiB moved at ${RATE}MiB/s, ETA ~${ETA_H}h"
    fi
fi

mkdir -p "$(dirname "$STATE")"
printf 'NEED=%s\nAT=%s\nBACKLOG_SINCE=%s\nFIRST_COMPLETE=%s\nLAST_COMPLETE=%s\n' \
    "$NEED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BACKLOG_SINCE" \
    "$FIRST_COMPLETE" "$LAST_COMPLETE" > "$STATE"

# --- verdict -----------------------------------------------------------------
[ "$FERRORS" -eq 0 ] 2>/dev/null || die "folder reports $FERRORS error(s)"

if [ "$LAST_SEEN_H" = "-1" ]; then
    die "$DEVICE_NAME has never been seen"
fi
if awk -v h="$LAST_SEEN_H" -v m="$LAST_SEEN_MAX_H" 'BEGIN{exit !(h>m)}'; then
    die "$DEVICE_NAME not seen for ${LAST_SEEN_H}h (threshold ${LAST_SEEN_MAX_H}h)"
fi
[ "$STALLED" -eq 0 ] || die "replication stalled at ${PCT}% — ${NEED_GB}GiB outstanding and not moving"

# A backlog is acceptable while it is shrinking toward completion. It stops
# being acceptable once it has simply been there too long, however healthy each
# individual night looked.
if [ "$NEED" -gt 0 ] && [ -n "$BACKLOG_SINCE" ]; then
    BL_EPOCH=$(date -u -d "$BACKLOG_SINCE" +%s 2>/dev/null || echo "$NOW_EPOCH")
    BL_DAYS=$(awk -v a="$NOW_EPOCH" -v b="$BL_EPOCH" 'BEGIN{printf "%.1f", (a-b)/86400}')
    log "backlog has existed for ${BL_DAYS} days (limit ${BACKLOG_MAX_DAYS})"
    if awk -v d="$BL_DAYS" -v m="$BACKLOG_MAX_DAYS" 'BEGIN{exit !(d>m)}'; then
        die "off-site copy has been behind for ${BL_DAYS} days — ${NEED_GB}GiB still outstanding"
    fi
fi

# The marker always says OK so the summary's EXPECTED check passes and the
# email subject stays reserved for things needing action. The [state] token
# lets the TLDR pick an honest glyph: a tick only when a complete off-site
# copy actually exists, an hourglass while one is still being built.
if [ "$NEED" -eq 0 ]; then
    log "off-site copy is fully up to date"
    log "$SUCCESS_MARKER [current] (100%, up to date)"
elif [ -z "$FIRST_COMPLETE" ]; then
    log "INITIAL SEED still running — no complete off-site copy exists yet"
    log "$SUCCESS_MARKER [seeding] (${PCT}%, ${NEED_GB}GiB outstanding${ETA_TXT} — no complete copy yet)"
else
    AGO=""
    if [ -n "$LAST_COMPLETE" ]; then
        LC_EPOCH=$(date -u -d "$LAST_COMPLETE" +%s 2>/dev/null || echo "$NOW_EPOCH")
        LC_H=$(awk -v a="$NOW_EPOCH" -v b="$LC_EPOCH" 'BEGIN{printf "%.0f", (a-b)/3600}')
        AGO=" — last complete ${LC_H}h ago"
    fi
    log "catching up — a complete off-site copy exists and is behind"
    log "$SUCCESS_MARKER [catchup] (${PCT}%, ${NEED_GB}GiB outstanding${ETA_TXT}${AGO})"
fi
exit 0
