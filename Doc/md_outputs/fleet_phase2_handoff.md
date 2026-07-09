**TURN OFF NORDVPN**

**\**

One thing to note for Phase 2 --- the Fleet API on Amsterdam will serve
from \_sync_monitor/amsterdamdesktop/server_status_all.json and the
backup on ChatWorkhorse from
\_sync_monitor/chatworkhorse/server_status_all.json. Each serves its own
view of the fleet, which is correct behavior.

**AdditionalNotes:**

**New-NetFirewallRule -DisplayName \"Tailscale - Flask API\" -Direction
Inbound -Protocol TCP -LocalPort 5000 -InterfaceAlias \"Tailscale\"
-Action Allow**

**New-NetFirewallRule -DisplayName \"Tailscale - Flask API-Edit\"
-Direction Inbound -Protocol TCP -LocalPort 5001 -InterfaceAlias
\"Tailscale\" -Action Allow**

**New-NetFirewallRule -DisplayName \"Tailscale - Flask Weather\"
-Direction Inbound -Protocol TCP -LocalPort 5005 -InterfaceAlias
\"Tailscale\" -Action Allow**

**New-NetFirewallRule -DisplayName \"Tailscale - OpenWebUI\" -Direction
Inbound -Protocol TCP -LocalPort 8080 -InterfaceAlias \"Tailscale\"
-Action Allow**

**New-NetFirewallRule -DisplayName \"Tailscale - Fleet API\" -Direction
Inbound -Protocol TCP -LocalPort 5010 -InterfaceAlias \"Tailscale\"
-Action Allow**

**Set-NetFirewallRule -DisplayName \"Tailscale - Flask API\"
-InterfaceAlias Any**

**Set-NetFirewallRule -DisplayName \"Tailscale - Flask API-Edit\"
-InterfaceAlias Any**

**Set-NetFirewallRule -DisplayName \"Tailscale - Flask Weather\"
-InterfaceAlias Any**

**Set-NetFirewallRule -DisplayName \"Tailscale - OpenWebUI\"
-InterfaceAlias Any**

**Set-NetFirewallRule -DisplayName \"Tailscale - Fleet API\"
-InterfaceAlias Any**

Set-NetFirewallProfile -Profile Domain,Private -Enabled False

**Notes**

**OLLAMA_HOST fix (run on ChatWorkhorse, then restart Ollama from system
tray):**

setx OLLAMA_HOST \"0.0.0.0\"

**Firewall rules (run on ChatWorkhorse in elevated PowerShell):**

powershell

New-NetFirewallRule -DisplayName \"Tailscale - Ollama\" -Direction
Inbound -Protocol TCP -LocalPort 11434 -InterfaceAlias \"Tailscale\"
-Action Allow

New-NetFirewallRule -DisplayName \"Tailscale - OpenWebUI\" -Direction
Inbound -Protocol TCP -LocalPort 8080 -InterfaceAlias \"Tailscale\"
-Action Allow

New-NetFirewallRule -DisplayName \"Tailscale - ComfyUI\" -Direction
Inbound -Protocol TCP -LocalPort 8188 -InterfaceAlias \"Tailscale\"
-Action Allow

New-NetFirewallRule -DisplayName \"Tailscale - Fleet API\" -Direction
Inbound -Protocol TCP -LocalPort 5010 -InterfaceAlias \"Tailscale\"
-Action Allow

Set-NetFirewallRule -DisplayName \"Tailscale - Ollama\" -InterfaceAlias
Any

Set-NetFirewallRule -DisplayName \"Tailscale - OpenWebUI\"
-InterfaceAlias Any

Set-NetFirewallRule -DisplayName \"Tailscale - ComfyUI\" -InterfaceAlias
Any

Set-NetFirewallRule -DisplayName \"Tailscale - Fleet API\"
-InterfaceAlias Any

The Set-NetFirewallRule lines were needed because the interface alias
binding wasn\'t matching traffic --- removing the restriction fixed it.

**\**

**Fleet Status Dashboard**

Phase 2 & 3 Handoff Document

*Session continuation --- Phase 1 checker complete and tested*

# Phase 1 Status --- Complete

The checker service (Phase 1) is fully built and tested on Amsterdam.
All files are flat in D:\\repos\\scripts\\Status\\ (no subdirectories).
Key outcomes from testing:

