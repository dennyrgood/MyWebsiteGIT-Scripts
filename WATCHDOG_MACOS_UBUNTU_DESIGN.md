# Fleet watchdog for macOS and Ubuntu — design notes for future rollout

**STATUS (updated 2026-08-31): mostly superseded on macOS, still open on Ubuntu.**
The note below ("could be added to/extended in the health check monitor") is
what actually happened, on the Macs, on 2026-08-30 — most of this document
now describes work that is done. Read the status section immediately below
before acting on anything further down, or you will re-derive and re-build
detection that already exists. Sections that have been overtaken are marked
inline with a **DONE** / **NOT DONE** annotation.

Original framing: this captured everything learned building/deploying
`Status/FleetMetricsWatchdog.ps1` on all 6 Windows boxes (2026-07-22 through
2026-07-29), translated to what a Mac/Ubuntu equivalent would need, so a
future session could pick it up without re-deriving any of it.

Note, the ubuntu machines and the mac mini have a health check monitor that this could be added to/extended in.

## What is actually built, as of 2026-08-31

The Mac side was implemented not as a standalone watchdog but by extending
the existing per-box health monitors (`DennissMacBookAir/mb-health-monitor.sh`,
`Denniss2ndMacBookAir/mb2-health-monitor.sh`,
`MathesMacMini/mathes-mac-mini-health-monitor.sh`) on 2026-08-30 — exactly the
route the one-line note above proposed.

Coverage against the three failure classes this document defines:

| Failure class | macOS (mb, mb2, mmm) | Ubuntu (wbu, cwhu, nas) |
|---|---|---|
| 1. Alive but hung (no HTTP response) | **DONE** | **NOT DONE** |
| 2. Stale heartbeat (server up, writer dead) | **DONE** | **NOT DONE** |
| 3. Duplicate processes | **NOT DONE** (still unverified whether the class exists here) | **NOT DONE** (writer is cron one-shot; only the systemd server is a candidate) |

**macOS, class 1 (hang):** each monitor checks
`METRICS_SERVER_URL="http://127.0.0.1:9100/heartbeat_${HOST}.txt"` — the exact
URL this document proposed — with a missing-vs-down distinction: `pgrep` says
the process is running but curl doesn't answer = hung, which is precisely the
original travelbeast bug class that `KeepAlive`/`Restart=always` cannot catch.

**macOS, class 2 (stale heartbeat):** `HEARTBEAT_STALE_SECS=600`, this
document's proposed 10-minute threshold. The open caveat below ("check the
Mac/Linux writer's actual tick interval before reusing 10 min verbatim") is
**resolved**: the Mac writer ticks every 150s, so 600s is a deliberate 4x
margin, documented in the constant's own comment.

**macOS, class 3 (duplicates):** not built. `pgrep -f "$pattern"` is used only
as a boolean presence test — no PID count, no keep-newest-kill-the-rest. This
document already flagged the class as unverified outside Windows, so this is a
deferred decision, not an oversight. The "go look before you build" advice
under *What to check before writing any code* still stands unchanged.

**Ubuntu: none of it.** `WorkBenchUnix/wbu-health-monitor.sh`,
`ChatWorkhorseUnix/cwhu-health-monitor.sh` and `FleetNAS/nas-health-monitor.sh`
cover iowait, D-state, disk, mounts, Docker/Immich, UPS/NUT, SMART/RAID — and
contain no reference to port 9100, `fleet_metrics_server`, or heartbeat
freshness. This is the real remaining gap: per this document's own analysis,
systemd's `Restart=always` covers crash but not hang, so the Ubuntu metrics
server is the one genuine hang candidate on those boxes and it is currently
unwatched.

### Two ways the built thing differs in kind from what was designed here

1. **It detects and emails; it does not self-heal.** The Windows watchdog
   restarts the offending process. The Mac monitors send an alert containing a
   runbook (`launchctl kickstart -k gui/$(id -u)/com.dennis.<label>`) and leave
   the human in the loop. One deliberate exception exists where the ROI was
   proven by a real incident: `comfy-fleet-http` auto-kickstarts and only
   alerts if the kickstart itself fails to fix it. Whether the fleet-critical
   pair (heartbeat-writer, fleet-metrics-server) should follow that same
   auto-heal pattern is an open decision.
