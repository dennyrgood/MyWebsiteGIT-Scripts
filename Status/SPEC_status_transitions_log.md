# Spec: status transition log + sparkline window label

Written 2026-07-22, updated 2026-07-22 with a second, stronger motivating incident.

**STATUS (2026-07-22): Part B implemented, deployed to both checker hosts, and verified
live** — `Status/reporters/transitions_reporter.py` (new), `Status/engine.py` (hooked in),
`Status/fleet_api.py` (`/api/transitions` endpoint), and `Status/Web/ST/tiles.html` (per-tile
"⚡N" flap badge, per-host modal "RECENT TRANSITIONS" section, and a persistent "FLEET
TRANSITIONS" link/modal on the alert-strip line — all beyond what this spec originally
scoped for the UI follow-up). Commits: `12afae1`, `7959837`, `b0afc08`.

**Part A (sparkline time window label) was deemed unnecessary and will NOT be
implemented.** Left below for reference only.

## Background / why this came up

While debugging false-negative "down" flickers for TravelBeast's ComfyUI/Ollama checks
(fixed in commits `12f5fbc` — TCP-connect fallback + retry on Layer 1 host reachability —
and `de1bc8a` — retry-once on Layer 2 HTTP checks, both in `Status/checkers/`), it became
clear there's no way to answer "how often does X actually flap" or "when did Y last go
down" without manually tailing raw poll-summary log lines and guessing which host/service
caused a count to drop. That's the gap this spec addresses.

Separately, the existing RAM/CPU/VRAM/GPU sparklines in `Web/ST/tiles.html` don't label
what time window they cover — this spec includes a small fix for that too since it's the
same "I can't tell what I'm looking at" problem in miniature.

