# Fleet Status — OneDrive → Tailscale HTTP cutover checklist

Moves per-machine metrics off the OneDrive `_sync_monitor` file transport onto
local-disk storage served over Tailscale by `fleet_metrics_server.py` (port 9100).
Each machine writes `heartbeat_<host>.txt` / `machine_info_<host>.json` /
`metrics_history_<host>.json` into a **flat** local dir (`C:\fleet_monitor` on
Windows, `~/fleet_monitor` on Mac/Ubuntu); the checker pulls them via HTTP GET.

**This is a clean cutover (HTTP only, no OneDrive fallback).** The moment a
*writer* flips it stops feeding OneDrive, and the moment a *checker* flips it
stops reading OneDrive — so do the whole fleet in one window. Expect a brief
sparse-tile period until every writer has run one cycle.

## Who's involved

Every fleet host runs a heartbeat writer, so **every host** gets the full deploy
(writer repointed to the local `fleet_monitor` dir + metrics server on 9100):

- **Macs (3)** — mac writer via LaunchAgent: `denniss-macbook-air`,
  `denniss-2nd-macbook-air`, `mathes-mac-mini`.
- **Ubuntu (2)** — linux writer via cron: `workbenchunix`, `chatworkhorseunix`.
- **Windows (6)** — `.ps1` writer via `run_hidden*.vbs` (Task Scheduler):
  `amsterdamdesktop` (D:\), `chatworkhorse`, `imagebeast`, `travelbeast`,
  `surface3-gc`, `remotews` (all C:\). Only `amsterdamdesktop` + `chatworkhorse`
  also run the checker + API.

The checker does a live `:9100` GET to every reachable host; since they all now
serve, every tile gets machine_info. Add each box's firewall rule before/with its
server — a firewall that *drops* (not rejects) 9100 before the server is up would
stall that poll ~3.5 s.

Ports: metrics server = **9100** (override `FLEET_METRICS_PORT`). Note 9100 is
node_exporter's default — change it if Prometheus runs anywhere on the fleet.

---

## Phase 0 — Make it available (safe; nothing on the fleet auto-pulls)

- [ ] Push both repos so the fleet *can* pull (no machine pulls until you do it by hand):
  ```bash
  cd ~/repos/scripts && git push
  cd ~/repos/fleet-configs && git push
  ```
- [ ] Pick one maintenance window and finish the fleet promptly once started.

## Phase 1 — Order

Bring up **all 7 writers + metrics servers**, verify each serves locally, **then**
restart the **two checkers** last. The two Windows boxes are both writer and
checker — a reboot handles the ordering for them automatically (Phase 2C).

## Phase 2A — The 3 Macs

`denniss-macbook-air`, `denniss-2nd-macbook-air`, `mathes-mac-mini` — on each:

- [ ] `cd ~/repos/scripts && git pull`
- [ ] `cd ~/repos/scripts/launchagents && ./install.sh`  (adds metrics-server agent, repoints writer to `~/fleet_monitor`)
- [ ] If the macOS app firewall is **on** (System Settings ▸ Network ▸ Firewall ▸ Options…): add `/usr/bin/python3`, **Allow incoming connections**.
- [ ] Verify:
  ```bash
  launchctl list | grep com.dennis      # com.dennis.fleet-metrics-server + heartbeat-writer, last-exit 0
  ls ~/fleet_monitor                     # three host-suffixed files (machine_info can take ~25s first time)
  curl -s http://localhost:9100/machine_info_$(scutil --get LocalHostName | tr 'A-Z' 'a-z').json | head -c 200
  ```

## Phase 2B — The 2 Ubuntu boxes

`workbenchunix`, `chatworkhorseunix`. ⚠️ `git pull` self-activates the writer
within 2 min (cron re-reads the script) and drops the OneDrive rsync — do this
inside the window, not early.

- [ ] `cd ~/repos/scripts && git pull`
- [ ] Install the metrics server (check `User=` and repo path in the unit first):
  ```bash
  sudo cp ~/repos/scripts/Status/fleet_metrics_server.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now fleet_metrics_server
  ```