- Layer 1 TCP host reachability working on all online machines

- Layer 2 service checks returning correct detail strings (GPU, VRAM,
  model counts)

- Layer 3 public endpoint checks passing for all configured Cloudflare
  URLs

- JSON reporter writing per-machine and master JSON files to
  D:\\OneDrive\\\_sync_monitor\\

- Two known infrastructure fixes applied: OLLAMA_HOST=0.0.0.0 on
  ChatWorkhorse, IPv4-forced TCP checker

- ChatWorkhorse firewall rules added for ports 8080, 8188, 11434, 5010

# Known Issues Carried Forward

  -----------------------------------------------------------------------
  **ImageBeast          Not running or OLLAMA_HOST not set. Same fix as
  Ollama/OpenWebUI**    ChatWorkhorse: setx OLLAMA_HOST 0.0.0.0, restart
                        Ollama. Also need firewall rules same as
                        ChatWorkhorse.
  --------------------- -------------------------------------------------
  **TravelBeast         Not running or firewall. Same fix pattern.
  Ollama**              

  **MacBook Air Prime   Host reachable (port refused = alive) but Ollama
  Ollama**              not responding on 11434. May need OLLAMA_HOST fix
                        on macOS: launchctl setenv OLLAMA_HOST 0.0.0.0

  **MacBook Air 2**     Offline/asleep. Ignore for now.

  **ChatWorkhorse       Not deployed yet --- intentional. Will be added
  OpenWebUI**           later.

  **Amsterdam           B9 priority, on-demand only. Expected down. No
  ComfyUI/Ollama**      fix needed.
  -----------------------------------------------------------------------

# Current File Layout --- Amsterdam

All files are flat in D:\\repos\\scripts\\Status\\ with subdirectories
for checkers/ and reporters/:

> D:\\repos\\scripts\\Status\\
>
> checker.py --- entry point (Task Scheduler launches this)
>
> config.py --- all machines, ports, timeouts, OneDrive path
>
> engine.py --- poll loop, orchestration, state assembly
>
> test_checker.py --- diagnostic test script
>
> checkers\\
>
> \_\_init\_\_.py
>
> tcp_checker.py --- Layer 1 host reachability (IPv4-forced)
>
> http_checker.py --- generic HTTP GET used by service checkers
>
> ollama_checker.py --- /api/tags + /api/ps
>
> comfyui_checker.py --- /system_stats + /queue
>
> openwebui_checker.py --- /health
>
> flask_checker.py --- GET /
>
> reporters\\
>
> \_\_init\_\_.py
>
> json_reporter.py --- writes JSON files + append log to OneDrive

