# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A flat grab-bag of standalone shell/PowerShell/Python scripts and a few multi-file tool subdirectories for managing a personal fleet of machines (Mac, Windows, Ubuntu) — fleet status monitoring, ComfyUI model/node management, Ollama helpers, git tooling, backups, and a Flask backend migration. There is no top-level build system, package manager, or test suite (no root `package.json`, `requirements.txt`, `pyproject.toml`, or `Makefile`). Most things are invoked as standalone executables (`./script-name`) or sourced shell functions.

## Fleet machine aliases

The user refers to fleet machines by short alias in conversation — recognize these (fuller table + snapshot scripts in `fleet-configs/README_GET_CONFIG.md`):

| Alias | Host/Tailscale name | scripts subdir | OS |
|---|---|---|---|
| amsdt | amsterdamdesktop | `AmsterdamDesktop/` | Windows |
| cwh | chatworkhorse | `ChatWorkHorse/` | Windows |
| cwhu | chatworkhorseunix | `ChatWorkhorseUnix/` | Ubuntu |
| ib | imagebeast | `ImageBeast/` | Windows |
| mb | denniss-macbook-air | `DennissMacBookAir/` | macOS — main workstation |
| mb2 | denniss-2nd-macbook-air | `Denniss2ndMacBookAir/` | macOS |
| mmm | mathes-mac-mini | `MathesMacMini/` | macOS |
| nas | fleetnas | `FleetNAS/` | Ubuntu |
| rws | remotews | `RemoteWS/` | Windows |
| s3g | surface3-gc | `Surface3GC/` | Windows |
| tb | travelbeast | `TravelBeast/` | Windows |
| wbu | workbenchunix | `WorkBenchUnix/` | Ubuntu |

## Flask backend migration (in progress)

`Flask/` is the **new, canonical** location for backend code being consolidated out of several previously-separate app repos. The corresponding **older/diverged** copies live as sibling repos one level up, at `/Users/dennishmathes/repos/`:

| App | Canonical (here) | Old/diverged sibling repo |
|---|---|---|
| Movies/Shows Excel editor | `Flask/movies_shows/excel-web-interface/excel_backend.py`, `Flask/movies_shows/MoviesShowsFullEdit/excel_backend_full_edit.py` | `../excel-web-interface/` (frontend only now) and `../movies-shows-editor/` |
| Weather dashboard | `Flask/weather/weather-dashboard/weather_backend.py` + HTML/JS | `../weather-dashboard/` (frontend only now) |

Per git history in both this repo and the sibling frontend repos:
- Frontend HTML/JS/CSS for these apps used to live alongside the backend in this repo's `Flask/` dir but was **removed** (commit `f903ec3`, "Remove front-end files from Flask dir; served from GitHub Pages") — frontends are now served via GitHub Pages from the sibling app repos (`../excel-web-interface`, `../movies-shows-editor`, `../weather-dashboard`), each of which still has leftover copies of shared JS/HTML (e.g. `shared-data.js`, `index_*_shared.html`) and its own `CLAUDE.md`.
- Those sibling repos previously had their own `Scripts/`/`OLD/` backend dirs, since removed ("backends moved to scripts repo") — the backend Python now lives only under `Flask/` here.
- So: **`Flask/` = canonical backend**, **sibling repos one level up = canonical frontend + legacy/diverged backend history**. `Flask/movies_shows/` and `Flask/weather/` still contain some static assets (xlsx/csv data files, leftover HTML) left over from when frontend files were copied in before being removed again — treat the HTML under `Flask/weather/weather-dashboard/` as stale relative to `../weather-dashboard/`.
- No `requirements.txt`/`pyproject.toml` exists for the Flask apps; dependencies (Flask, flask_cors, openpyxl, requests) must be installed manually. There is no run script committed — the backends are Flask apps meant to be run directly (`python3 weather_backend.py`, `python3 excel_backend.py`) or via whatever process manager is configured on the host (see `Status/` fleet docs, host `amsterdamdesktop` is described as "Flask/API Primary").
- `excel_backend.py` hardcodes a Windows path to the target `.xlsx` (`D:\OneDrive\...\Movies Shows - to add.xlsx`), so it's expected to run on a specific Windows host, not portably.

