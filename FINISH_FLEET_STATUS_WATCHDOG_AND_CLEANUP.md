# Fleet metrics/watchdog cleanup — full rollout + OneDrive retirement

Written 2026-07-23. Picks up after `FleetMetricsWatchdog.ps1` was built and
live-tested on remotews (found + fixed: cross-task-kill bug, missing
powershell.exe in process filter, duplicate-process pileup, wrong task name
"Fleet Metrics Server" with a space). All three former no-repo boxes
(surface3-gc, remotews, mmm) have since been converted to repo checkouts.

## 1. Watchdog production rollout (remaining boxes, AND remotews itself)

- **IMPORTANT (found 2026-07-27):** `FleetMetricsWatchdog.ps1` was only ever
  run manually on remotews during testing (`.\FleetMetricsWatchdog.ps1`) — it
  was never actually registered as its own recurring Task Scheduler job
  there. `schtasks /Query /TN "FleetMetricsWatchdog"` on remotews is expected
  to come back "cannot find." The 5 days of silence in
  `watchdog_remotews.log` after 7/22 wasn't proof of stability — it was
  proof nothing was running it. Also found: the Heartbeat Writer process is
  running as an orphan, not managed by the actual "Heartbeat Writer" task,
  consistent with nothing having checked/restarted it since testing ended.
  **remotews needs the recurring task created just as much as every other
  box below** — don't treat it as "done."
- Deploy the script + recurring task to travelbeast (the original genuine-hang
  case — never actually tested with this script at all, not even manually),
  plus chatworkhorse, amsterdamdesktop, imagebeast, surface3-gc, and remotews
  (per above).
- Per box: Task Scheduler task, recurring trigger every 5 min indefinitely,
  **"Run with highest privileges" checked** (required — CommandLine comes
  back blank for other-session processes otherwise, which caused the
  false-negative duplicate-writer bug on remotews), `MultipleInstancesPolicy
  = IgnoreNew`.
- Confirm `$staleThresholdMinutes` is at the production value (10) on every
  deployed copy, not the `1` used for remotews testing.
- ~~Confirm each box's actual task names match~~ **RESOLVED 2026-07-27** (in
  two passes — first pass was incomplete, see below):
  confirmed the writer task's display name drifts across the fleet —
  "Heartbeat Writer" (travelbeast, ImageBeast), "HeartbeatWriter" (no space,
  AmsterdamDesktop), "Hearbeat Writer OneDrive" (typo + stale suffix,
  ChatWorkHorse), "Heartbeat Write OneDrive" (typo, Surface3GC). "Fleet
  Metrics Server" was consistent across all 5. Fixed by rewriting the script
  to discover both task names by their action (script path) instead of
  hardcoding display names — no per-box config needed.
- **Gap found in the first pass:** discovery only checked each task's own
  `Execute`/`Arguments`. But travelbeast/ImageBeast/ChatWorkHorse/
  AmsterdamDesktop all launch via a generic `wscript.exe run_hidden*.vbs`
  wrapper whose action never mentions the real script at all — only the
  `.vbs` file's *contents* do (`heartbeat_writer` etc. lives inside the VBS,
  not in the task action). So discovery silently failed on every VBS-wrapped
  box and fell back to the hardcoded default name — which happened to be
  *correct* on travelbeast by coincidence (its actual name is literally
  "Heartbeat Writer"), masking the bug during that test, but would have been
  *wrong* on ChatWorkHorse/AmsterdamDesktop, the exact boxes the fix was
  for. Second pass: discovery now also reads the referenced `.vbs` file's
  contents when a task's action points at one.
- **Validated on travelbeast 2026-07-27** on first real run: caught 2 genuine
  duplicate Heartbeat Writer processes and killed the stale one, confirming
  the whole mechanism works on the box where the original hang happened, not
  just remotews.
