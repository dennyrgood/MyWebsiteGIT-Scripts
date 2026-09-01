"""
config.py — Fleet Checker Configuration
All machines, services, ports, check types, and public endpoints defined here.
No code changes needed to add/remove machines or services — edit this file only.
"""
# Last updated: 2026-06-16 19:59 UTC
# Updated: 2026-06-28 UTC — add IMMICH_CONFIG; add WorkBenchUnix and ChatWorkhorseUnix to FLEET
# Updated: 2026-08-11 UTC — add FleetNAS (LAN-only, not Tailscale — see its FLEET entry's comment)
# Updated: 2026-08-13 UTC — Phase 1 (alert-log noise-reduction project): add TIMEOUT_SYNCTHING_MS,
#   FAIL_STREAK_THRESHOLD, PORTABLE_GRACE_SECONDS/PORTABLE_HOSTS, FLAP_* thresholds,
#   SCHEDULED_BLIP_WINDOWS. Consumed by reporters/transitions_reporter.py and engine.py.
# Updated: 2026-08-13 UTC — moved surface3-gc into REMOTE_LINK_HOSTS (stationary Plex
#   server at a remote site, not a sleeping laptop) and added remotews to the same set
#   for the same reason.

import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Output paths / metrics transport
# ---------------------------------------------------------------------------

# Which machine is running this checker instance
CHECKER_HOST = os.environ.get("FLEET_CHECKER_HOST") or os.environ.get("COMPUTERNAME", "unknown").lower()

# Per-machine self-reported metrics (heartbeat / machine_info / history) are written
# locally on each machine and served over Tailscale by fleet_metrics_server.py. The
# checker pulls them via HTTP on this port — no OneDrive, no file sync.
METRICS_PORT = int(os.environ.get("FLEET_METRICS_PORT", "9100"))

STATUS_DIR = Path("c:/fleet_monitor") / CHECKER_HOST
MASTER_STATUS_FILE = STATUS_DIR / "server_status_all.json"



# ---------------------------------------------------------------------------
# Polling / timeout settings
# ---------------------------------------------------------------------------

POLL_INTERVAL_SECONDS = 30
TIMEOUT_TCP_MS = 5000         # Layer 1 host reachability
TIMEOUT_HTTP_MS = 7000        # Layer 2 Tailscale service checks (default, all check_types)
TIMEOUT_PUBLIC_MS = 5000      # Layer 3 public endpoint checks

# Per-check_type override of TIMEOUT_HTTP_MS. Syncthing runs 4 sequential HTTP
# calls (ping/version/connections/per-folder db status) and 7s was firing on
# legitimate load (large transfers), not failure — see surface3-gc 2026-08-09,
# 68GB in flight. Split out rather than raising TIMEOUT_HTTP_MS globally, since
# other check_types haven't shown this problem.
TIMEOUT_SYNCTHING_MS = 20000

# ---------------------------------------------------------------------------
# Transitions-log tuning (alert-log noise-reduction project, 2026-08-13)
# ---------------------------------------------------------------------------
FAIL_STREAK_THRESHOLD = 2          # consecutive raw "down" observations required before declaring down; 1 "up" clears immediately (asymmetric)
PORTABLE_GRACE_SECONDS = 30 * 60   # portables (laptops that sleep) don't get a host down/up transition unless the outage outlasts this
REMOTE_LINK_GRACE_SECONDS = 5 * 60 # stationary but remote-sited hosts on a flaky/relayed link — shorter grace than a sleeping laptop
FLAP_THRESHOLD = 6                 # transitions within FLAP_WINDOW_MINUTES that collapse into one "chatter" line
FLAP_WINDOW_MINUTES = 60
FLAP_STABLE_MINUTES = 30           # must hold steady this long before flap suppression lifts

# Portables are expected to sleep/roam — see PORTABLE_GRACE_SECONDS above.
PORTABLE_HOSTS = {
    "denniss-macbook-air", "denniss-2nd-macbook-air", "travelbeast",
}

# Stationary but at a remote site on a Tailscale-relayed link, not a sleeping device —
# both are Plex servers, confirmed 2026-08-13 (surface3-gc was mis-lumped in with the
# portables initially; remotews added same day for the same reason). Gets a shorter
# grace period than PORTABLE_HOSTS, not the sleep rationale. Adjust
# REMOTE_LINK_GRACE_SECONDS above if 5 min proves wrong either way.
REMOTE_LINK_HOSTS = {
    "surface3-gc", "remotews",
}

# Servers (everything else in FLEET, incl. the two sets above by exception) stay
# strict: any down/up transition emits immediately, no held grace period.