## Other notable subdirectories

- `Status/` — Fleet Status Checker system: `checker.py` polls remote hosts, `fleet_api.py` (Flask) serves the JSON, static dashboards display it. Runs redundantly on two Windows machines (AmsterdamDesktop, ChatWorkhorse) writing to separate OneDrive-synced status files. See `Status/readme.md` for the full host table and architecture diagram. As of 2026-07-21, the OneDrive-as-transport design was retired in favor of each box running `fleet_metrics_server.py` (stdlib-only Python `http.server`, port 9100) to serve its own local heartbeat/metrics/machine-info files, with the checker pulling them over Tailscale HTTP instead of reading synced files — see `Status/README_MOVE_AWAY_ONEDRIVE.md` for the full before/after architecture and deployment notes (per-OS writer mechanism, gotchas found rolling it out to each box).
- `fleet-configs` (sibling private repo, one level up) — per-machine config snapshots (Task Scheduler XML, crontabs, launchagents, env files, etc.) for every box in the fleet, used to rebuild a machine's scheduled tasks/services from scratch if needed. Each box has a `*-snapshot-fleet-configs.ps1`/`.sh` script (this repo, under `scripts/<Machine>/`) that dumps its current state into that repo. As of 2026-07-27, all fleet boxes including surface3-gc, remotews, and mathes-mac-mini have a local git checkout — the old OneDrive-staging workaround (`OneDrive\ForFleetConfigs\<box>\` + `scripts/collect-fleet-configs-from-onedrive.sh`) is retired. See `HOWTO_TWEAK_FLEET_TASKS.md` (repo root) for the day-to-day workflow after changing a scheduled task, and `fleet-configs/README_GET_CONFIG.md` for the per-machine snapshot/collect table. Never commit/push in `fleet-configs` without asking first — snapshot output should be reviewed (`git status`, delete stale XML from renamed/removed tasks) before committing. Snapshot-script gotchas: they identify the writer/metrics-server Task Scheduler tasks by the **action** they run (`fleet_metrics_server.py` / the writer script), not by task name, so task names have drifted (Matrix/Metrix/Metrics) across boxes with no functional impact; `$ErrorActionPreference = "Stop"` is deliberately **not** set, so one bad or access-denied task export just logs a warning instead of aborting the whole run; and the root crontab on `ChatWorkhorseUnix`/`WorkBenchUnix` needs local `sudo` to refresh — it can't be captured over a non-interactive SSH session (no password prompt reaches you), so run the snapshot locally on the box for a fresh `crontab-l-root.txt`.
- `comfyui/` — Scripts for managing a multi-machine ComfyUI setup (IMAGEBEAST, CHATWORKHORSE, TRAVELBEAST). Workflow per `comfyui/readme.MD`: run `Run-FleetScan-[MACHINE].bat` on each Windows box, then `comfy_fleet.sh` on Mac to produce `fleet-output/fleet_report_*.html`. Uses OneDrive-junctioned `Models_bare` folders to share models between Chat/Travel machines.
- `dms_util/` — Python modules (`dms_*.py`) implementing a personal file-management/dedup tool (scan, categorize, summarize, cleanup, render); has `__init__.py`/`__pycache__` (built with Python 3.13) but no packaging metadata — imported/run in place, invoked via the top-level `dms` script.
- `tasks/` — Google Tasks export scripts (`export_tasks.py`, `gemini-code-export-tasks.py`) with their own `venv/`; run via `run.sh` / `run-g.sh`.
- `ChatWorkhorseUnix/` and `WorkBenchUnix/` — host-specific shell scripts (backup, sync, snapshot, health-monitor) for two specific fleet machines; not portable elsewhere.
- `SRC/` — git helper shell functions (`git_helper_scripts.sh`) with a companion guide (`git_helper_scripts.sh`, `git_helpers_guide.md`); the top-level `git-tools`, `git-undo` scripts are the user-facing entry points.
- `MyEverything/` — has its own `build/`/`dist/` output (via `Setup_py2app.py` at repo root, a py2app packaging script), i.e. a packaged Mac app, not a script.
- `tmdb_explorer/` — a single-file Flask app (`tmdb_explorer.py` + inline-JS SPA `tmdb_explorer.html`) that proxies TMDB; runs under launchd at `http://mb.ldmathes.cc:5035`. Alongside it, `enrich_xlsx.py` is a standalone CLI (`enrich_xlsx INPUT.xlsx [OUTPUT.xlsx]`) that enriches an .xlsx of movie/TV titles with TMDB columns. It matches each row by the themoviedb.org/imdb.com link already in the sheet (no fuzzy matching), and edits the .xlsx surgically at the XML/zip level — NOT via openpyxl, so external-workbook VLOOKUPs, hyperlinks, and named views survive. The TMDB fields written and the formula columns blanked are the `COLUMNS`/`CLEAR_COLS` constants near the top; reads the key from `~/.config/search_shows/keys.json`, fetches live (no cache).