**Later the same day, a real (not hypothetical) incident made the case much stronger** —
see "Case study" below. Diagnosing a ~2hr Immich outage on `chatworkhorseunix` required
manually cross-referencing five separate, differently-shaped data sources by hand (two
checker app logs, `server_status_all.json`, a health-monitor's own alert emails, and the
failing script's own log files) because nothing anywhere records "service X changed from
up to down at time Y, here's why." A transition log would have collapsed most of that
into one query.

## Case study: the 2026-07-22 CWHU/Immich outage (concrete evidence for Part B)

Same day this spec was first written, a real outage happened that's a near-perfect
illustration of the exact gap Part B addresses. Summarized here so a future
implementer has a concrete "here's what this would have made easy" reference, not
just an abstract goal.

**What happened**: `ChatWorkhorseUnix/restore_from_wbu.sh` (a nightly cron job, `0 4 * * *`
on `chatworkhorseunix`, tears down the local Immich stack, pulls a fresh Postgres dump +
images from WorkBenchUnix, restores, brings the stack back up) hit a transient SSH hang
connecting to WBU. Because the script had `set -e` and a bare `LATEST_DUMP=$(ssh ...)`
assignment (no `ConnectTimeout`), the hang meant the script died silently right after
tearing the stack down — never reaching its own "bring it back up" recovery logic. Immich
stayed down for **~2 hours** before it was noticed and manually restarted
(`docker compose up -d`). Root-caused and fixed same day: commit `a7cdd5c` (the script
itself), then `0156b93` and `c87e8c4` (an audit found + fixed 6 more scripts across CWHU
and WBU with the identical bare-ssh-no-timeout pattern, and retired 3 superseded/orphaned
scripts). None of that fix work is part of this spec — it's mentioned here only because
diagnosing it is what proved out the need for Part B.

**What it actually took to diagnose**, all done by hand, cross-referencing five different
sources with no shared schema or query:
1. `checker_amsterdamdeskto_app.log` (note the truncated hostname) — raw poll-summary
   lines like `machines 11/11 | services 26/27`, no indication *which* service.
2. `server_status_all.json` — current snapshot only, had to grep for `status != "up"` to
   find `chatworkhorseunix / Immich: connection refused` at the moment of inspection —
   tells you *what's down now*, nothing about *when it started* or *history*.
3. A forwarded nightly health-summary **email** from a completely separate monitor
   (`WorkBenchUnix/wbu-health-monitor.sh`, root cron, alerts by email) — this is what
   actually had the timeline (`HEALTH ALERT -- 04:05, 04:40, 05:15, 05:40, 06:15` — an
   independent monitor on a different machine, escalating over the same window).
4. `journalctl` on `chatworkhorseunix`, twice — first queried the wrong window entirely
   (confused the script's UTC log timestamp with the box's local-time cron trigger,
   CEST/UTC+2), then re-queried correctly to confirm the cron actually fired and the
   system itself never rebooted/froze.
5. The failing script's own `sync_log_*.txt` / `sync_errors_*.txt` output files, compared
   line-by-line against the previous night's successful run to see exactly where it
   stopped.

**What Part B would have made trivial**: a single `status_transitions.jsonl` line —
`{"ts": "...04:0Xish", "scope": "service", "host": "chatworkhorseunix", "service": "Immich", "from": "up", "to": "down", "detail": "connection refused"}`
— would have given the exact transition moment and cause in one line, from one file,
without needing the email, the second `journalctl` host, or manually diffing log files
from two different nights. It would NOT have replaced steps 4/5 above (figuring out *why*
the underlying script hung is a separate investigation the transition log doesn't help
with) — but it would have collapsed "when did this start and what was down" from ~20
minutes of cross-referencing to one grep.

## Part A — sparkline time window label (NOT implemented, deemed unnecessary)

**What the sparkline data actually is**, confirmed by reading the writers:
- `Status/heartbeat_writer_linux.py` (Linux, run via cron) and
  `Status/onedrive_heartbeat_writer_server.ps1` (Windows) each append one entry to
  `metrics_history_{host}.json` roughly every **30 seconds**
  (`onedrive_heartbeat_writer_server.ps1` line ~205: `$tickInterval = 30`).
- Both trim the file to the **last 120 entries**
  (`HISTORY_MAX_LINES = 120` in the Linux writer; same constant name/value in the PS1).
- 120 × 30s = **60 minutes**. So every sparkline is a sliding ~1-hour window, oldest point
  left, newest point right. It is NOT clock-aligned (not "top of the hour to now") — if a
  writer was down for a stretch, the window just has fewer/gappier points, no visible gap
  marker.
- Consumed by `Status/fleet_api.py`'s `/api/history/<host>` endpoint (reads the JSONL file,
  returns parsed array, comment there already says "~1 hour" — so the backend already knows
  this, it's just not surfaced in the UI).
- Rendered in `Web/ST/tiles.html` by `applySparklines()` (~line 944) via `buildSparklineSVG()`.

**Fix**: add a small caption near each `.si-spark-wrap` — something like `60m` or
`LAST HOUR` — so it's not ambiguous. Since the window length is a fixed constant
(120 entries × 30s), this can be a static label, not something computed from the actual
data span. If you want it to be honest about gappy data (writer was down part of the
window), you could instead compute `(entries[entries.length-1].ts - entries[0].ts)` and
show the actual span, but that's more work for a mostly-cosmetic fix — static "60m" is
probably good enough unless gaps turn out to be common in practice.

## Part B — status transition log (the main piece)

### Goal

An append-only, per-checker-host log that records only the *moments a host or service's
status actually changes* (not every 30s poll), so you can answer "how many times did
TravelBeast/ComfyUI flap in the last hour" or "when did Amsterdam's Flask API last go
down" without grepping raw poll summaries.

### Why this lives in the checker, not the per-machine writers

The per-machine metrics writers (`heartbeat_writer_linux.py`, the PS1/Mac equivalents)
only know their own local CPU/RAM/disk stats — they have no concept of fleet-wide
up/down status. That determination is made entirely by `Status/engine.py`'s poll loop
(`_check_machine`, `_check_service`, `_assemble_state`). So the transition log needs to
be built there, alongside the existing `reporters/json_reporter.py` call.

### Existing pieces to build on

- `Status/engine.py::run_forever()` (line ~64) — the `while True:` loop that calls
  `_poll_cycle()` every `POLL_INTERVAL_SECONDS` (30s, `config.py`). This is a single
  long-lived process (per checker host), so **in-memory state persists across cycles
  within one run** but resets on restart (task restart, box reboot, deploy). That's an
  acceptable gap for a personal fleet tool — worst case you lose the ability to detect
  "changed while restarting" for one cycle, not ongoing data.
- `Status/reporters/json_reporter.py::report(state, status_dir, checker_host)` — called
  once per cycle from `_poll_cycle()` (engine.py line ~91) after `_assemble_state()`
  builds `state`. This is the natural sibling location for a new reporter.
- **Careful**: there are already two *different* log files per checker host, easy to
  confuse:
  - `STATUS_DIR / f"checker_{CHECKER_HOST}_app.log"` — Python `logging` output
    (INFO-level poll summaries + exceptions), set up in `checker.py::_configure_logging()`.
    This is the one that was tailed during the TravelBeast debugging session.
  - `STATUS_DIR / f"checker_{checker_host}.log"` — a separate one-line-per-cycle summary
    written by `json_reporter.py::_append_log()` (counts only, no per-host detail).
  The new transition log should be a **third, distinctly-named file** — don't overload
  either existing one. Suggest: `STATUS_DIR / "status_transitions.jsonl"`.
- `STATUS_DIR` = `Path("c:/fleet_monitor") / CHECKER_HOST` (config.py line 24). Note
  `CHECKER_HOST` is derived from `%COMPUTERNAME%` lowercased (config.py line 17) — on
  AmsterdamDesktop this is truncated to `amsterdamdeskto` (15-char NetBIOS limit, missing
  the final "p"). This bit an earlier debugging session; don't assume the dir name matches
  the friendly hostname.

### Data model

One JSON object per line (JSONL, matching the existing `metrics_history_*.json` convention
so any future tooling can reuse the same parsing approach as `fleet_api.py`'s
`/api/history/<host>` does):

```json
{"ts": "2026-07-22T01:15:00Z", "scope": "host", "host": "travelbeast", "service": null, "from": "up", "to": "down", "detail": "Ping failed: ..."}
{"ts": "2026-07-22T01:15:30Z", "scope": "service", "host": "travelbeast", "service": "ComfyUI", "from": "up", "to": "down", "detail": "Connection timeout"}
```

- `scope`: `"host"` (Layer 1 result) or `"service"` (a service's `tailscale_check.status`).
  Public-check (`Layer 3`) transitions could be a third scope (`"public"`) if wanted, but
  start with host+service since those are what actually gate the tile's red border.
- `detail`: carry over whatever `detail` string the checker already produced (from
  `host_result`/`tailscale_check`), so the log entry is self-explanatory without needing
  to cross-reference anything.
- No `id`/`uuid` needed — `(ts, scope, host, service)` is unique enough for a personal tool.

### Where to hook the diff

In `engine.py::_poll_cycle()`, after `_assemble_state()` builds the new `state`, diff it
against the previous cycle's `state` (kept in a module-level or closure variable across
`run_forever()`'s loop iterations — simplest is a module-level `_previous_state: dict | None`
in `engine.py`, or pass it into a new reporter function that keeps its own internal
previous-state cache). For each machine in `state["machines"]`:
- Compare `machine["host"]["status"]` to the previous cycle's value for that
  `tailscale_name`. If different, and previous isn't `None` (i.e. skip the very first
  cycle after a restart — nothing to diff against), emit a host-scope transition.
