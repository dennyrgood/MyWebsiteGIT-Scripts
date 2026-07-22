"""
engine.py — Fleet Checker Engine
Orchestrates the polling loop. Knows nothing about specific machines or services —
driven entirely by config. Calls checker modules per check_type, assembles state,
passes to all reporters. Three-layer architecture:
  Layer 1 — TCP host reachability (skip L2/L3 if down)
  Layer 2 — Tailscale service health (per check_type)
  Layer 3 — Public endpoint check (if public_url defined)
Last updated: 2026-06-16 00:00 UTC — _read_machine_info subdirectory lookup for Mac writers
"""

import json
import logging
import os
import time
import urllib.request
from datetime import datetime, timezone

from config import (
    FLEET,
    STATUS_DIR,
    CHECKER_HOST,
    POLL_INTERVAL_SECONDS,
    TIMEOUT_TCP_MS,
    TIMEOUT_HTTP_MS,
    TIMEOUT_PUBLIC_MS,
    METRICS_PORT,
)
from checkers import tcp_checker, http_checker
from checkers import ollama_checker, comfyui_checker, openwebui_checker, flask_checker, plex_checker, http_heartbeat_checker, syncthing_checker, immich_checker
from reporters import json_reporter, transitions_reporter

logger = logging.getLogger(__name__)

# Map check_type strings → checker modules
CHECKER_MAP = {
    "ollama": ollama_checker,
    "comfyui": comfyui_checker,
    "openwebui": openwebui_checker,
    "flask": flask_checker,
    "plex": plex_checker,
    "http_heartbeat": http_heartbeat_checker,
    "syncthing": syncthing_checker,
    "immich": immich_checker,
}


def _read_machine_info(tailscale_name: str) -> dict | None:
    """
    Fetch machine_info_{tailscale_name}.json from the target machine's fleet_metrics_server
    over Tailscale HTTP. The checker's own box is reached via 127.0.0.1. Returns the parsed
    dict, or None if unreachable/unreadable — never raises. Callers should only invoke this
    when the host is already known reachable, so a down machine doesn't cost a timeout.
    """
    host = "127.0.0.1" if tailscale_name == CHECKER_HOST else tailscale_name
    url = f"http://{host}:{METRICS_PORT}/machine_info_{tailscale_name}.json"
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT_HTTP_MS / 1000) as resp:
            return json.loads(resp.read().decode("utf-8-sig"))
    except Exception:
        return None


def run_forever() -> None:
    """Main entry point. Runs poll loop indefinitely."""
    logger.info("Fleet Checker starting — host: %s, interval: %ss", CHECKER_HOST, POLL_INTERVAL_SECONDS)
    while True:
        try:
            _poll_cycle()
        except Exception as e:
            logger.exception("Unhandled error in poll cycle: %s", e)
        time.sleep(POLL_INTERVAL_SECONDS)


def _poll_cycle() -> None:
    """Run one complete poll of all machines, assemble state, write outputs."""
    cycle_start = time.monotonic()
    timestamp_utc = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    machine_results = []

    for machine_cfg in FLEET:
        machine_result = _check_machine(machine_cfg, timestamp_utc)
        machine_results.append(machine_result)

    cycle_ms = round((time.monotonic() - cycle_start) * 1000)

    state = _assemble_state(machine_results, timestamp_utc, cycle_ms)

    # Call all reporters
    json_reporter.report(state, STATUS_DIR, CHECKER_HOST)
    transitions_reporter.report(state, STATUS_DIR, CHECKER_HOST)

    summary = state["summary"]
    logger.info(
        "Poll complete in %dms | machines %d/%d | services %d/%d | public %d/%d",
        cycle_ms,
        summary["machines_up"], summary["machines_total"],
        summary["services_up"], summary["services_total"],
        summary["public_endpoints_up"], summary["public_endpoints_total"],
    )


def _check_machine(machine_cfg: dict, cycle_timestamp: str) -> dict:
    """
    Run all three layers for a single machine.
    Returns a per-machine result dict matching the schema.
    """
    check_start = time.monotonic()
    tailscale_name = machine_cfg["tailscale_name"]

    # --- Layer 1: Host reachability ---

    probe_port = machine_cfg.get("probe_port", 80)
    probe_host = "127.0.0.1" if tailscale_name == CHECKER_HOST else tailscale_name
    host_result = tcp_checker.check(probe_host, TIMEOUT_TCP_MS, port=probe_port)

    host_up = host_result["status"] == "up"

    service_results = []

    for svc_cfg in machine_cfg.get("services", []):
        if not host_up:
            # Host unreachable — mark all services unknown, skip checks
            svc_result = _unknown_service(svc_cfg)
        else:
            svc_result = _check_service(tailscale_name, svc_cfg)

        service_results.append(svc_result)

    # Pull machine_info from the target's fleet_metrics_server over Tailscale.
    # Only when the host is reachable — otherwise the GET would just burn a timeout.
    machine_info = _read_machine_info(tailscale_name) if host_up else None

    # Strip any _machine_info keys left by heartbeat checker (legacy path, no-op if absent)
    for svc_result in service_results:
        svc_result.pop("_machine_info", None)

    poll_duration_ms = round((time.monotonic() - check_start) * 1000)

    result = {
        "machine": {
            "display_name": machine_cfg["display_name"],
            "tailscale_name": machine_cfg["tailscale_name"],
            "tailscale_ip": machine_cfg["tailscale_ip"],
            "primary_role": machine_cfg["primary_role"],
        },
        "poll": {
            "timestamp_utc": cycle_timestamp,
            "poll_duration_ms": poll_duration_ms,
            "checker_host": CHECKER_HOST,
        },
        "host": {
            "status": host_result["status"],
            "response_time_ms": host_result["response_time_ms"],
            "detail": host_result.get("detail"),
        },
        "services": service_results,
    }

    # Only include machine_info key if we actually got data
    if machine_info is not None:
        result["machine_info"] = machine_info

    return result