2. **The dashboard integration was never done.** Nothing on Mac writes a
   `watchdog_<host>.log`, and `Status/Web/ST/tiles.html`'s `WATCHDOG_HOSTS`
   array still lists only the 6 Windows boxes. So the tiles' watchdog badge
   remains Windows-only even though Mac detection now exists — the detection
   reaches you by email instead. See the `WATCHDOG_HOSTS` section below, which
   is still accurate and still outstanding.

   Related: this document's "daily alive ping, so silence isn't ambiguous
   between healthy and watchdog-died" convention *was* effectively achieved,
   by a different route. The nightly summaries check the monitor's own state
   file for staleness (`MONITOR_STALE_SECS=600` in
   `MathesMacMini/nightly_summary.sh`), which proves the monitor is alive on a
   daily cadence over a separate channel.

### Remaining work, ranked

1. Port the two macOS checks (9100 hang check + heartbeat freshness) into the
   three Ubuntu monitors — roughly 15 lines each, copied from the Mac version.
   Note the Ubuntu restart mechanism differs (`systemctl restart
   fleet_metrics_server`) and the writer needs no restart at all, being cron
   one-shot.
2. Decide explicitly whether heartbeat-writer / fleet-metrics-server should
   auto-heal on Mac the way `comfy-fleet-http` does, or stay alert-only.
3. Duplicate-process detection: still genuinely unverified outside Windows.
   Go look first (`ps aux | grep` over a day) before building anything.
4. Optional, lowest value: emit `watchdog_<host>.log` lines from the Mac
   monitors and add the Mac/Ubuntu hosts to `WATCHDOG_HOSTS` so the tiles badge
   covers the whole fleet rather than just Windows.

## Why this wasn't just "port the .ps1"

*(Analysis below remains correct and is what the 2026-08-30 macOS
implementation was built on. Classes 1 and 2 are now DONE on macOS, still
open on Ubuntu; class 3 is open everywhere.)*

The Windows watchdog exists because Task Scheduler has **no native
restart-on-hang** — a `BootTrigger`-only task that crashes or hangs just sits
dead until someone (or something) notices. macOS and Ubuntu are structurally
different here, so the problem this needs to solve is smaller on both:

- **launchd (`KeepAlive: true`)** already restarts a **crashed** process
  automatically. This is already configured for both Mac agents
  (`launchagents/com.dennis.heartbeat-writer.plist`,
  `com.dennis.fleet-metrics-server.plist`).
- **systemd (`Restart=always`)** already does the same for the metrics
  server — confirmed in `Status/fleet_metrics_server.service:29`. Ubuntu's
  heartbeat writer isn't even a persistent process to begin with (see
  below), so it has no crash-restart need at all.

So a Mac/Ubuntu watchdog's actual job is narrower than the Windows one: it
only needs to catch what the OS's native supervisor **can't** —
1. A process that's alive but **hung** (not crashed, so `KeepAlive`/`Restart=`
   never fires, but not answering HTTP either — the exact original bug that
   started this whole project, on travelbeast).
2. A **stale heartbeat** — the server responds fine, but the writer stopped
   actually updating data (dead writer, server still up).
3. **Duplicate processes** — turned out to be the single most common real
   bug found in the Windows rollout: 6 for 6 boxes had a genuine duplicate
   writer or server process sitting around undetected on first watchdog run.
   Whether this class of bug exists on Mac/Ubuntu at all is unverified —
   worth checking before assuming it's needed there too.

## Current per-OS setup (as of 2026-07-29)