- **DONE, ALL 6 WINDOWS BOXES (2026-07-27/28):** travelbeast, remotews,
  chatworkhorse, amsterdamdesktop, imagebeast, surface3-gc. Script deployed,
  recurring task created, XML captured into fleet-configs on every one.
  **6 for 6 caught a genuine duplicate process on the very first run**
  (5x duplicate writer, 1x duplicate server on surface3-gc — an orphaned
  process still running the old bespoke `C:\Misc\fleet_metrics_server.py`
  even though the task itself had been repointed to the repo copy). This
  was clearly a real, widespread problem across the fleet, not a one-off —
  worth a root-cause look later at why boxes end up with duplicate
  processes after reboot/relaunch in the first place, though the watchdog
  now cleans it up regardless.
- Also converted `Surface3GC/surface3-gc-snapshot-fleet-configs.ps1` from
  the old OneDrive-staging pattern to repo-based while deploying there
  (folds into item 3 below — that item is now only mmm's snapshot script).
- **Not Windows / not directly applicable (5):** mb, mb2, mmm (launchd,
  `KeepAlive` already restarts a crashed process, but wouldn't catch a
  hung-but-alive process or a stale heartbeat) and workbenchunix/
  chatworkhorseunix (systemd/cron). These would need an equivalent but
  separately-built check (shell + cron/systemd timer), not a port of the
  `.ps1`. Open decision: is launchd's/systemd's native restart-on-crash good
  enough there, or do these 5 want the same duplicate/stale-heartbeat
  protection too?

## 2. ST tiles dashboard integration — DONE 2026-07-28

Ended up as two pieces, not one — design evolved during the session:

- **Per-tile badge** (`⚠N`, hidden unless there's an issue in the last 24h) —
  matches the existing transitions-badge pattern, avoids per-tile clutter.
  Click the tile → modal has a new WATCHDOG LOG section (raw tail).
- **Fleet-wide indicator** (`🛡 WATCHDOG OK` / `⚠ WATCHDOG: N issues, M
  stale`) next to the FLEET TRANSITIONS button — added because per-tile-only
  badges are ambiguous: no badge could mean "healthy" OR "watchdog died and
  stopped reporting silently." This single persistent button distinguishes
  the two explicitly and is always visible without per-tile clutter. Click
  opens a modal listing all `WATCHDOG_HOSTS` individually.
- Backend: new `/api/watchdog/<host>` endpoint in `fleet_api.py`, mirroring
  the existing `/api/history/<host>` live-fetch-over-9100 pattern exactly —
  no new service, deploys only to the 2 boxes already running `fleet_api.py`.
- **Prerequisite discovered along the way:** the `_ALLOWED` regex fix in
  `fleet_metrics_server.py` (needed to serve `watchdog_*.log` at all) had
  been in the repo since 7/22, but most boxes' *running* server process
  predated it (Python doesn't hot-reload) — `git pull` alone wasn't enough,
  every box's `Fleet Metrics Server` task needed an explicit bounce too.
- **TODO when more boxes get the watchdog:** update the hardcoded
  `WATCHDOG_HOSTS` array in `tiles.html` to include them.
- **Same hot-reload gotcha bit the `/api/watchdog` deploy too:** restarting
  the wrong/no task after `git pull` on amsterdamdesktop left `fleet_api.py`
  serving a literal 404 for the new route for a while — confirmed via
  `Get-EventLog`-style direct testing (`https://fleet.ldmathes.cc/api/watchdog/<host>`
  in a browser) rather than trusting that a `git pull` + "I restarted it"
  meant the right process actually reloaded. Once the correct task was
  bounced, it worked immediately on both the primary and backup
  (`fleet-bkp.ldmathes.cc`) feeds.
- **Live-validated 2026-07-28/29:** the fleet-wide indicator correctly
  surfaced a real, previously-invisible event — imagebeast's Fleet Metrics
  Server went down for ~15 minutes (21:57-22:12) during a Windows Update
  install (confirmed via `Get-EventLog`: WU install completed 22:04, with a
  burst of service-restart/DCOM/config-change events either side), needed 3
  failed watchdog cycles before recovering on the 4th. This would have
  silently taken imagebeast off the dashboard's data feed with nothing
  catching it before this indicator existed - good real-world proof the
  whole project (watchdog + dashboard surfacing) works end to end, not a
  code problem to fix.
- **Known cosmetic quirk, not fixed:** the issue **count** in both the badge
  and the modal is a count of matching *log lines*, not *incidents* - a
  single duplicate-kill event produces 2 lines ("found duplicate" + "killing
  duplicate"), and a single flaky-restart outage can produce 20+ lines (one
  "not responding" + 2 lines per failed attempt x 3 attempts x however many
  5-min cycles it took, e.g. imagebeast's one 15-min WU-outage showed as "27
  issues"). Correct at reflecting "something happened," misleading at
  suggesting *how many* somethings. Low priority - grouping consecutive
  lines into incidents would fix it if it's ever confusing in practice.

## 3. Snapshot scripts — finish repo-based conversion — ALL DONE 2026-07-28

- ~~Surface3GC~~ **DONE 2026-07-28.**
- ~~MathesMacMini~~ **DONE 2026-07-28** — `launchctl`/plist-list capture
  pattern, matching `Denniss2ndMacBookAir`'s snapshot (not the Windows
  Task Scheduler XML pattern, since mmm is a Mac).
- ~~Add `watchdog` to the task-discovery regex in all repo-based Windows
  snapshot scripts~~ **DONE 2026-07-27** — travelbeast, ImageBeast,
  ChatWorkHorse, AmsterdamDesktop, Surface3GC all fixed (only RemoteWS had
  it originally).
- **Every box that needed a repo-based snapshot conversion is now done.**
  What's left before OneDrive staging can be deleted (see item 4) is purely
  confirming no box still references it, not more script work.

## 4. Retire the OneDrive staging mess — DONE 2026-07-29

- ~~Delete `push-snapshots-to-onedrive.sh`, `collect-fleet-configs-from-onedrive.sh`~~
  **DONE** — user deleted both directly.
- ~~Clean up references in `HOWTO_TWEAK_FLEET_TASKS.md`, `CLAUDE.md`,
  `Status/README_MOVE_AWAY_ONEDRIVE.md`~~ **DONE** — removed the "no-repo box"
  branches from `HOWTO_TWEAK_FLEET_TASKS.md`'s short-version steps and
  "things that bite you" list, and replaced `README_MOVE_AWAY_ONEDRIVE.md`'s
  OneDrive-staging section with a one-liner noting all boxes are repo boxes
  now. `CLAUDE.md` needed no edit — it already said the workaround "is
  retired." Left the mentions in this file (changelog) and the two
  ex-no-repo boxes' snapshot script header comments alone — those are
  accurate past-tense history, not instructions to do anything wrong.
- ~~Delete leftover `C:\Misc\Bekah_*`/`GC_*` files on remotews/surface3-gc~~
  **DONE 2026-07-29** — confirmed via Task Scheduler that all 6 Windows
  boxes' tasks point at repo paths (not `C:\Misc`), then deleted the dead
  `fleet_metrics_server.py`, `Bekah_*`/`GC_*` writer scripts, and stray
  leftover files on both boxes. `Python313\` kept on both (still the
  interpreter in use).

## 5. Loose ends found during this work — DONE 2026-07-29

- ~~Confirm the metrics server actually running on remotews is the repo
  copy~~ **DONE** — verified via Task Scheduler screenshot, task points at
  the repo path.
- `launchagents/MMM-PROMPT.md` is still sitting there, technically obsolete
  (describes the old OneDrive-era, no-repo, heartbeat-only setup) but
  harmless — nothing reads or runs it anymore now that mmm is fully
  repo-based with host-aware `install.sh`. Not retired/rewritten, just
  no longer accurate; low priority to actually clean up.