- For each service in `machine["services"]`, compare `service["tailscale_check"]["status"]`
  the same way, emit a service-scope transition on change.
- First cycle after process start: build the previous-state snapshot but don't emit any
  transitions (avoids a burst of spurious "unknown → whatever" entries every restart).

Implementation location: either inline in `engine.py` right after `_assemble_state()`, or
(cleaner, matches the existing `reporters/` pattern) a new
`Status/reporters/transitions_reporter.py` with a `report(state, status_dir, checker_host)`
function mirroring `json_reporter.py`'s signature, called from the same spot in
`_poll_cycle()`. The reporter module would need to own the previous-state cache internally
(e.g. a module-level dict keyed by checker_host, or just a plain module-level var since
each checker process only ever calls it for its own host) since `engine.py` already passes
`state` fresh each cycle and doesn't currently retain history itself.

### Retention

Match the existing pattern in the PS1/Linux writers: trim to last N lines on each append
(e.g. last 500-1000 entries, or time-based — drop lines older than 7 days by parsing `ts`
on each write). Given transitions are rare (only on actual flaps), a line-count cap of
even a few thousand will cover months of history, so this is low-stakes — pick whichever's
easier to implement, line-count trim is simpler (same approach as
`heartbeat_writer_linux.py` line 155: read existing, append, slice last N, write back).

Write atomically the same way `json_reporter.py::_write_json()` does (write to `.tmp`,
`.replace()`) to avoid a torn read if `fleet_api.py` reads it mid-write — though since this
is append-only line data, a simple `open(path, "a")` append (as `_append_log` already does)
is arguably fine too; a reader tailing the file will just see the file grow, not get
corrupted mid-line unless the process crashes mid-write, which is an acceptable risk for
a personal monitoring tool.

