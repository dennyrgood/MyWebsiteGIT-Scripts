# Migrating to the Mac Mini M4 ("WorkHub") — plan

Target: ~2 months out (fall 2026 pull-forward). Goal: retire amsterdamdesktop
(Win11) entirely — Flask backends, OpenWebUI, and its leg of the fleet
status checker — and stop running always-on LaunchAgent services on the
laptop. Consolidate all of it onto the new Mac Mini M4.

## 1. Flask backends (currently on amsterdamdesktop, Win11)

| App | Port | Blocker to move | Effort |
|---|---|---|---|
| Weather dashboard (`Flask/weather/weather-dashboard/weather_backend.py`) | 5005 | None found — no Windows-specific paths, just `app.run(host='0.0.0.0')`. Should run on macOS unmodified. | Low |
| Excel editor (`Flask/movies_shows/excel-web-interface/excel_backend.py`) | 5000 | Hardcoded `EXCEL_FILE = D:\OneDrive\...\Movies Shows - to add.xlsx` (Win path) | Medium |
| Excel full-edit (`Flask/movies_shows/MoviesShowsFullEdit/excel_backend_full_edit.py`) | 5001 | Same hardcoded Windows OneDrive path | Medium |

**Steps:**
1. Confirm OneDrive is (or will be) installed and syncing
   `MathesDropBox/00  Top Drawer/Movies Shows - to add.xlsx` on the Mac Mini.
   Note the actual sync path — likely under
   `~/Library/CloudStorage/OneDrive-.../...` on modern macOS OneDrive, not a
   raw `~/OneDrive/...` path.
2. Update `EXCEL_FILE` in both `excel_backend.py` and
   `excel_backend_full_edit.py` to that macOS path (`os.path.expanduser`
   already used, just needs the right string — no code restructuring
   needed).
3. Port 5000 conflicts with macOS's built-in AirPlay Receiver on some
   Macs — check `System Settings > General > AirDrop & Handoff` and either
   disable AirPlay Receiver or confirm this Mac Mini doesn't have it enabled
   by default (already noted as a gotcha in the LaunchAgents README).
4. No `requirements.txt` exists anywhere for these — write one (Flask,
   flask_cors, openpyxl, requests) and create a venv on the Mac Mini rather
   than relying on manual installs, matching the `.venv` pattern already
   used for search_adv/search_shows.
5. Confirmed via Task Scheduler (see below): each backend is its own
   "At system startup" task (Flask Excel Backend, Flask Full Edit, Flask
   Weather), no recurring schedule or retry logic. Maps 1:1 onto a
   LaunchAgent per backend, same pattern as `scripts/launchagents/`
   (`RunAtLoad` + `KeepAlive`).
6. Frontend HTML/JS for these apps is served from GitHub Pages
   (`excel-web-interface`, `movies-shows-editor`, `weather-dashboard` repos)
   and points at whatever hostname/IP the backend runs on — after moving,
   update those frontends' API base URLs to the Mac Mini's address (likely
   its Tailscale name, consistent with how search_shows/search_adv are
   reached remotely today).
7. `Status/fleet_api.py` and the two redundant heartbeat writers
   (AmsterdamDesktop, ChatWorkhorse) currently describe amsterdamdesktop as
   "Flask/API Primary" — update `Status/readme.md`'s host table once the
   move is live, and decide whether amsterdamdesktop keeps running as a
   heartbeat source at all or is decommissioned outright.

## 2. LaunchAgent services (currently on this laptop)

Current agents, per `scripts/launchagents/README.md`:

| Label | What it runs | Port |
|---|---|---|
| `com.dennis.search-adv-web` | search_adv web GUI | 5025 |
| `com.dennis.search-shows-web` | search_shows web GUI (cast/actor/show lookup) | 5020 |
| `com.dennis.travel-http` | `python3 -m http.server` for `dennyrgood.github.io/travel` | 5030 |
| `com.dennis.heartbeat-writer` | fleet heartbeat → OneDrive | — |

**Steps:**
1. Clone the needed repos (`search_adv`, `search_shows`,
   `dennyrgood.github.io`, `scripts`) onto the Mac Mini, same layout as the
   laptop (`~/repos/...`) — the plists and install script assume that
   layout and the current user's home dir.
2. Rebuild each repo's `.venv` on the Mac Mini (they're venv-pinned, not
   portable binaries — same as the existing per-Mac fleet rollout done for
   Ollama/heartbeat).
3. Copy `scripts/launchagents/*.plist` + `install.sh` over (already
   repo-versioned, so just `git pull` + `./install.sh` once repos exist) —
   no plist edits needed as long as the Mac Mini uses the same
   `/Users/dennishmathes` home path. If the account name differs, the
   plists' hardcoded paths need a one-time sed.
4. Grant Full Disk Access to the venv/system python used by
   `heartbeat-writer` up front (this bit every previous Mac in the fleet
   rollout per `MIGRATION.md`) — do this proactively rather than debugging
   silent OneDrive write failures again.
5. Decide whether the laptop keeps *any* of these running (e.g. as a
   fallback while testing the Mac Mini) or is fully decommissioned as a
   server the moment the Mac Mini is verified — recommend running both for
   a short overlap window, then commenting out the laptop's copies (same
   "keep old starter commented for rollback" pattern already used
   elsewhere).
6. Update DNS/Tailscale-facing references: anything bookmarking the
   laptop's Tailscale name (`denniss-macbook-air` or similar) for
   search_adv/search_shows/travel needs to point at the Mac Mini's
   Tailscale name instead — including any iPhone shortcuts, browser
   bookmarks, or the frontend GitHub Pages sites' hardcoded API URLs from
   Part 1.
