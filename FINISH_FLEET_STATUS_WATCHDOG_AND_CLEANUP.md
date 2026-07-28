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

## 4. Retire the OneDrive staging mess

(After the overnight/reboot soak test confirms nothing regressed.)

- Delete `push-snapshots-to-onedrive.sh`, `collect-fleet-configs-from-onedrive.sh`.
- Clean up references in `HOWTO_TWEAK_FLEET_TASKS.md`, `CLAUDE.md`,
  `Status/README_MOVE_AWAY_ONEDRIVE.md` (host table's "no repo" rows for
  surface3-gc/remotews/mathes-mac-mini are now stale).
- Delete leftover `C:\Misc\Bekah_*` files on remotews (superseded by repo
  copies) and equivalent leftovers on surface3-gc.

## 5. Loose ends found during this work

- `launchagents/MMM-PROMPT.md` is now obsolete (describes the old
  OneDrive-era, no-repo, heartbeat-only setup) — retire or rewrite now that
  mmm is fully repo-based with host-aware `install.sh`.
- Confirm the metrics server actually running on remotews is the repo copy,
  not a stale leftover at the old `c:\misc\python313\fleet_metrics_server.py`
  path.
