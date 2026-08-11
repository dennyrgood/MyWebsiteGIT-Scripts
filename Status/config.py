"""
config.py — Fleet Checker Configuration
All machines, services, ports, check types, and public endpoints defined here.
No code changes needed to add/remove machines or services — edit this file only.
"""
# Last updated: 2026-06-16 19:59 UTC
# Updated: 2026-06-28 UTC — add IMMICH_CONFIG; add WorkBenchUnix and ChatWorkhorseUnix to FLEET
# Updated: 2026-08-11 UTC — add FleetNAS (LAN-only, not Tailscale — see its FLEET entry's comment)

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
TIMEOUT_HTTP_MS = 7000        # Layer 2 Tailscale service checks
TIMEOUT_PUBLIC_MS = 5000      # Layer 3 public endpoint checks

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
        ],
    },
]