| | Writer | Metrics server | Supervisor |
|---|---|---|---|
| **macOS** (mb, mb2, mmm) | `Status/onedrive_heartbeat_writer_all_macs.py`, persistent loop | `Status/fleet_metrics_server.py` | LaunchAgents via `launchagents/install.sh`, `KeepAlive: true` on both |
| **Ubuntu** (workbenchunix, chatworkhorseunix) | `Status/run_heartbeat.sh <hostname>`, **one-shot**, cron every 2 min | `Status/fleet_metrics_server.py` | writer: cron (no supervisor needed, it's not persistent); server: systemd unit `fleet_metrics_server.service`, `Restart=always` |

Key implication: **duplicate-process risk on Ubuntu is essentially zero for
the writer** — cron just runs `run_heartbeat.sh` to completion every 2
minutes and it exits, there's no long-running process to duplicate. Only the
systemd-managed server is a candidate for the same "actually hung, not
crashed" class of bug the Windows boxes had. mb/mb2/mmm's writer *is*
persistent (a loop, like Windows' `onedrive_heartbeat_writer_server.ps1`), so
duplicate-writer risk is a real open question there, same as it was on
Windows before testing.

## What to check before writing any code

1. **Has this actually happened on Mac/Ubuntu?** All 6 Windows duplicate/hang
   incidents were *discovered*, not assumed — go check
   `~/fleet_monitor/heartbeat_<host>.txt`'s mtime staleness history, or just
   `ps aux | grep -i heartbeat` / `ps aux | grep fleet_metrics_server` on
   each box a few times over a day, before building a whole watchdog for a
   problem that might not exist here. The Windows rollout's near-100% hit
   rate was suspicious in itself and worth understanding (why were so many
   duplicates present? something about how these tasks get relaunched on
   reboot/logon was probably the real root cause — never actually
   root-caused, just detected-and-cleaned-up every time).
2. **Does `KeepAlive`/`Restart=always` already cover "hung"?** Neither
   actually does — both only fire on process *exit* (crash), not on a
   process that's alive but not responding on its port. So the "genuine
   hang" class (the original travelbeast bug) is NOT covered by the existing
   Mac/Ubuntu supervisors and would need this watchdog regardless.

## Design translation, if built

### Health check (same on both OSes, same as Windows)

**DONE on macOS** (2026-08-30, inside the per-box health monitors, same URL
and same 10-min threshold — see the status section above). **Still open on
Ubuntu**, and this is the highest-value remaining item.

```bash
curl -sf --max-time 5 "http://127.0.0.1:9100/heartbeat_${HOST}.txt"
```
- 200 + fresh timestamp inside = healthy.
- No response / timeout = server down or hung → restart server.
- 200 but timestamp stale (>10 min, matching the Windows threshold — writer
  ticks every ~150s there; check the Mac/Linux writer's actual tick interval
  before reusing 10 min verbatim) → writer dead/stuck → restart writer.

### Duplicate-process detection (macOS + persistent Linux daemons only)

**NOT DONE anywhere outside Windows.** Deliberately deferred — the class is
still unverified on Mac/Ubuntu. Verify before building.

```bash
pgrep -fa "onedrive_heartbeat_writer_all_macs.py"   # or the relevant script name
pgrep -fa "fleet_metrics_server.py"
```
Same principle as Windows: if more than one PID matches, keep the newest
(`ps -o lstart= -p <pid>` for start time, or `ps -o etime=`) and `kill` the
rest. **Keep the match patterns mutually exclusive per role** — the Windows
version had a real bug (documented in `Status/FleetMetricsWatchdog.ps1`'s
header comments) where a shared/blanket pattern killed the server while
trying to fix the writer. Not applicable to Ubuntu's writer since it's not
persistent.

### Restart mechanism

**NOT DONE for the fleet-critical pair** — the Mac monitors emit these
commands as runbook text in the alert email rather than executing them.
`comfy-fleet-http` is the one service that does auto-`kickstart`. See "differs
in kind" above.

- **macOS:** `launchctl kickstart -k gui/$(id -u)/com.dennis.<label>` — note
  the exit-status caveat already documented in `launchagents/README.md`
  (`-k` sends SIGTERM, so status briefly shows `-15` even on success; use
  `bootout` + `bootstrap` instead if you need a clean `0` immediately).
- **Ubuntu:** `sudo systemctl restart fleet_metrics_server` (writer needs no
  restart mechanism, cron just runs it again in ≤2 min naturally).

### Scheduling the watchdog itself

**Superseded on macOS.** No separate `com.dennis.fleet-watchdog.plist` was
created; the checks ride the existing 5-minute health-monitor LaunchAgents
(`launchagents/com.dennis.mb-health-monitor.plist` and siblings), which already
run at the cadence this section specifies. Ubuntu equivalent still open — same
logic applies, extend the existing 5-minute cron health monitor rather than
adding a systemd timer.

- **macOS:** a new LaunchAgent, `com.dennis.fleet-watchdog.plist`, using
  `StartInterval: 300` (NOT `KeepAlive` — this should run, finish, exit every
  5 min, not stay resident). Needs its own plist in `launchagents/` and an
  entry in `install.sh`'s host-aware `case` statement.
- **Ubuntu:** a systemd timer (`fleet-watchdog.timer` +
  `fleet-watchdog.service`, `OnUnitActiveSec=5min`), or just a cron entry —
  simpler given the writer's already cron-based there.

### Logging — reuse the exact same convention, unchanged

**NOT DONE.** No `watchdog_<host>.log` is written on Mac or Ubuntu; detection
reaches you by email instead of via the tiles badge. Everything below is still
accurate if/when you want the dashboard to cover non-Windows hosts.

Write to `~/fleet_monitor/watchdog_<host>.log` (Mac) or the Ubuntu
equivalent's `fleet_monitor` dir, in the **same line format** the Windows
script uses:
```
<ISO8601 timestamp> <message>
```
This matters a lot: `fleet_metrics_server.py`'s `_ALLOWED` regex already
permits `watchdog_*.log` (OS-agnostic — same Python file runs everywhere),
and the **entire dashboard side is already built and OS-agnostic**:
`fleet_api.py`'s `/api/watchdog/<host>` endpoint and `tiles.html`'s
`parseWatchdogLog()` just look for lines starting with a timestamp and check
for `watchdog alive, checking` as the "routine, not an issue" marker — none
of that cares what OS wrote the log. **No backend or dashboard changes
needed** to onboard a Mac/Ubuntu watchdog once it exists.

The "alive" daily ping convention (once per calendar day, so silence isn't
ambiguous between "healthy" and "watchdog itself died") should carry over
unchanged too — same reasoning applies on any OS.

### The one deploy step that IS required: `WATCHDOG_HOSTS`

`Status/Web/ST/tiles.html` has a hardcoded array:
```js
const WATCHDOG_HOSTS = ['travelbeast', 'remotews', 'chatworkhorse', 'amsterdamdesktop', 'imagebeast', 'surface3-gc'];
```
Add the new `tailscale_name` values here once a box actually has the
watchdog running (`denniss-macbook-air`, `denniss-2nd-macbook-air`,
`mathes-mac-mini`, `workbenchunix`, `chatworkhorseunix`) — this is the single
required frontend change, nothing else.

## Rollout checklist (mirrors what worked for Windows)

*(Written for a standalone watchdog. For the Ubuntu port — the actual
remaining work — steps 1-3 collapse into "add the checks to the existing
health monitor," since it is already deployed and already scheduled. Steps 4
and 6 apply only if you also do the optional logging/dashboard item.)*

1. Write the watchdog script (bash, probably — no reason for Python here).
2. Deploy to one box first, run it **manually** to confirm behavior before
   scheduling it (the Windows rollout caught the cross-role-kill bug and the
   VBS-wrapper-discovery gap this way, before they could bite silently).
3. Schedule it (LaunchAgent / systemd timer), confirm "Run with highest
   privileges" has no macOS/Linux equivalent problem — permissions were a
   real gotcha on Windows (`Get-CimInstance`/`Get-ScheduledTask` silently
   return incomplete data unless elevated); check whether `pgrep`/`ps` need
   any special entitlement under launchd's sandboxed environment (per
   `launchagents/README.md`'s TCC notes — Full Disk Access bit the heartbeat
   writer before for a different reason, worth checking if it affects this
   too).
4. Verify the log write, verify the dashboard picks it up automatically
   (it will, once `WATCHDOG_HOSTS` is updated — no other change needed).
5. Capture the new LaunchAgent plist / systemd unit into `fleet-configs` via
   that box's existing snapshot script.
6. Deliberately trigger a test event (kill the process, or a fake log line
   per the Windows testing pattern) to confirm the dashboard badge and
   fleet-wide indicator actually reflect it before trusting it unattended.