# Important config.py Notes

  -----------------------------------------------------------------------
  **CHECKER_HOST**      amsterdamdesktop on Amsterdam. Must be changed to
                        chatworkhorse when deploying to ChatWorkhorse.
  --------------------- -------------------------------------------------
  **probe_port**        Each machine has a probe_port for Layer 1 TCP
                        check. ImageBeast/TravelBeast=8188,
                        ChatWorkhorse=11434, Amsterdam=5000,
                        MacBooks=11434.

  **127.0.0.1           engine.py and test_checker.py substitute
  substitution**        127.0.0.1 when tailscale_name == CHECKER_HOST to
                        avoid Windows IPv6 loopback delay.

  **ChatWorkhorse       public_url is None (not chat.ldmathes.cc --- that
  OpenWebUI**           points to Amsterdam\'s OpenWebUI).

  **OneDrive path**     Resolved via env vars: OneDriveConsumer, then
                        OneDrive, then \~/OneDrive fallback.
  -----------------------------------------------------------------------

# Phase 2 --- Fleet API (fleet_api.py)

A new standalone Flask app. Completely separate from the checker
service. Reads the master JSON from OneDrive and serves it. Does zero
checking itself.

## Spec

  -----------------------------------------------------------------------
  **File**              fleet_api.py --- single file, no subdirectories
                        needed
  --------------------- -------------------------------------------------
  **Port**              5010 on both Amsterdam and ChatWorkhorse

  **Endpoint**          GET /api/status --- returns
                        server_status_all.json contents

  **CORS**              Restricted to https://www.ldmathes.cc only

  **Auth**              None --- Cloudflare Zero Trust handles access at
                        the tunnel

  **State**             Stateless --- reads JSON file on every request,
                        no caching

  **Dependencies**      Flask only --- no SQLite, no external deps beyond
                        Flask

  **Error handling**    If JSON file missing or unreadable: return HTTP
                        503 with JSON error body

  **Stale detection**   Add X-Data-Age header: seconds since master JSON
                        was last written
  -----------------------------------------------------------------------

## fleet_api.py --- Full Spec

Build this file from scratch in the new session:

- Import: flask, json, os, pathlib, datetime --- nothing else

- Read STATUS_DIR and CHECKER_HOST from config.py (same config file)

- Single route: GET /api/status

- On request: read MASTER_STATUS_FILE, parse JSON, return with
  Content-Type application/json

- CORS header on every response: Access-Control-Allow-Origin:
  https://www.ldmathes.cc

- If file missing: return {\"error\": \"status file not found\",
  \"checker_host\": CHECKER_HOST} with HTTP 503

- If file unreadable/corrupt: return {\"error\": \"status file
  unreadable\"} with HTTP 503

- Add X-Data-Age response header: integer seconds since file mtime

- Add X-Checker-Host response header: value of CHECKER_HOST

- GET /health endpoint: returns {\"status\": \"ok\", \"checker_host\":
  CHECKER_HOST} --- used by Cloudflare health checks

- Run on host 0.0.0.0, port 5010, debug=False

## Testing Phase 2

After building fleet_api.py, test in order:

1.  Confirm server_status_all.json exists in
    D:\\OneDrive\\\_sync_monitor\\ (run checker once first if not)

2.  Start fleet_api.py: python fleet_api.py

3.  curl http://localhost:5010/api/status --- should return full JSON

4.  curl http://localhost:5010/health --- should return {\"status\":
    \"ok\"}

5.  Verify X-Data-Age and X-Checker-Host headers present in response

6.  Rename status file temporarily, confirm 503 response

7.  Deploy identical file to ChatWorkhorse with
    CHECKER_HOST=chatworkhorse in config.py, repeat tests

# Phase 2 --- Cloudflare Tunnel Setup

Both tunnels must be added before Phase 3 frontend can be tested
end-to-end. These are manual steps in the Cloudflare dashboard.

## Amsterdam --- fleet.ldmathes.cc

  -----------------------------------------------------------------------
  **Tunnel**            Add new public hostname to existing Amsterdam
                        cloudflared tunnel
  --------------------- -------------------------------------------------
  **Subdomain**         fleet

  **Domain**            ldmathes.cc

  **Service**           HTTP --- localhost:5010

  **Zero Trust**        Verify access policy covers fleet.ldmathes.cc

  **CORS**              Fleet API already restricts to www.ldmathes.cc
                        --- no additional Cloudflare CORS config needed
  -----------------------------------------------------------------------

## ChatWorkhorse --- fleet-bkp.ldmathes.cc

  -----------------------------------------------------------------------
  **Tunnel**            Add new public hostname to existing ChatWorkhorse
                        cloudflared tunnel
  --------------------- -------------------------------------------------
  **Subdomain**         fleet-bkp

  **Domain**            ldmathes.cc

  **Service**           HTTP --- localhost:5010

  **Zero Trust**        Verify access policy covers fleet-bkp.ldmathes.cc
  -----------------------------------------------------------------------

## Verification

- curl https://fleet.ldmathes.cc/health --- should return {\"status\":
  \"ok\", \"checker_host\": \"amsterdamdesktop\"}

- curl https://fleet.ldmathes.cc/api/status --- should return full fleet
  JSON

- curl https://fleet-bkp.ldmathes.cc/health --- should return
  checker_host: chatworkhorse

# Phase 2 --- Windows Task Scheduler

Four new Task Scheduler entries total --- two on Amsterdam, two on
ChatWorkhorse. Both checker and Fleet API must auto-start and restart on
failure.

## Amsterdam

  -----------------------------------------------------------------------
  **Task 1 ---          Program: python.exe Arguments:
  Checker**             D:\\repos\\scripts\\Status\\checker.py Start in:
                        D:\\repos\\scripts\\Status\\
  --------------------- -------------------------------------------------
  **Task 2 --- Fleet    Program: python.exe Arguments:
  API**                 D:\\repos\\scripts\\Status\\fleet_api.py Start
                        in: D:\\repos\\scripts\\Status\\

  **Trigger**           At startup --- Begin task: At system startup

  **Restart on          Settings tab: If task fails, restart every 1
  failure**             minute, attempt 999 times

  **Run as**            Current user account with \'Run whether user is
                        logged in or not\'
  -----------------------------------------------------------------------

## ChatWorkhorse

Same task structure as Amsterdam. Copy config.py to ChatWorkhorse first
and change CHECKER_HOST to chatworkhorse before setting up tasks.

  -----------------------------------------------------------------------
  **Task 1 ---          Same as Amsterdam but paths will differ based on
  Checker**             where files are placed on ChatWorkhorse
  --------------------- -------------------------------------------------
  **Task 2 --- Fleet    Same as Amsterdam
  API**                 

  **config.py change**  CHECKER_HOST = \"chatworkhorse\"
  -----------------------------------------------------------------------

# Phase 3 --- GitHub Pages Frontend

Two static HTML files in the www.ldmathes.cc GitHub Pages repo. Each
polls its respective Fleet API. No build step --- pure HTML/JS.

## Files to Create

  ------------------------------------------------------------------------------
  **/status/index.html**       Polls https://fleet.ldmathes.cc/api/status ---
                               primary frontend
  ---------------------------- -------------------------------------------------
  **/status-bkp/index.html**   Polls https://fleet-bkp.ldmathes.cc/api/status
                               --- backup frontend

  ------------------------------------------------------------------------------

## UI Spec

  -----------------------------------------------------------------------
  **Target device**     Mobile-first, iPhone 15 Pro Max primary. Must
                        work on desktop too.
  --------------------- -------------------------------------------------
  **Global summary      Top of page: e.g. \'14/16 services healthy · 7/8
  bar**                 public endpoints reachable\' --- sourced from
                        summary block in JSON, no frontend math

  **Machine cards**     One card per machine. Shows: display_name,
                        primary_role, host status, service rows, last
                        checked timestamp converted to local time

  **Service rows**      Each service shows: name, priority badge,
                        Tailscale check status+detail, public check
                        status+response time (if applicable)

  **MacBook treatment** MacBook Air Prime and MacBook Air 2 visually
                        lighter --- present but clearly secondary

  **Offline machines**  Show last seen timestamp even when down

  **Stale data          Show clear visual indicator if API unreachable OR
  warning**             data timestamp \> 90 seconds old

  **API down state**    Frontend stays up, shows \'API unreachable\'
                        banner --- never blank

  **Auto-refresh**      Every 30 seconds --- use setInterval, not page
                        reload

  **Timestamps**        All UTC in JSON --- convert to user local time
                        for display only

  **Tech**              Vanilla HTML/JS only --- no React, no build step,
                        no npm. Single file per page.
  -----------------------------------------------------------------------

## Priority Badge Colors

  -----------------------------------------------------------------------
  **P**                 Green --- primary service
  --------------------- -------------------------------------------------
  **B2**                Blue --- real backup

  **B5**                Yellow/amber --- capable but not preferred

  **B9**                Orange --- last resort

  **B99**               Gray --- theoretical only
  -----------------------------------------------------------------------

## Status Indicator Colors

  -----------------------------------------------------------------------
  **up**                Green dot
  --------------------- -------------------------------------------------
  **down**              Red dot

  **unknown**           Gray dot
  -----------------------------------------------------------------------

## Data Flow Reminder

The frontend fetches one URL only --- /api/status. The summary block is
pre-calculated by the engine. The machines array contains full
per-machine objects inline. The frontend does zero math and zero data
transformation beyond timestamp display.

## Testing Phase 3

- Open /status/index.html directly from filesystem first (before GitHub
  Pages deploy) --- use a local server: python -m http.server 8000

- Verify summary bar matches the JSON summary block exactly

- Verify all service detail strings display correctly

- Test stale data warning by stopping the checker and waiting 90+
  seconds

- Test API down state by pointing fetch at a bad URL

- Test on iPhone 15 Pro Max viewport (430x932) before finalizing

- Deploy to GitHub Pages repo, verify both /status and /status-bkp work

# JSON Schema Reference

Master file served at /api/status. Machines array contains full
per-machine objects inline.

## Top-level structure

> { meta, summary, machines\[\] }

## meta block

  -----------------------------------------------------------------------------
  **timestamp_utc**           ISO8601 UTC --- when this poll cycle ran
  --------------------------- -------------------------------------------------
  **checker_host**            amsterdamdesktop or chatworkhorse --- which
                              instance wrote this

  **poll_interval_seconds**   30

  **fleet_version**           1.0

  **cycle_duration_ms**       total ms for the poll cycle
  -----------------------------------------------------------------------------

## summary block --- pre-calculated, frontend reads directly

  ----------------------------------------------------------------------------
  **machines_total /         Host-level counts
  machines_up /              
  machines_down /            
  machines_unknown**         
  -------------------------- -------------------------------------------------
  **services_total /         Service-level counts --- unknown = services on
  services_up /              unreachable hosts
  services_down /            
  services_unknown**         

  **public_endpoints_total / Layer 3 counts
  public_endpoints_up /      
  public_endpoints_down**    
  ----------------------------------------------------------------------------

## Per-machine object

> machine: { display_name, tailscale_name, tailscale_ip, primary_role }
>
> poll: { timestamp_utc, poll_duration_ms, checker_host }
>
> host: { status, response_time_ms, detail }
>
> services\[\]: { name, port, priority, tailscale_check, public_check }

## tailscale_check

> { status: up\|down\|unknown, response_time_ms, detail }

## public_check --- null if no public_url configured

> { url, status, http_code, response_time_ms, detail }

## Detail string examples

  -----------------------------------------------------------------------
  **Ollama passing**    12 models available · llama3:8b active in VRAM
  --------------------- -------------------------------------------------
  **Ollama idle**       12 models available · none active

  **ComfyUI passing**   VRAM: 18.2GB / 32GB · GPU: RTX 5090 · Queue: idle

  **ComfyUI busy**      VRAM: 18.2GB / 32GB · GPU: RTX 5090 · Queue: 2
                        running, 5 pending

  **OpenWebUI**         healthy

  **Flask**             HTTP 200 or HTTP 400 --- service alive

  **Any failure**       Connection timeout or DNS resolution failed etc.
  -----------------------------------------------------------------------

# Remaining Setup Tasks Checklist

## Amsterdam

- \[ \] Run checker.py once manually to generate server_status_all.json
  before starting Fleet API

- \[ \] Build and test fleet_api.py locally on port 5010

- \[ \] Add Cloudflare tunnel entry: fleet.ldmathes.cc → localhost:5010

- \[ \] Verify Zero Trust access policy covers fleet.ldmathes.cc

- \[ \] Add Task Scheduler entry: checker.py --- startup, restart on
  failure

- \[ \] Add Task Scheduler entry: fleet_api.py --- startup, restart on
  failure

- \[ \] Fix ImageBeast: setx OLLAMA_HOST 0.0.0.0, restart Ollama, add
  firewall rules

## ChatWorkhorse

- \[ \] Copy all Status files to ChatWorkhorse

- \[ \] Update config.py: CHECKER_HOST = chatworkhorse

- \[ \] Build and test fleet_api.py locally on port 5010

- \[ \] Add Cloudflare tunnel entry: fleet-bkp.ldmathes.cc →
  localhost:5010

- \[ \] Verify Zero Trust access policy covers fleet-bkp.ldmathes.cc

- \[ \] Add Task Scheduler entry: checker.py --- startup, restart on
  failure

- \[ \] Add Task Scheduler entry: fleet_api.py --- startup, restart on
  failure

- \[ \] Deploy OpenWebUI when ready

## GitHub Pages

- \[ \] Create /status/ subdirectory in www.ldmathes.cc repo

- \[ \] Create /status-bkp/ subdirectory

- \[ \] Build and deploy index.html for both

- \[ \] Verify Cloudflare Zero Trust covers both GitHub Pages URLs

# New Session Startup Instructions

Paste this at the start of the new session:

> *\"I am continuing work on the Fleet Status Dashboard project. Phase 1
> (checker service) is complete and tested on Amsterdam. I need to build
> Phase 2 (fleet_api.py Flask app on port 5010) and Phase 3 (GitHub
> Pages frontend). All files are in D:\\repos\\scripts\\Status\\ on
> Amsterdam. Read this handoff document and confirm you understand the
> current state before we write any code.\"*

Then attach this document and the current config.py so the new session
has full context.
