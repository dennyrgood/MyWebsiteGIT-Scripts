# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A flat grab-bag of standalone shell/PowerShell/Python scripts and a few multi-file tool subdirectories for managing a personal fleet of machines (Mac, Windows, Ubuntu) — fleet status monitoring, ComfyUI model/node management, Ollama helpers, git tooling, backups, and a Flask backend migration. There is no top-level build system, package manager, or test suite (no root `package.json`, `requirements.txt`, `pyproject.toml`, or `Makefile`). Most things are invoked as standalone executables (`./script-name`) or sourced shell functions.

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

- `Status/` — Fleet Status Checker system: `checker.py` polls remote hosts, `fleet_api.py` (Flask) serves the JSON, static dashboards display it. Runs redundantly on two Windows machines (AmsterdamDesktop, ChatWorkhorse) writing to separate OneDrive-synced status files. See `Status/readme.md` for the full host table and architecture diagram.
- `comfyui/` — Scripts for managing a multi-machine ComfyUI setup (IMAGEBEAST, CHATWORKHORSE, TRAVELBEAST). Workflow per `comfyui/readme.MD`: run `Run-FleetScan-[MACHINE].bat` on each Windows box, then `comfy_fleet.sh` on Mac to produce `fleet-output/fleet_report_*.html`. Uses OneDrive-junctioned `Models_bare` folders to share models between Chat/Travel machines.
- `dms_util/` — Python modules (`dms_*.py`) implementing a personal file-management/dedup tool (scan, categorize, summarize, cleanup, render); has `__init__.py`/`__pycache__` (built with Python 3.13) but no packaging metadata — imported/run in place, invoked via the top-level `dms` script.
- `tasks/` — Google Tasks export scripts (`export_tasks.py`, `gemini-code-export-tasks.py`) with their own `venv/`; run via `run.sh` / `run-g.sh`.
- `ChatWorkhorseUnix/` and `WorkBenchUnix/` — host-specific shell scripts (backup, sync, snapshot, health-monitor) for two specific fleet machines; not portable elsewhere.
- `SRC/` — git helper shell functions (`git_helper_scripts.sh`) with a companion guide (`git_helper_scripts.sh`, `git_helpers_guide.md`); the top-level `git-tools`, `git-undo` scripts are the user-facing entry points.
- `MyEverything/` — has its own `build/`/`dist/` output (via `Setup_py2app.py` at repo root, a py2app packaging script), i.e. a packaged Mac app, not a script.

## Commands

No lint/test/build commands exist anywhere in this repo — there is no test suite. The only "commands" are running the individual scripts/tools directly, e.g.:
- `./dms` — main entry point for the `dms_util` file-management tool.
- `comfyui/comfy_fleet.sh` — run ComfyUI fleet scan/report on Mac (after running the per-machine `.bat` scanners on Windows).
- `python3 Flask/weather/weather-dashboard/weather_backend.py` / `python3 Flask/movies_shows/excel-web-interface/excel_backend.py` — run the Flask backends directly (dependencies must be installed manually; no requirements file).
- `tasks/run.sh` / `tasks/run-g.sh` — run the Google Tasks export scripts (uses `tasks/venv`).