- [ ] Firewall (only if ufw active — `sudo ufw status`):
  ```bash
  sudo ufw allow in on tailscale0 to any port 9100 proto tcp
  ```
- [ ] Verify:
  ```bash
  systemctl status fleet_metrics_server --no-pager
  ls ~/fleet_monitor
  curl -s http://localhost:9100/machine_info_$(hostname).json | head -c 200
  ```

## Phase 2C — The 6 Windows boxes  (reboot-based — the clean path)

`amsterdamdesktop` (D:\), `chatworkhorse`, `imagebeast`, `travelbeast`,
`surface3-gc`, `remotews` (all C:\). Every task is *At system startup*, and the
`.ps1` writer runs fire-and-forget via `run_hidden*.vbs`→PowerShell (so
`schtasks /End` won't kill it — you'd double-run). A reboot brings everything up
fresh in the right order; on amsterdamdesktop + chatworkhorse it also restarts the
checker + API onto the HTTP path. Run cmd **as Administrator** on each.

- [ ] Pull both repos (do not manually run anything yet):
  ```cmd
  cd /d D:\repos\scripts && git pull            & REM  C:\repos\scripts on chatworkhorse
  cd /d D:\repos\fleet-configs && git pull       & REM  C:\repos\fleet-configs on chatworkhorse
  ```
- [ ] Firewall — allow inbound TCP 9100 (GUI: *Windows Defender Firewall w/ Advanced Security ▸ Inbound Rules ▸ New Rule ▸ Port ▸ TCP 9100 ▸ Allow*), or:
  ```cmd
  netsh advfirewall firewall add rule name="Fleet Metrics 9100" dir=in action=allow protocol=TCP localport=9100
  ```
- [ ] Register the metrics-server task:
  ```cmd
  REM amsterdamdesktop:
  schtasks /Create /TN "FleetMetricsServer" /XML "D:\repos\fleet-configs\AmsterdamDesktop\TaskSched\FleetMetricsServer.xml"
  REM chatworkhorse:
  schtasks /Create /TN "FleetMetricsServer" /XML "C:\repos\fleet-configs\ChatWorkHorse\TaskSched\FleetMetricsServer.xml"
  REM imagebeast / travelbeast / surface3-gc / remotews (portable, SID-free template):
  schtasks /Create /TN "FleetMetricsServer" /XML "C:\repos\scripts\Status\FleetMetricsServer.Crepos.xml"
  ```
  The portable template assumes `c:\misc\pythonw.exe`. Verify on each box with
  `where pythonw.exe`; if it differs, edit the `<Command>` line before importing.
- [ ] **Reboot the box.** On boot: new `.ps1` writer → `C:\fleet_monitor`, checker + API read over HTTP, metrics server serves 9100.
- [ ] Verify after boot:
  ```cmd
  dir C:\fleet_monitor
  curl http://localhost:9100/machine_info_%COMPUTERNAME%.json
  ```

No-reboot alternative (fiddlier): register + `schtasks /Run "FleetMetricsServer"`;
restart the directly-launched tasks with `schtasks /End`+`/Run` on `Fleet Checker`
and `Fleet status`/`Fleet Status`; for the writer, `taskkill` the running
`powershell.exe` hosting the `.ps1`, then `schtasks /Run` its task
(`HeartbeatWriter` on amsdt, `Hearbeat Writer OneDrive` on chatworkhorse).

## Phase 3 — Fleet-wide verification

- [ ] From a checker, pull a couple of peers over Tailscale:
  ```cmd
  curl http://denniss-macbook-air:9100/machine_info_denniss-macbook-air.json
  curl http://workbenchunix:9100/heartbeat_workbenchunix.txt
  ```
- [ ] Dashboards repopulate (RAM/CPU/disk + heartbeat dots):
  - https://status.ldmathes.cc  (Amsterdam feed)
  - https://fleet.ldmathes.cc/status-bkp/  (ChatWorkhorse feed)