## Git sync scripts (`sync-this` / `sync-all`, + PowerShell twins)

Top-level scripts that commit + `pull --rebase` + push, in two parallel sets:

- **Mac/Ubuntu:** `sync-this` (current repo) and `sync-all` (every repo under `$HOME/repos`, `.git` up to 3 levels deep, skipping `.bkup`/`.bak`/`_backup`/`_bak` dirs). `sync-ck` is a read-only status peek.
- **Win11:** `sync-this.ps1` / `sync-all.ps1` — added 2026-07-15 as PowerShell equivalents of the two bash scripts, replacing the deleted `git-sync.bat` (which hardcoded `main`, had no commit message, and had no multi-repo analog).

Behavior shared by all four: they act on the **current branch** (not a hardcoded `main`), take the commit message as the first positional arg and prompt only if it's omitted, push with `-u` so new branches work, and abort the transaction rather than pushing if the commit or pull fails. `sync-all`/`sync-all.ps1` also skip repos that are clean *and* up-to-date unless passed `--all`/`-All`, and support `--dry-run`/`-DryRun`.

Bash-pair mechanics (confirmed by reading `sync-this` 2026-07-23), useful when scripting a commit through it:
- It stages with **`git add -A`**, so *everything* untracked/modified/deleted in the repo is swept into the commit — a stray `.bak`, scratch, or editor temp file gets committed unless it's `.gitignore`d. Check `git status` first if you're not sure what's dirty. (This is why the `WorkBenchUnix/*.bak.YYYY-MM-DD` backups end up tracked.)
- The message arg goes straight to **`git commit -m "$1"`**, so it may be **multi-line**: a subject line, a blank line, then a body and trailers (e.g. `Co-Authored-By:`) all fit inside the single quoted argument.
- After committing it runs **`git pull --rebase`** (not merge) before pushing, then reprints status + the last 5 commits so you can confirm the new commit landed. The pre-sync banner shows ahead/behind counts.
- Commits from `WorkBenchUnix` use git's **auto-detected identity** (`Dennis <dhm@workbenchunix.tailb73767.ts.net>`) unless `user.name`/`user.email` are set globally on that box — harmless, but it's why author identity varies across the fleet.

`sync-this`/`sync-this.ps1` resolve the repo from the **current working directory** — the script itself can live anywhere on PATH; you just have to be `cd`'d inside the target repo. `sync-all*` never uses cwd.

Repo roots differ per platform, which is why `sync-all.ps1` doesn't just reuse `$HOME/repos`: on the Windows fleet repos live at `C:\repos` on every machine **except amsterdamdesktop, which uses `D:\repos`**. Rather than branching on hostname, `sync-all.ps1` probes `C:\repos` → `D:\repos` → `$HOME\repos` and takes the first that exists (override with `-RepoRoot`). If a box ever has both `C:\repos` and `D:\repos`, `C:` wins — revisit if that becomes true on amsdt.

