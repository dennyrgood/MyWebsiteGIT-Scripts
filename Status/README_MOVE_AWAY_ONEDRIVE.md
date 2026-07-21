# Moving Fleet Status off OneDrive → Tailscale HTTP

**Completed 2026-07-21.** This documents why and how the Fleet Status system stopped
using OneDrive as a transport, the new architecture, and everything learned deploying
it across the fleet (so the next box — or the next person — isn't re-discovering it).

See also: `readme.md` (system overview), `CUTOVER_CHECKLIST.md` (the step-by-step
runbook used for the rollout).

---

## Why we moved

OneDrive was never really a database — it started as a way to test whether OneDrive
itself was wedged (the original `heartbeat.txt`) and accreted into the transport for
*all* per-machine metrics. As a transport it was a bad fit:

- **Sync lag vs. a 5-minute stale threshold** — a healthy Mac could show STALE/DOWN
  simply because OneDrive hadn't propagated its heartbeat yet. False alarms.
- **Tiny-file churn** — writing 3 files every 30–150 s across ~11 machines is exactly
  what OneDrive handles worst (batching, throttling, `... (2).json` conflict copies).
- **macOS-hostile** — OneDrive on the Macs was the flakiest link of all.

Everything is already on Tailscale, and the checker already polls every box over it.
So the fix was to stop syncing files and instead **serve them over HTTP and pull**.

---

## Architecture: before → after

**Before:** each machine's writer wrote `heartbeat_/machine_info_/metrics_history_`
files into `~/OneDrive/_sync_monitor/`; OneDrive synced them to the two Windows
checkers; the checker read them off disk.

**After:** each machine writes those same files to a **local** dir and runs a tiny
HTTP server; the checker **pulls them over Tailscale** — the same kind of GET it
already does to Ollama/ComfyUI.

```
[each box]  writer (local metrics)  ──writes──▶  C:\fleet_monitor  or  ~/fleet_monitor
            fleet_metrics_server.py ──serves──▶  http://<host>:9100/<file>
                                                        │
[checker]   engine._read_machine_info ──HTTP GET──▶ ────┘  (embeds machine_info)
            fleet_api.py /api/history  ──HTTP GET──▶ ────┘  (proxies history)
            http_heartbeat_checker     ──HTTP GET──▶ ────┘  (writer-liveness, 2 checkers)
                     │
                     ▼  merges into  C:\fleet_monitor\<host>\server_status_all.json
            fleet_api.py :5010  ──serves──▶  dashboard
```

A "stale" reading now means the **writer actually stopped**, never that a sync lagged.

### Two processes per box (important mental model)

Every box runs **two** independent things:

| Process | Role | Notes |
|---|---|---|
| **Writer** | *Produces* the files in the local dir | Mac: LaunchAgent loop. Ubuntu: one-shot via cron every 2 min. Windows: PowerShell `.ps1` launched by `run_hidden*.vbs` via a Task Scheduler task. |
| **Metrics server** (`fleet_metrics_server.py`) | *Serves* those files on port **9100** | stdlib-only Python (`http.server`), runs on all three OSes. Path-restricted to the 3 filename patterns. |

The writer makes the data; the server hands it out; the checker reads it. Kill the
writer and within ~5 min the tiles lose CPU/RAM and the heartbeat goes stale.

---

## What changed in the code

- **New:** `fleet_metrics_server.py` — the per-machine static server (port 9100).
- **New:** `checkers/http_heartbeat_checker.py` — writer-liveness over HTTP, replaced
  `onedrive_heartbeat_checker.py` (left in place; still imported by the test files).
- **`config.py`** — dropped `ONEDRIVE_PATH`, added `METRICS_PORT` (9100); the two
  cross-checker services changed `check_type: onedrive_heartbeat` → `http_heartbeat`.
- **`engine.py`** — `_read_machine_info` now HTTP-GETs `http://<host>:9100/machine_info_<host>.json`
  (gated on host-up so a down box costs no timeout); own box reached via 127.0.0.1.
- **`fleet_api.py`** — `/api/history/<host>` proxies `http://<host>:9100/metrics_history_<host>.json`.
- **Writers repointed** off OneDrive to the local dir:
  - `onedrive_heartbeat_writer_all_macs.py` → `~/fleet_monitor`
  - `heartbeat_writer_linux.py` / `run_heartbeat.sh` → `~/fleet_monitor` (and the
    rsync-into-amsterdamdesktop's-OneDrive step was **deleted**)
  - `onedrive_heartbeat_writer_server.ps1` → `C:\fleet_monitor`
  - (the minimal root `onedrive_heartbeat_writer_server.py` was also repointed, though
    the live Windows tasks run the `.ps1` via VBS, not that `.py`)

Local dir convention (flat — filenames are already host-suffixed, so no subdir):
`C:\fleet_monitor` (Windows), `~/fleet_monitor` (Mac/Ubuntu). Override with
`FLEET_METRICS_DIR`; port override `FLEET_METRICS_PORT`.

---

## Deployment per OS

| OS | Writer | Metrics server | Mechanism |
|---|---|---|---|
| **macOS** (3) | `onedrive_heartbeat_writer_all_macs.py` | `fleet_metrics_server.py` | LaunchAgents via `launchagents/install.sh` (`com.dennis.heartbeat-writer`, `com.dennis.fleet-metrics-server`) |
| **Ubuntu** (2) | `run_heartbeat.sh` (cron, every 2 min) | `fleet_metrics_server.py` | systemd unit `Status/fleet_metrics_server.service` |
| **Windows** (6) | `.ps1` via `run_hidden*.vbs` (existing HeartbeatWriter task) | `fleet_metrics_server.py` via `pythonw.exe` | Task Scheduler task `FleetMetricsServer` (At startup) |

Firewall: allow inbound TCP 9100 (`netsh advfirewall firewall add rule …` on Windows;
`ufw allow in on tailscale0 to any port 9100` on Ubuntu if ufw is active; macOS app
firewall → allow `python3` incoming if enabled).

---

## Per-box reality (nothing was uniform)

The fleet is a grab-bag; the deployment method and Python location differed per box.

| Box | Repo? | Writer | Python for metrics server |
|---|---|---|---|
| denniss-macbook-air | yes | mac writer (LaunchAgent) | `/usr/bin/python3` |
| denniss-2nd-macbook-air | yes | mac writer | `/usr/bin/python3` |
| mathes-mac-mini | **no repo** — standalone scripts in `$HOME` | mac writer | `/usr/bin/python3` |
| workbenchunix / chatworkhorseunix | yes | linux writer (cron) | system `python3` |
| amsterdamdesktop | yes (**D:**) | `.ps1` via VBS | `D:\Misc\Python313\pythonw.exe` |
| chatworkhorse | yes | `.ps1` via VBS | `c:\misc\Python313\pythonw.exe` (relocated from flat `c:\misc`) |
| imagebeast | yes | `.ps1` via VBS | `c:\misc\Python313\pythonw.exe` (installed fresh) |
| travelbeast | yes | `.ps1` via VBS | `c:\misc\Python313\pythonw.exe` (was misinstalled flat in `c:\misc`) |
| surface3-gc | **no repo** — bespoke `GC_*` script | `.ps1` (`-WindowStyle Hidden`, no VBS) | `C:\Users\DrDen\AppData\Local\Programs\Python\Python313\pythonw.exe` |
| remotews (Plex-Bekah) | **no repo** — bespoke `Bekah_*` in `C:\Misc` | `Bekah_*.ps1` via `Bekah_run_hidden.vbs` | `C:\Misc\Python313\pythonw.exe` |

**Checker boxes (amsterdamdesktop, chatworkhorse) additionally need Python packages:**
`pip install flask requests plexapi` (flask → `fleet_api.py`; requests → syncthing/immich
checkers; plexapi → `plex_checker`). Writer-only boxes need **bare** Python — the metrics
server is stdlib-only. This bites when reinstalling a checker's Python: pip packages live
in `Lib\site-packages` and the Python *uninstaller does not remove them*, so a fresh
install is missing them until you re-`pip install`.

---

## Gotchas / lessons (things that actually bit us)

- **`schtasks /Create /XML` needs UTF-16.** A UTF-8 XML fails with *"unable to switch the
  encoding."* The committed `FleetMetricsServer*.xml` are UTF-16 for this reason. The
  Task Scheduler **GUI** ("Create Task") was the reliable path throughout.
- **Windows `localhost` → IPv6 `::1`.** The server binds IPv4 `0.0.0.0`, so
  `http://localhost:9100` gives "unable to connect" while **`http://127.0.0.1:9100`**
  works. Use 127.0.0.1 for local tests. (Cross-machine over Tailscale is unaffected.)
- **VBS-launched writer shows "Ready", not "Running".** `run_hidden.vbs` fires PowerShell
  and returns immediately (`…Run …, 0, False`), so the *task* completes ("Ready") while
  the real writer keeps running as a detached `powershell.exe`. "Ready" ≠ stopped.
- **Exported task XMLs go stale.** The archived `HeartbeatWriter.xml` claimed a `pythonw …
  .py` writer, but the live task actually runs `wscript … run_hidden.vbs` → the `.ps1`.
  Re-export live tasks after changes (`schtasks /Query /TN … /XML`).
- **MS-Store Python stubs shadow PATH.** On boxes with the Store Python, the 0 KB
  `WindowsApps\pythonw.exe` aliases resolve first — never rely on `where`; always use a
  full explicit path. Don't tie the metrics server to ComfyUI's embedded Python either.
- **Task Settings:** always **untick "Stop the task if it runs longer than…"** (default
  kills a long-running server after 3 days) and set restart-on-failure.
- **Bespoke boxes** (no repo): mac-mini, surface3-gc, remotews were deployed by copying
  the two files in and editing the writer's output path in place, not `git pull`.

---

## Adding / redoing a box

**Writer** — point it at the local dir. The Windows `.ps1` output block becomes:
```powershell
$heartbeatDir  = if ($env:FLEET_METRICS_DIR) { $env:FLEET_METRICS_DIR } else { "C:\fleet_monitor" }
```
(Mac/Ubuntu writers default to `~/fleet_monitor`.)

**Metrics server** — get `fleet_metrics_server.py` onto the box and run it on 9100:
- macOS: add the LaunchAgent (`launchagents/install.sh`).
- Ubuntu: `sudo systemctl enable --now fleet_metrics_server` (unit in `Status/`).
- Windows: create a `FleetMetricsServer` task (At startup) →
  `<real pythonw path> "…\fleet_metrics_server.py"`. Verify the pythonw path first.
  Import `FleetMetricsServer.Crepos.xml` (UTF-16) or use the GUI.

**Verify** from any box (or the checker):
```bash
curl http://<host>:9100/heartbeat_<host>.txt          # timestamp = writer alive
curl http://<host>:9100/machine_info_<host>.json      # cpu/ram/disk
curl http://<checker>:5010/api/status                 # machine_info present for the host
```
`<host>` must match the box's `tailscale_name` in `config.py` **and** the writer's
`COMPUTERNAME.ToLower()` (add a `$hostnameMap` entry if they differ).

---

## Still-optional cleanup

- Re-export the live Windows task XMLs into `fleet-configs` (the archived ones are stale).
- Delete leftover `OneDrive/_sync_monitor` folders and stray `GC_*`/`Bekah_*` copies.
- Delete `chatworkhorse:C:\Misc\Lib` + `C:\Misc\Scripts` orphaned pip leftovers.
- Standardize the Windows Python locations if the inconsistency ever bothers you.
- OneDrive still moves ComfyUI workflows/images between machines — replacing that
  (likely tuned Syncthing) is a **separate** future task, out of scope here.