- [ ] The two heartbeat cross-checks read **up / "N sec old"** (Amsterdam ↔ ChatWorkhorse).

## Phase 4 — Re-export live tasks + cleanup

The committed Task Scheduler XMLs in fleet-configs were **stale** (they showed a
`pythonw … .py` writer; the live `HeartbeatWriter` actually runs
`wscript … run_hidden_amsDT.vbs` → the `.ps1`). After cutover, re-export the real
tasks so the repo matches reality. On **amsterdamdesktop** (D:\), elevated cmd:

```cmd
schtasks /Query /TN "HeartbeatWriter"     /XML > "D:\repos\fleet-configs\AmsterdamDesktop\TaskSched\HeartbeatWriter.xml"
schtasks /Query /TN "Fleet Checker"       /XML > "D:\repos\fleet-configs\AmsterdamDesktop\TaskSched\Fleet Checker.xml"
schtasks /Query /TN "Fleet status"        /XML > "D:\repos\fleet-configs\AmsterdamDesktop\TaskSched\Fleet status.xml"
schtasks /Query /TN "FleetMetricsServer"  /XML > "D:\repos\fleet-configs\AmsterdamDesktop\TaskSched\FleetMetricsServer.xml"
```

On **chatworkhorse** (C:\) — note the different task names:

```cmd
schtasks /Query /TN "Hearbeat Writer OneDrive" /XML > "C:\repos\fleet-configs\ChatWorkHorse\TaskSched\Hearbeat Writer OneDrive.xml"
schtasks /Query /TN "Fleet Checker"            /XML > "C:\repos\fleet-configs\ChatWorkHorse\TaskSched\Fleet Checker.xml"
schtasks /Query /TN "Fleet Status"             /XML > "C:\repos\fleet-configs\ChatWorkHorse\TaskSched\Fleet Status.xml"
schtasks /Query /TN "FleetMetricsServer"       /XML > "C:\repos\fleet-configs\ChatWorkHorse\TaskSched\FleetMetricsServer.xml"
```

On **imagebeast / travelbeast / surface3-gc / remotews**, capture their writer +
metrics tasks into fleet-configs too (create the box's `TaskSched\` dir if missing;
the writer task name varies — check the Name column in Task Scheduler):
```cmd
schtasks /Query /TN "Heartbeat Writer"   /XML > "C:\repos\fleet-configs\<Box>\TaskSched\HeartbeatWriter.xml"
schtasks /Query /TN "FleetMetricsServer" /XML > "C:\repos\fleet-configs\<Box>\TaskSched\FleetMetricsServer.xml"
```

Then commit the true exports:
```cmd
cd /d D:\repos\fleet-configs && git add -A && git commit -m "Re-export live TaskSched XMLs (post-cutover)" && git push
```

Optional, after a day of stable running:
- [ ] Delete stale OneDrive drops: `…/OneDrive/_sync_monitor/` on Macs + Windows.
- [ ] Remove the old Ubuntu rsync SSH key if unused elsewhere (`~/.ssh/id_ed25519_amsterdamdesktop`).
- [ ] Delete `Status/checkers/onedrive_heartbeat_checker.py` and its `test_checker*.py` references.

## Rollback

Coordinated flip back: on each box `git checkout <pre-cutover-commit> -- <files>`
(or `git revert` the three scripts commits), then redeploy that machine
(`./install.sh` / `systemctl restart` / reboot). The OneDrive writers/rsync/reads
return exactly as before — nothing about the cutover is destructive.

---

### Reference — the three migration commits (scripts repo)

- `d999292` move fleet metrics off OneDrive to HTTP-pull over Tailscale
- `93f6216` fix the (non-live) `.py` Windows heartbeat writer to use fleet_monitor
- fleet-configs `c106f4c` add FleetMetricsServer Task Scheduler tasks

Live Windows writer = the `.ps1` via `run_hidden*.vbs` (already migrated). The
`.py` fix is belt-and-suspenders — the live `HeartbeatWriter` task does not run it.
