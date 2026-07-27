#!/bin/bash
# Created: 2026-06-27 10:42 UTC — warm-sync job: ChatWorkhorseUnix pulls from WorkBenchUnix
# Edited: 2026-06-27 — fixed completion-marker check: "cluster dump complete", not "dump complete"
# Edited: 2026-06-30 UTC — switched source from WBU's backup-c to WBU's win-d (live data).
# Trigger: backup-c's drive was found failing (SMART extended self-test failure, growing
# pending sectors — see Immich-Backup-Strategy-Present-and-Future.md, "Drive Health
# Incident"). Images now read from win-d/immich/images/ directly (the live source, healthy,
# no dated-folder wrapper needed). DB dump now reads from win-d/immich/postgres-dumps-latest/,
# produced by the new standalone dump_immich_db_for_cwhu.sh (5:30am), independent of any
# backup drive's health. No other logic changed — format, completion marker, and restore
# steps are unchanged since the dump is still pg_dumpall, uncompressed, same as before.
# Runs ON ChatWorkhorseUnix, triggered by CWHU's own cron (6am daily). Destructive by
# design — see runbook v6.6.
# 2026-06-30 UTC: WBU renamed its win-d mount to immich-data; updated remote-facing
# references (ssh/rsync targets) below to match.
# 2026-06-30 UTC: CWHU also renamed its own local win-d mount to immich-data (separate
# mount, separate UUID, on /dev/sdb1 — a VM vdi). LIVE_IMAGES, DUMP_STAGING, and the
# local Postgres wipe path below updated to match. Both machines now use immich-data
# consistently; no win-d mounts remain on either host.
# 2026-07-14 15:30 UTC: Save psql restore log to ~/.cache/cwhu-warm-sync/ with datestamp (alongside sync_log/sync_errors), replacing ephemeral /tmp path.
# 2026-07-22 UTC: Root-caused a ~2hr Immich outage — WBU had a transient SSH hang, and
# the bare `ssh` call below (no ConnectTimeout/keepalive) sat there indefinitely, never
# reaching the "no dump found" guard, so the stack stayed torn down with no recovery and
# no error surfaced. Added SSH_OPTS (applied to the ssh call and every rsync's transport,
# since rsync can hang mid-transfer the same way) so any future connectivity blip to WBU
# fails within ~25s instead of hanging forever, and switched the LATEST_DUMP assignment to
# explicit error-checking so set -e can't skip past the recovery block on failure.
# 2026-07-23 UTC: Second outage, different step — WBU was itself in I/O distress (RCU
# stalls), which corrupted the SSH transport mid-image-rsync ("message authentication
# code incorrect"). That step had no recovery block (only the dump-list/verify steps
# did), so the stack stayed down with nothing to bring it back up. Fixed two ways:
#   1. Added a preflight WBU health check (iowait + D-state, same signal/thresholds
#      wbu-health-monitor.sh alerts on) before anything destructive happens. If WBU is
#      unreachable or already struggling, skip the run entirely and never touch CWHU's
#      running stack.
#   2. Replaced the per-step manual "docker compose up -d; exit 1" recovery blocks with
#      a single trap on EXIT, gated by STACK_DOWN. That way *any* failure after the
#      stack comes down — not just the two steps someone remembered to guard — brings
#      it back up.
# 2026-07-28 UTC: Third outage — the wipe-then-restore left Immich showing the
# first-run "create admin user" screen. The pg_isready readiness check below matched
# the postgres image's short-lived TEMPORARY init server (Unix socket only) instead of
# the real one, so the restore got piped into a connection that was killed seconds
# later when the temp server shut down, leaving Postgres empty. Fixed by forcing
# pg_isready onto TCP (-h 127.0.0.1), which the temp server never listens on. See the
# comment at the pg_isready line for the full mechanism. Recovered manually by
# restoring the still-staged dump into the live container (no wipe needed) after
# DROP DATABASE immich to undo the schema Immich had auto-migrated onto the empty DB.
set -e
WBU_HOST="workbenchunix"   # Tailscale name
WBU_USER="dhm"
LIVE_IMAGES="/mnt/immich-data/immich/images"
DUMP_STAGING="/mnt/immich-data/immich/restore-dump"
DUMP_STAGING_FILE="$DUMP_STAGING/latest-sync-dump.sql"
# Fail fast rather than hang forever on a wedged/unreachable WBU connection —
# ConnectTimeout bounds the initial connect, ServerAlive* detects a session that
# connected but then went silent (the failure mode that caused the 2026-07-22 outage).
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
# Same thresholds wbu-health-monitor.sh alerts on for itself (iowait > 20%, gated on
# D-state also present — a healthy nightly backup can sit in D-state without high
# iowait, so require both, matching that monitor's 2026-07-21 anti-false-positive fix).
IOWAIT_THRESHOLD=20
cd /home/dhm/immich-app

