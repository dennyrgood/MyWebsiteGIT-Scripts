# How to change a fleet Task Scheduler task (and keep fleet-configs current)

Quick reference for whenever you add/rename/edit a scheduled task involved in
fleet-status (writer, metrics server, checker, API) on any machine.

## The short version

1. Make your change on the box (create/rename/edit the task, edit a script, etc).
2. Re-run that box's snapshot script to capture the new state:
   - Repo box (Win): `<drive>:\repos\scripts\<Machine>\<machine>-snapshot-fleet-configs.ps1`
   - Repo box (Mac/Ubuntu): `scripts/<Machine>/<machine>-snapshot-fleet-configs.sh`
3. `cd fleet-configs && git status` — review, delete any now-stale XML (e.g. a task
   you renamed leaves its old name's `.xml` behind — the snapshot won't remove it
   automatically), then commit + push.

Full background: `Status/README_MOVE_AWAY_ONEDRIVE.md` (architecture) and
`fleet-configs/README_GET_CONFIG.md` (the snapshot/collect workflow, per-machine table).

## Things that bite you

- **Renaming a task doesn't need export/recreate.** Task Scheduler GUI: right-click
  the task → Rename (or F2). Safe — doesn't touch the action/trigger. Just remember
  to re-run the snapshot afterward and delete the old-named XML from fleet-configs.
- **The snapshot scripts find the metrics/writer tasks by their ACTION** (they run
  `fleet_metrics_server.py` / the writer script), not by a hardcoded task name — so
  it doesn't matter what you've named the task on a given box. This is why task names
  have drifted (Matrix / Metrix / Metrics) across boxes with zero functional impact.
- **Task Scheduler XML must be UTF-16** for `schtasks /Create /XML` to accept it.
  The snapshot scripts already export correctly (`Out-File -Encoding Unicode`); if
  you ever hand-author or hand-edit one, keep it UTF-16 or re-export.
- **Avoid non-ASCII characters (em-dashes, curly quotes) in `.ps1` files.** Windows
  PowerShell 5.1 has no way to detect UTF-8 without a BOM, so it guesses the system
  codepage — a stray em-dash can decode as mojibake and break string literals,
  producing confusing "missing closing brace" parse errors far from the real cause.
  Use plain ASCII (`--`, straight quotes) in these scripts.
- **`$ErrorActionPreference = "Stop"` is deliberately NOT set** in the snapshot
  scripts. It would turn `schtasks`' stderr (e.g. a stale task name, or "Access is
  denied" on a protected task like OpenWebUI) into a terminating error and abort the
  whole export. Each task export is individually wrapped so one bad task just logs a
  warning and the rest still runs.
- **`Join-Path "D:\repos" ...` throws `DriveNotFoundException`** on any box with no
  `D:` drive at all (not just a missing folder) — non-terminating here, but noisy.
  The repo-root probe uses plain string concatenation (`"$_\fleet-configs"`) instead.
- **Root crontab (cwhu/wbu) needs local sudo** — can't be refreshed by running the
  snapshot over a non-interactive SSH session (no password prompt reaches you). Run
  it locally on the box if you need a fresh `crontab-l-root.txt`.
