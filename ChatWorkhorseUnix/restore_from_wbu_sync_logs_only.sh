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
set -e
WBU_HOST="workbenchunix"   # Tailscale name
WBU_USER="dhm"
rsync -aq --delete /home/dhm/.cache/cwhu-warm-sync/ "$WBU_USER@$WBU_HOST:/home/dhm/.cache/cwhu-warm-sync/"