The `.ps1` pair uses plain ASCII status glyphs instead of the bash scripts' `↑ ↓ ✓ 📂`, since the default `powershell.exe` console mangles them. They were written on a Mac with no `pwsh` available, so **they have never been executed or even syntax-checked** — first Windows run should be `.\sync-all.ps1 -DryRun`. Also note `.ps1` files need an execution-policy exception (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`) and, to run by bare name from any dir, `.PS1` in `$env:PATHEXT` or a profile wrapper function.

## dms_util / `dms` Doc-index tool — only checks one level up for `.git`

`dms` (and the underlying `dms_util/dms_render.py`, `dms_scan.py`, etc.) manages a `Doc/` folder's `index.html` via `.dms_state.json`/`.dms_scan.json`. Its docstring says it "must be run from the ROOT of a repository," and `dms:283` enforces a version of that: `has_git = (cwd / ".git").exists() or (cwd.parent / ".git").exists()` — it accepts being run either at a repo root, or one level down inside `Doc/` itself, but goes no further than that. It does not walk upward to find a repo root the way `git rev-parse --show-toplevel` would.

This matters because three `Doc/` directories that `dms` previously managed as separate repo roots are no longer repo roots — they were folded into `dennyrgood.github.io` as subdirectories during the 2026-07-06 consolidation (see `dennyrgood.github.io`'s own CLAUDE.md):

- `dennyrgood.github.io/weather/Doc` (was `weather-dashboard/Doc`) — still works: `weather/`'s parent is `dennyrgood.github.io`, which has `.git`.
- `dennyrgood.github.io/excel_edit/Doc` (was `movies-shows-editor/Doc`) — still works, same reason.
- `dennyrgood.github.io/avp/gallery/Doc` (was `usdz-avp/Doc`) — **broken**: `avp/gallery`'s parent is `avp/`, which has no `.git` (it's two levels below the repo root). Running `dms` there errors with "DMS must be run from a git repository," even from inside `Doc/` itself.

Practical handling (confirmed 2026-07-06):
- `dennyrgood.github.io/Doc`, `standing-up-llm/Doc`, `google-photos/Doc`, `scripts/Doc` are true repo roots — `dms scan`/`dms auto` works normally there. As of this date each had a handful of new files not yet indexed; run `dms auto` in each when you want them caught up (low urgency, since new docs mostly go to Google Docs now).
- `dennyrgood.github.io/weather/Doc` and `.../excel_edit/Doc` also work fine as-is (one level below a repo root).
- `dennyrgood.github.io/avp/gallery/Doc` cannot be scanned/rendered by `dms` in its current location. It already has a manually-verified-current `index.html` (confirmed 2026-07-06, no new files added since the consolidation), so no action is needed unless new docs are ever dropped in there — if that happens, either run `dms` against a temporary copy one level shallower and copy the regenerated `index.html` back, or fix `dms:283` to walk upward through all ancestors instead of checking only one level.

## Commands

No lint/test/build commands exist anywhere in this repo — there is no test suite. The only "commands" are running the individual scripts/tools directly, e.g.:
- `./dms` — main entry point for the `dms_util` file-management tool.
- `comfyui/comfy_fleet.sh` — run ComfyUI fleet scan/report on Mac (after running the per-machine `.bat` scanners on Windows).
- `python3 Flask/weather/weather-dashboard/weather_backend.py` / `python3 Flask/movies_shows/excel-web-interface/excel_backend.py` — run the Flask backends directly (dependencies must be installed manually; no requirements file).
- `tasks/run.sh` / `tasks/run-g.sh` — run the Google Tasks export scripts (uses `tasks/venv`).
- `./sync-this "msg"` / `./sync-all "msg" [--dry-run|--all]` — git commit/pull/push for the current repo or every repo under `$HOME/repos` (Mac/Ubuntu). Windows equivalents: `.\sync-this.ps1 "msg"` / `.\sync-all.ps1 "msg" [-DryRun|-All|-RepoRoot <path>]`.