# STACK_DOWN tracks whether CWHU's stack is currently torn down. Whatever kills the
# script from here on (this step or any later one), the trap brings it back up —
# no per-step recovery block to forget.
STACK_DOWN=0
recover_stack() {
    if [ "$STACK_DOWN" = "1" ]; then
        echo "Recovering: bringing CWHU's stack back up after failure..."
        docker compose up -d
        STACK_DOWN=0
    fi
}
trap recover_stack EXIT

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting warm-sync from WBU's immich-data."

# 0. Preflight: is WBU even up, and not itself mid-meltdown? Checked *before*
#    touching CWHU's live stack, so a bad night on WBU costs nothing here beyond
#    skipping tonight's sync — same data, same running stack, try again tomorrow.
echo "Checking WBU is reachable and not under I/O distress..."
if ! WBU_CHECK=$(ssh $SSH_OPTS "$WBU_USER@$WBU_HOST" '
    read -r _ a1 b1 c1 i1 w1 _ < /proc/stat
    sleep 1
    read -r _ a2 b2 c2 i2 w2 _ < /proc/stat
    dt=$(( (a2+b2+c2+i2+w2) - (a1+b1+c1+i1+w1) ))
    diowait=$((w2 - w1))
    iowait_pct=$(( dt > 0 ? diowait * 100 / dt : 0 ))
    dstate=$(ps -eo stat= | grep -c "^D")
    echo "$iowait_pct $dstate"
'); then
    echo "WBU unreachable or unresponsive — skipping tonight's sync. CWHU's stack is untouched."
    exit 0
fi
read -r WBU_IOWAIT WBU_DSTATE <<< "$WBU_CHECK"
echo "WBU: iowait=${WBU_IOWAIT}% D-state-procs=${WBU_DSTATE}"
if [ "$WBU_IOWAIT" -gt "$IOWAIT_THRESHOLD" ] && [ "$WBU_DSTATE" -gt 0 ]; then
    echo "WBU looks like it's in I/O distress — skipping tonight's sync. CWHU's stack is untouched."
    exit 0
fi

# 1. Stop CWHU's Immich stack first — avoids any race between the live
#    container and the incremental image rsync that's about to run.
echo "Stopping CWHU's Immich stack..."
docker compose down
STACK_DOWN=1
# 2. Pull the latest Postgres dump from WBU's immich-data into local staging.
#    Cheap and small enough to stage separately before touching anything live.
mkdir -p "$DUMP_STAGING"
# Explicit if-check, not `LATEST_DUMP=$(...)` on its own — under `set -e`, a failed
# assignment like that exits the script immediately, before this recovery block ever
# runs. That's what actually happened on 2026-07-22: the ssh call failed(/hung), the
# script died silently, and the intended "bring the stack back up" never fired.
if ! LATEST_DUMP=$(ssh $SSH_OPTS "$WBU_USER@$WBU_HOST" "ls -1t /mnt/immich-data/immich/postgres-dumps-latest/immich-dump_*.sql | head -1"); then
    echo "ERROR: could not reach WBU or list dump files. Aborting before touching anything live."
    exit 1
fi
if [ -z "$LATEST_DUMP" ]; then
    echo "ERROR: could not find a dump file on WBU's immich-data. Aborting before touching anything live."
    exit 1
fi
echo "Pulling dump: $LATEST_DUMP"
rsync -avh --checksum -e "ssh $SSH_OPTS" "$WBU_USER@$WBU_HOST:$LATEST_DUMP" "$DUMP_STAGING_FILE"
# 3. Verify the staged dump looks complete before doing anything destructive with it.
#    Minimum bar: file exists, non-empty, and ends with the expected pg_dumpall
#    closing marker rather than being truncated mid-transfer.
if [ ! -s "$DUMP_STAGING_FILE" ]; then
    echo "ERROR: staged dump is missing or empty. Aborting before touching anything live."
    exit 1
fi
if ! tail -5 "$DUMP_STAGING_FILE" | grep -q "PostgreSQL database cluster dump complete"; then
    echo "ERROR: staged dump does not end with the expected pg_dumpall completion marker — possible truncation. Aborting before touching anything live."
    exit 1
fi
echo "Staged dump verified complete."
# 4. Incremental image rsync, directly into the live path — this is where
#    "only changes" actually happens, since rsync compares against what's
#    already there. Stack is down, so nothing's reading/writing concurrently.
#    --delete matches immich-data's own behavior: if it's gone on WBU, it's gone here too.
echo "Re-checking UPLOAD_LOCATION ownership before rsync..."
sudo chown -R 1000:1000 "$LIVE_IMAGES"
echo "Syncing images from WBU's immich-data (live)..."
rsync -avh --delete -e "ssh $SSH_OPTS" "$WBU_USER@$WBU_HOST:/mnt/immich-data/immich/images/" "$LIVE_IMAGES/"
# 5. Wipe and restore Postgres from the staged, verified dump.
#    find -mindepth 1 -delete, not rm -rf */ — see runbook v5/v6 for why the
#    glob version silently no-ops under sudo.
echo "Wiping CWHU's Postgres data directory..."
sudo find /mnt/immich-data/immich/postgres/ -mindepth 1 -delete
echo "Bringing up Postgres only, to restore into it..."
docker compose up -d database
# -h 127.0.0.1 forces a TCP check, not the default Unix socket. On a wiped/fresh
# data dir, the postgres image's entrypoint runs initdb, then briefly starts a
# TEMPORARY server (Unix socket only, for init scripts), then shuts it down and
# starts the real server (which listens on both). A bare `pg_isready -U postgres`
# can match that temp server and report ready before the real one exists — the
# script then pipes the restore into a session that gets killed seconds later
# ("FATAL: terminating connection due to administrator command") when the temp
# server shuts down, leaving Postgres empty and Immich looking like a fresh
# install. The temp server never listens on TCP, so forcing TCP here waits for
# the real server instead. Root-caused 2026-07-28 after exactly this happened.
until docker exec immich_postgres pg_isready -h 127.0.0.1 -U postgres; do sleep 2; done
echo "Restoring dump..."
RESTORE_LOG="$HOME/.cache/cwhu-warm-sync/restore_log_$(date -u +%Y%m%d_%H%M%S).txt"
cat "$DUMP_STAGING_FILE" | docker exec -i immich_postgres psql -U postgres > "$RESTORE_LOG" 2>&1 || true
if grep -qi error "$RESTORE_LOG"; then
    echo "WARNING: possible errors during restore — check $RESTORE_LOG on CWHU."
    echo "(Note: 'role already exists' / 'database already exists' lines are expected and harmless.)"
fi
# 6. Bring the full stack back up.
echo "Bringing up full stack..."
docker compose up -d
STACK_DOWN=0
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Warm-sync complete."
rsync -aq --delete -e "ssh $SSH_OPTS" /home/dhm/.cache/cwhu-warm-sync/ "$WBU_USER@$WBU_HOST:/home/dhm/.cache/cwhu-warm-sync/"