def _check_service(tailscale_name: str, svc_cfg: dict) -> dict:
    """
    Run Layer 2 (Tailscale service check) and Layer 3 (public endpoint) for one service.
    """
    check_type = svc_cfg["check_type"]
    port = svc_cfg["port"]
    check_params = svc_cfg.get("check_params", {})

    # --- Layer 2: Tailscale service check ---
    if check_type == "tcp":
        # TCP only — no HTTP
        raw = tcp_checker.check(tailscale_name, TIMEOUT_TCP_MS)
        tailscale_check = {
            "status": raw["status"],
            "response_time_ms": raw["response_time_ms"],
            "detail": raw.get("detail") or ("port open" if raw["status"] == "up" else None),
        }
    else:
        checker_module = CHECKER_MAP.get(check_type)
        if checker_module is None:
            logger.warning("Unknown check_type '%s' for service %s", check_type, svc_cfg["name"])
            tailscale_check = {
                "status": "unknown",
                "response_time_ms": 0,
                "detail": f"Unknown check_type: {check_type}",
            }
        else:
            # Pass check_params as additional kwargs to checker modules
            if check_params:
                raw = checker_module.check(tailscale_name, port, TIMEOUT_HTTP_MS, **check_params)
            else:
                raw = checker_module.check(tailscale_name, port, TIMEOUT_HTTP_MS)

            tailscale_check = {
                "status": raw["status"],
                "response_time_ms": raw["response_time_ms"],
                "detail": raw.get("detail"),
            }

    # --- Layer 3: Public endpoint check (if configured) ---
    public_url = svc_cfg.get("public_url")
    public_check = None

    if public_url:
        pub_raw = http_checker.get(public_url, TIMEOUT_PUBLIC_MS)
        code = pub_raw.get("http_code")

        pub_detail = None
        if code == 302:
            pub_detail = "Zero Trust redirect"
        elif code == 401:
            pub_detail = "Zero Trust auth required"
        elif code and code >= 400:
            pub_detail = f"HTTP {code}"

        public_check = {
            "url": public_url,
            "status": pub_raw["status"],
            "http_code": code,
            "response_time_ms": pub_raw["response_time_ms"],
            "detail": pub_detail or pub_raw.get("detail"),
        }

    return {
        "name": svc_cfg["name"],
        "port": port,
        "priority": svc_cfg["priority"],
        "tailscale_check": tailscale_check,
        "public_check": public_check,
    }


def _unknown_service(svc_cfg: dict) -> dict:
    """Return an 'unknown' service result for unreachable host."""
    return {
        "name": svc_cfg["name"],
        "port": svc_cfg["port"],
        "priority": svc_cfg["priority"],
        "tailscale_check": {
            "status": "unknown",
            "response_time_ms": None,
            "detail": "Host unreachable",
        },
        "public_check": None,
    }


def _assemble_state(machine_results: list, timestamp_utc: str, cycle_ms: int) -> dict:
    """
    Assemble full master state object with pre-calculated summary block.
    Frontend does no math — all counts done here.
    """
    machines_total = len(machine_results)
    machines_up = 0
    machines_down = 0
    machines_unknown = 0
    services_total = 0
    services_up = 0
    services_down = 0
    services_unknown = 0
    public_total = 0
    public_up = 0
    public_down = 0

    for m in machine_results:
        host_status = m["host"]["status"]
        if host_status == "up":
            machines_up += 1
        elif host_status == "down":
            machines_down += 1
        else:
            machines_unknown += 1

        for svc in m.get("services", []):
            tc = svc.get("tailscale_check", {})
            svc_status = tc.get("status", "unknown")

            if host_status != "up":
                services_unknown += 1
            else:
                services_total += 1
                if svc_status == "up":
                    services_up += 1
                elif svc_status == "down":
                    services_down += 1
                else:
                    services_unknown += 1

            pc = svc.get("public_check")
            if pc:
                public_total += 1
                if pc["status"] == "up":
                    public_up += 1
                else:
                    public_down += 1

    # services_total should reflect all attempted checks
    services_total = services_up + services_down + services_unknown

    return {
        "meta": {
            "timestamp_utc": timestamp_utc,
            "checker_host": CHECKER_HOST,
            "poll_interval_seconds": POLL_INTERVAL_SECONDS,
            "fleet_version": "1.0",
            "cycle_duration_ms": cycle_ms,
        },
        "summary": {
            "machines_total": machines_total,
            "machines_up": machines_up,
            "machines_down": machines_down,
            "machines_unknown": machines_unknown,
            "services_total": services_total,
            "services_up": services_up,
            "services_down": services_down,
            "services_unknown": services_unknown,
            "public_endpoints_total": public_total,
            "public_endpoints_up": public_up,
            "public_endpoints_down": public_down,
        },
        "machines": machine_results,
    }