# Scheduled, expected blips: the down/up transition inside the window is suppressed,
# but if the expected blip does NOT happen at all that day, that silence is the anomaly
# and gets its own alert line. chatworkhorseunix Immich goes "connection refused" for
# ~2 min around 02:00 UTC nightly (4am CEST warm-sync) — confirmed expected; absent on
# 2026-08-08 and 2026-08-10 with no way to notice under the old logging.
SCHEDULED_BLIP_WINDOWS = [
    {
        "host": "chatworkhorseunix", "service": "Immich",
        "start_utc": "01:55", "end_utc": "02:10",
        "label": "nightly warm-sync (4am CEST)",
    },
]

# ------ Plex Configuration ------
PLEX_CONFIG = {
    "surface3-gc": {
        "plex_url": "http://surface3-gc:32400",
        "plex_token": "xqetuxscJvEVVUdNE6-v",
    },
    "mathes-mac-mini": {
        "plex_url": "http://mathes-mac-mini:32400",
        "plex_token": "xqetuxscJvEVVUdNE6-v",
    },
        "denniss-2nd-macbook-air": {
        "plex_url": "http://denniss-2nd-macbook-air:32400",
        "plex_token": "xqetuxscJvEVVUdNE6-v",
    },
    "remotews": {
        "plex_url": "http://remotews:32400",
        "plex_token": "xqetuxscJvEVVUdNE6-v",
    },
    "chatworkhorse": None,
    "travelbeast": None,
    "amsterdamdesktop": None,
    "denniss-macbook-air": None,
    "imagebeast": None,
}

SYNCTHING_CONFIG = {
    "surface3-gc": {
        "syncthing_url": "http://surface3-gc:8384",
        "api_key": "NXiQUQ2MnrHfZwrALKxECfrHrmwWfLqi",
    },
    "mathes-mac-mini": {
        "syncthing_url": "http://mathes-mac-mini:8384",
        "api_key": "rPDLKezk4ppcf6sYDwdmLwtv3jx3ZUvg",
    },
        "denniss-2nd-macbook-air": {
        "syncthing_url": "http://denniss-2nd-macbook-air:8384",
        "api_key": "YXrcyDGXJe9hhgUacuPZuwcWJUREc49S",
    },
    "remotews": {
        "syncthing_url": "http://remotews:8384",
        "api_key": "HuYQZgkKm6ZtnWaHvfKepncUkNwgogsE"
    },
}

IMMICH_CONFIG = {
    "workbenchunix": {
        "api_key": "iuCCTHgYgbSaGQ2USs1xW4rk9bfZwHvQWhsi1agIU",  # fill in from Immich UI -> Account Settings -> API Keys
    },
    "chatworkhorseunix": {
        "api_key": "iuCCTHgYgbSaGQ2USs1xW4rk9bfZwHvQWhsi1agIU",
    },
}


# ---------------------------------------------------------------------------
# Fleet definition
# ---------------------------------------------------------------------------
# check_types controls which checker modules run for each service:
#   "tcp"       — TCP connect only (no HTTP)
#   "ollama"    — Ollama API (/api/tags + /api/ps)
#   "comfyui"   — ComfyUI API (/system_stats + /queue)
#   "openwebui" — OpenWebUI health (/health)
#   "flask"     — Flask alive (GET /)
#   "http_heartbeat" — writer-liveness check over Tailscale HTTP (requires check_params: {target_host})
#
# priority: service display priority
#   "P"  — primary service for this host; featured on tile with full metrics
#   "S"  — secondary; shown as status dot on tile, full detail in drill-down
#
# probe_port: port used for Layer 1 TCP host reachability check.
#             Pick the most reliably open port on that machine.
#             Port 22 (SSH) is NOT used — most machines are Windows without SSH.
#
# public_url: present = Layer 3 check runs; null = Tailscale only
# check_params: optional dict of extra arguments for checker modules