7. Rename hostname to match its Tailscale name from day one (a past
   fleet gotcha: mismatched hostnames caused Ollama DNS-rebinding 403s) —
   do this before installing any LaunchAgents that will be reached by
   hostname.

## 3. OpenWebUI (currently on amsterdamdesktop, bare pip install)

Fragile bare-pip deployment today (heavy dependency tree, drifts easily).
Stateless relative to the fleet — no important chat history to preserve
(confirmed) — and it already talks to remote Ollama instances over the
network rather than anything local, so this is a low-risk move.

**Steps:**
1. Stand up a fresh OpenWebUI Docker container on the Mac Mini rather than
   reinstalling via pip — same trust level you already have in Docker from
   running Immich on wbu/cwhu, and it removes the dependency-drift fragility
   for good instead of just relocating it.
2. Re-add the same Ollama connections it has today (`admin/settings/connections`):
   `http://chatworkhorse:11434`, `http://imagebeast:11434`,
   `http://travelbeast:11434`, `http://denniss-macbook-air:11434`.
3. Decide, while re-adding connections: does the Mac Mini's own Ollama get
   added as a new entry, and does `denniss-macbook-air` stay in the list
   once the laptop is no longer meant to run always-on services?
4. No data migration needed (chat history confirmed unimportant) — this is
   a clean fresh-container setup, not a lift-and-shift.

## 4. Fleet status checker + presenter (currently one leg on amsterdamdesktop)

`Status/checker.py` (poller) and `Status/fleet_api.py` (Flask JSON server)
currently run redundantly on two Windows machines (amsterdamdesktop,
ChatWorkhorse), each writing to a separate OneDrive-synced status file per
`Status/readme.md`. Nothing about the design is Windows-specific — it's
plain Python hitting HTTP endpoints and writing JSON to a shared
OneDrive-synced location — so the Mac Mini can take over amsterdamdesktop's
leg directly; the redundant pair doesn't need to be same-platform, and a
platform-diverse pair is arguably better (catches platform-specific bugs
that would otherwise take out both legs at once).

**Steps:**
1. Clone `scripts` (already needed for LaunchAgents/Flask above) and
   confirm `checker.py` / `fleet_api.py` have no Windows-only dependencies
   (check for anything shelling out to Windows-specific tools or paths).
2. Set up the Mac Mini's own OneDrive-synced status file path, matching
   the pattern ChatWorkhorse and amsterdamdesktop already use.
3. Confirmed via Task Scheduler: "Fleet Checker" and "Fleet status" are
   separate "At system startup" tasks (poller vs. presenter) — translate
   each to its own LaunchAgent, consistent with the other always-on
   services.
4. Update `Status/readme.md`'s host table once live to reflect the Mac
   Mini as the second leg instead of amsterdamdesktop.

## 5. Suggested order of operations

1. Set up the Mac Mini's base environment first: hostname matching
   Tailscale name, repos cloned, venvs built, FDA grants done.
2. Migrate LaunchAgent services first (lower risk, no Windows-path
   rework, matches a rollout pattern already proven 3x on other Macs).
3. Migrate Flask backends second: fix the Excel path, write the
   requirements file, write new plists, verify OneDrive sync actually
   reaches the file on the Mac Mini before cutting over.
4. Stand up OpenWebUI fresh on the Mac Mini via Docker and re-add the
   Ollama connections — can happen any time in parallel, since it has no
   dependency on the other pieces.
5. Migrate the fleet status checker's amsterdamdesktop leg to the Mac
   Mini, verify both legs are writing correctly before treating it as the
   new redundant pair.
6. Update frontend API URLs and any bookmarks/shortcuts once the Flask
   and LaunchAgent pieces are verified reachable.
7. Decommission amsterdamdesktop and stop the laptop's LaunchAgents only
   after a short overlap/verification window across all four pieces.

## Confirmed: amsterdamdesktop startup mechanism

All relevant pieces are plain Windows Task Scheduler tasks triggered "At
system startup," all shown "Running" in the Task Scheduler screenshot
reviewed 2026-07-16. No cron-like recurring schedule or retry logic to
replicate — this maps directly onto launchd's `RunAtLoad` + `KeepAlive`,
the same pattern the existing `scripts/launchagents/*.plist` already use.
No extra scheduling design work needed, just one plist per task.

| Task Scheduler name | Maps to | Doc section |
|---|---|---|
| Flask Excel B... | `excel_backend.py` (port 5000) | §1 |
| Flask Full Edi... | `excel_backend_full_edit.py` (port 5001) | §1 |
| Flask Weath... | `weather_backend.py` (port 5005) | §1 |
| Fleet Checker | `Status/checker.py` (poller) | §4 |
| Fleet status | `Status/fleet_api.py` (presenter) | §4 |
| HeartbeatWr... | fleet heartbeat writer (amsterdamdesktop's leg, separate from the laptop's `com.dennis.heartbeat-writer`) | §4 |
| OpenWebUI | OpenWebUI (bare pip today) | §3 |

## Open questions to resolve before starting

- Where will OneDrive actually place `Movies Shows - to add.xlsx` on the
  Mac Mini, and is OneDrive-on-Mac reliable enough for this, or should the
  file move to iCloud Drive / a synced git-tracked location instead?
- Mac Mini's account name / home path — confirm it'll be
  `/Users/dennishmathes` so the plists need no edits.
- Does amsterdamdesktop get fully decommissioned, or does it stay as a
  redundant heartbeat source per the existing two-Windows-machines
  redundancy design in `Status/readme.md`?
- Are there any Windows-only dependencies in `checker.py`/`fleet_api.py`?
- Does the Mac Mini's own Ollama get added to OpenWebUI's connection list,
  and does `denniss-macbook-air` stay in that list post-migration?