### Serving it — `fleet_api.py`

Add an endpoint mirroring `/api/history/<host>` (fleet_api.py line ~76), e.g.:

```
GET /api/transitions?host=<name>&limit=<n>
```

Reads `STATUS_DIR / "status_transitions.jsonl"`, filters by `host` if given (query param,
optional — omit to get the whole fleet), returns the last `limit` (default e.g. 50) entries
as a JSON array, newest last (or first — match whatever `applySparklines()` expects if you
want to reuse conventions). Same graceful-degradation pattern as `/api/history/<host>`:
missing file → empty array, not an error.

**Note on the two-checker-host setup**: ChatWorkhorse and AmsterdamDesktop each run their
own independent `checker.py` process polling the same fleet redundantly (that's the
existing architecture — see `Status/readme.md`). That means **each will maintain its own
separate transition log**, and the two may not agree exactly on flap timing/count, since
they're checking over different network paths (also literally what motivated the
TravelBeast TCP/HTTP retry fixes — one checker host might see a blip the other doesn't).
This is expected, not a bug — treat each checker's transitions log as that checker's-eye
view, same as `server_status_all.json` already is. Whichever checker's `fleet_api.py`
instance serves a given dashboard request only shows that host's transitions.

### UI (tiles.html) — optional follow-up, not required for the data layer to be useful

Once the log exists, a small addition to `Web/ST/tiles.html` could show, e.g., a
"⚡ 3 flaps in last hour" badge or "last down: 12m ago" per tile, fetched via a new
`fetchTransitions(host)` alongside the existing `fetchHistory(host)` call
(`fetchAllHistory()`, ~line 1032). Not scoped in detail here — the data layer (Parts A/B
above) is the priority; UI can follow once you can see the log actually populating and
know what's worth surfacing.

## Deployment reminders (same as the recent TCP/HTTP retry fixes)

- Repo root on Mac: `/Users/dennishmathes/repos/scripts`. Commit via `./sync-this "message"`
  (per-repo, current-branch, commit+pull --rebase+push — see root `CLAUDE.md`). Per user's
  global instructions, **never commit/push without being explicitly asked** in a given
  session, even though this spec describes the eventual change.
- Two checker hosts, both Windows, reached via `ssh <tailscale-name>` (lands directly in
  PowerShell, not cmd/bash — use `;` not `&&` to chain commands):
  - `ssh chatworkhorse` — repo at `C:\repos\scripts`
  - `ssh amsterdamdesktop` — repo at `D:\repos\scripts` (the one exception to `C:\repos`
    across the Windows fleet)
- After `git pull` on each box, restart the scheduled task (name confirmed via
  `fleet-configs/AmsterdamDesktop/TaskSched/Fleet Checker.xml` and
  `fleet-configs/ChatWorkHorse/TaskSched/Fleet Checker.xml`, both named exactly
  `"Fleet Checker"`):
  ```powershell
  Stop-ScheduledTask -TaskName "Fleet Checker"
  Start-ScheduledTask -TaskName "Fleet Checker"
  ```
- To verify a restart actually picked up new code (not just that the task launched),
  tail the **app log** (not the reporter's summary log) and look for a real
  `Poll complete` line timestamped *after* the "Fleet Checker starting" line, not just
  the launch itself:
  ```powershell
  Get-Content 'c:\fleet_monitor\<checker_host>\checker_<checker_host>_app.log' -Tail 10
  ```
  Remember `<checker_host>` for AmsterdamDesktop is `amsterdamdeskto` (truncated), not
  `amsterdamdesktop`.
- Each poll cycle currently takes ~50-80s wall time (not the nominal 30s
  `POLL_INTERVAL_SECONDS`, which is the *sleep between* cycles, not the cycle duration) —
  factor that into how long to wait before checking logs for confirmation.

## Open decisions for the implementer

1. Inline the diff in `engine.py` vs. a new `reporters/transitions_reporter.py` module —
   spec above leans toward the separate reporter for consistency with `json_reporter.py`,
   but either works.
2. Retention: line-count cap vs. time-based trim. Line-count is simpler and matches
   existing writer code precedent.
3. Whether to include Layer 3 (`public_check`) transitions as a third `scope`, or leave
   that out for now since the tile's red border is driven by host/service status, not
   public endpoint reachability.
4. Whether the sparkline label (Part A) should be a static "60m" or computed from actual
   first/last entry timestamps — static is less work, computed is more honest about gaps.