FLEET = [
    {
        "display_name": "ImageBeast",
        "tailscale_name": "imagebeast",
        "tailscale_ip": "100.107.247.38",
        "primary_role": "ComfyUI Primary",
        "probe_port": 22,
        "services": [
            {
                "name": "ComfyUI",
                "port": 8188,
                "priority": "P",
                "check_type": "comfyui",
                "public_url": "https://image.ldmathes.cc",
            },
            {
                "name": "Ollama",
                "port": 11434,
                "priority": "P",
                "check_type": "ollama",
                "public_url": None,
            },    
        ],
    },
    {
        "display_name": "ChatWorkhorse",
        "tailscale_name": "chatworkhorse",
        "tailscale_ip": "100.110.253.46",
        "primary_role": "Ollama Primary",
        "probe_port": 22,
        "services": [
            {
                "name": "Ollama",
                "port": 11434,
                "priority": "P",
                "check_type": "ollama",
                "public_url": None,
            },
            {
                "name": "OpenWebUI",
                "port": 8080,
                "priority": "S",
                "check_type": "openwebui",
                "public_url": "https://talk.ldmathes.cc",
            },
            {
                "name": "ComfyUI",
                "port": 8188,
                "priority": "P",
                "check_type": "comfyui",
                "public_url": "https://clips.ldmathes.cc",
            },
            {
                "name": "Fleet API",
                "port": 5010,
                "priority": "S",
                "check_type": "flask",
                "public_url": "https://fleet-bkp.ldmathes.cc",
            },
            {
                "name": "Amsterdam Desktop Heartbeat Check",
                "port": 0,  # Not applicable for heartbeat check
                "priority": "S",
                "check_type": "http_heartbeat",
                "public_url": None,
                "check_params": {"target_host": "amsterdamdesktop"}
            },
        ],
    },
    {
        "display_name": "TravelBeast",
        "tailscale_name": "travelbeast",
        "tailscale_ip": "100.73.82.42",
        "primary_role": "Mobile/Travel",
        "probe_port": 22,
        "services": [
            {
                "name": "ComfyUI",
                "port": 8188,
                "priority": "P",
                "check_type": "comfyui",
                "public_url": None,
            },
            {
                "name": "Ollama",
                "port": 11434,
                "priority": "P",
                "check_type": "ollama",
                "public_url": None,
            },
        ],
    },
    {
        "display_name": "Amsterdam",
        "tailscale_name": "amsterdamdesktop",
        "tailscale_ip": "100.125.37.114",
        "primary_role": "Flask / OpenWebUI Primary",
        "probe_port": 22,
        "services": [
            {
                "name": "OpenWebUI",
                "port": 8080,
                "priority": "P",
                "check_type": "openwebui",
                "public_url": "https://chat.ldmathes.cc",
            },
            {
                "name": "Flask/API",
                "port": 5000,
                "priority": "S",
                "check_type": "flask",
                "public_url": "https://api.ldmathes.cc",
            },
            {
                "name": "Flask/API-Edit",
                "port": 5001,
                "priority": "S",
                "check_type": "flask",
                "public_url": "https://api-edit.ldmathes.cc",
            },
            {
                "name": "Flask/Weather",
                "port": 5005,
                "priority": "P",
                "check_type": "flask",
                "public_url": "https://weatherproxy.ldmathes.cc",
            },
            {
                "name": "Fleet API",
                "port": 5010,
                "priority": "P",
                "check_type": "flask",
                "public_url": "https://fleet.ldmathes.cc",
            },
            {
                "name": "ChatWorkhorse Heartbeat Check",
                "port": 0,  # Not applicable for heartbeat check
                "priority": "S",
                "check_type": "http_heartbeat",
                "public_url": None,
                "check_params": {"target_host": "chatworkhorse"}
            },
        ],
    },
    {
        "display_name": "MacBook Air Prime",
        "tailscale_name": "denniss-macbook-air",
        "tailscale_ip": "100.72.187.19",
        "primary_role": "Ollama",
        "probe_port": 11434,  # Ollama port (ignored; Tailscale ping used instead)
        "services": [
            {
                "name": "Ollama",
                "port": 11434,
                "priority": "P",
                "check_type": "ollama",
                "public_url": None,
            },
        ],
    },
    {
        "display_name": "Plex Server GC",
        "tailscale_name": "surface3-gc",
        "tailscale_ip": "100.72.84.84",
        "primary_role": "Plex Server",
        "probe_port": 22,
        "services": [
            {
                "name": "Plex",
                "port": 32400,
                "priority": "P",
                "check_type": "plex",
                "public_url": None,
            },
            {
                "name": "Syncthing",
                "port": 8384,
                "priority": "P",
                "check_type": "syncthing",
                "public_url": None,
            },
        ],
    },
    {
        "display_name": "Plex Server AMS",
        "tailscale_name": "mathes-mac-mini",
        "tailscale_ip": "100.108.12.39",
        "primary_role": "Plex Server",
        "probe_port": 22,
        "services": [
            {
                "name": "Plex",
                "port": 32400,
                "priority": "P",
                "check_type": "plex",
                "public_url": None,
            },
            {
                "name": "Syncthing",
                "port": 8384,
                "priority": "P",
                "check_type": "syncthing",
                "public_url": None,
            },
        ],
    },
    {
        "display_name": "MacBook Air 2",
        "tailscale_name": "denniss-2nd-macbook-air",
        "tailscale_ip": "100.92.24.75",
        "primary_role": "Plex / Ollama",
        "probe_port": 22,
        "services": [
            {
                "name": "Ollama",
                "port": 11434,
                "priority": "P",
                "check_type": "ollama",
                "public_url": None,
            },
            {
                "name": "Plex",
                "port": 32400,
                "priority": "P",
                "check_type": "plex",
                "public_url": None,
            },
            {
                "name": "Syncthing",
                "port": 8384,
                "priority": "P",
                "check_type": "syncthing",
                "public_url": None,
            },
        ],
},
    {
        "display_name": "Plex Server Bekah",
        "tailscale_name": "remotews",
        "tailscale_ip": "100.69.183.71",
        "primary_role": "Plex Server",
        "probe_port": 22,
        "services": [
            {
                "name": "Plex",
                "port": 32400,
                "priority": "P",
                "check_type": "plex",
                "public_url": None,
            },
            {
                "name": "Syncthing",
                "port": 8384,
                "priority": "P",
                "check_type": "syncthing",
                "public_url": None,
            },
        ],
    },
    {
        # New box added 2026-08-31, may eventually replace surface3-gc. Deliberately
        # minimal for now (per user): only the base Fleet Metrics Server / Heartbeat /
        # Watchdog pipeline is deployed (see SurfaceGoLaptopGC/sgc-health-monitor.ps1) --
        # no Plex/Syncthing checks yet, so no "services" entries below. machine_info/
        # heartbeat still gets pulled automatically like every other FLEET host.
        "display_name": "Plex Server GC New",
        "tailscale_name": "surfacegolaptopgc",
        "tailscale_ip": "100.125.98.23",
        "primary_role": "Plex Server",
        "probe_port": 22,
        "services": [],
    },
    {
        "display_name": "WorkBenchUnix",
        "tailscale_name": "workbenchunix",
        "tailscale_ip": "100.105.10.123",
        "primary_role": "Immich",
        "probe_port": 22,
        "services": [
            {
                "name": "Immich",
                "port": 2283,
                "priority": "P",
                "check_type": "immich",
                "public_url": None,
            },
            {
                # upsd for UPS #2 (ups2). Closes the monitoring gap noted in "UPS and NUT
                # Setup Guide - Amsterdam v7" Section 8: if upsd dies, ImageBeast/ChatWorkhorse
                # get no signal and just silently lose shutdown coverage. Port-only, not the
                # host ping — WBU itself staying up doesn't mean upsd is still running.
                "name": "NUT (ups2)",
                "port": 3493,
                "priority": "S",
                "check_type": "tcp",
                "public_url": None,
            },
        ],
    },
    {
        "display_name": "ChatWorkhorseUnix",
        "tailscale_name": "chatworkhorseunix",
        "tailscale_ip": "100.118.51.113",
        "primary_role": "Immich",
        "probe_port": 22,
        "services": [
            {
                "name": "Immich",
                "port": 2283,
                "priority": "P",
                "check_type": "immich",
                "public_url": None,
            },
        ],
    },
    {
        # FleetNAS is NOT on Tailscale — it's a UGREEN NAS reachable only on
        # the home LAN. There's no separate "host" field in this schema, so
        # its LAN IP is used directly as tailscale_name (a misnomer here;
        # engine.py just uses this field as the literal string it connects
        # with). This works as long as the checker (AmsterdamDesktop) is on
        # the same LAN/subnet as 192.168.178.123 — true today, revisit if
        # the checker ever moves off that network.
        # The Heartbeat service's target_host below MUST match FleetNAS/
        # run_heartbeat_nas.sh's HOST exactly (both filename and URL host
        # for http_heartbeat_checker) — see that script's header comment.
        "display_name": "FleetNAS",
        "tailscale_name": "192.168.178.123",
        "tailscale_ip": "192.168.178.123",
        "primary_role": "NAS / Storage",
        "probe_port": 22,
        "services": [
            {
                "name": "Heartbeat",
                "port": 0,  # Not applicable for heartbeat check
                "priority": "P",
                "check_type": "http_heartbeat",
                "public_url": None,
                "check_params": {"target_host": "192.168.178.123"},
            },
            {
                # upsd for UPS #1 (ups0). Same rationale as WorkBenchUnix's NUT check —
                # the NAS staying reachable doesn't guarantee upsd on it is still running.
                "name": "NUT (ups0)",
                "port": 3493,
                "priority": "S",
                "check_type": "tcp",
                "public_url": None,
            },
        ],
    },
]
