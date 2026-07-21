"""
checkers/tcp_checker.py - Layer 1 host reachability check
Primary probe is ICMP ping; if that fails, falls back to a raw TCP connect on
`port` (when provided) before declaring the host down, since some networks —
notably Tailscale DERP relays and mobile/hotel connections — drop or deprioritize
ICMP while a real TCP handshake still succeeds. Each probe is retried once on
failure to absorb transient packet-loss bursts (common on non-LAN links) rather
than flipping a host to "down" from a single bad poll cycle.
"""

import socket
import subprocess
import re
import sys
import time
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _ping_once(host: str, timeout_s: float) -> dict:
    """Run one ICMP ping attempt, bounded by timeout_s. Returns a result dict."""
    if sys.platform.startswith('win'):
        # Windows ping defaults to 4 pings, force 3 for consistency
        ping_cmd = ["ping", "-n", "3", str(host)]
    else:
        # Linux/macOS ping uses -c for count
        ping_cmd = ["ping", "-c", "3", str(host)]

    try:
        result = subprocess.run(
            ping_cmd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        return {"status": "down", "response_time_ms": 0, "detail": "Ping timed out", "timestamp_utc": _now()}
    except Exception as e:
        return {"status": "down", "response_time_ms": 0, "detail": f"Ping error: {e}", "timestamp_utc": _now()}

    output = result.stdout.strip() + " " + result.stderr.strip()

    has_ping_success = (
        ("64 bytes from" in output.lower() and "icmp_seq" in output.lower())  # Linux/macOS
        or "round-trip" in output.lower()  # Also Linux/macOS
        or "reply from" in output.lower()  # Windows
    )

    if not has_ping_success:
        error_text = result.stderr.strip() if result.stderr else output[:100]
        detail = f"Ping failed: {error_text}" if error_text else "Host unreachable on network"
        return {"status": "down", "response_time_ms": 0, "detail": detail, "timestamp_utc": _now()}

    response_time_ms = 0
    detail = "responded"
    try:
        # Linux/macOS format: round-trip min/avg/max/stddev = 5.123/45.678/67.890/15.321 ms
        linux_match = re.search(r'round-trip\s+[^=]+=\s+(?:min\/)?([\d.]+)', output)
        if linux_match:
            avg_ms = float(linux_match.group(1))
            response_time_ms = round(avg_ms)
            detail = f"avg response time: {response_time_ms}ms"
        else:
            # Windows format: "Reply from X.X.X.X: ... time=95ms ..."
            times = re.findall(r'time=([\d.]+)ms', output, re.IGNORECASE)
            if times:
                avg_time = sum(float(t) for t in times) / len(times)
                response_time_ms = round(avg_time)
                detail = f"avg response time: {response_time_ms}ms"
            elif "64 bytes from" in output.lower():
                # Fallback for localhost ping or individual replies without stats line
                time_match = re.search(r'time=([\d.]+)ms', output, re.IGNORECASE)
                if time_match:
                    response_time_ms = round(float(time_match.group(1)))
                    detail = f"avg response time: {response_time_ms}ms"
    except Exception:
        pass

    return {"status": "up", "response_time_ms": response_time_ms, "detail": detail, "timestamp_utc": _now()}


def _tcp_connect_once(host: str, port: int, timeout_s: float) -> dict:
    """Fallback probe: raw TCP connect to `port`. Used when ICMP fails/is blocked."""
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout_s):
            elapsed_ms = round((time.monotonic() - start) * 1000)
            return {
                "status": "up",
                "response_time_ms": elapsed_ms,
                "detail": f"TCP connect ok (port {port}, ICMP unavailable)",
                "timestamp_utc": _now(),
            }
    except Exception as e:
        return {"status": "down", "response_time_ms": 0, "detail": f"TCP connect failed: {e}", "timestamp_utc": _now()}


def check(host: str, timeout_ms: int, port: int = 0) -> dict:
    """
    Check if a machine is alive. Primary probe is ICMP ping to its Tailscale
    MagicDNS name or IP; if ping fails and `port` is given (non-zero), falls
    back to a TCP connect on that port. Each probe (ping, and TCP fallback if
    used) gets one retry before the host is declared down, to ride out a single
    bad poll cycle on lossy/relayed connections.

    Returns a host-level result dict:
      status: "up" | "down"
      response_time_ms: probe RTT in milliseconds
      detail: how the host was determined up/down
    """
    timeout_s = timeout_ms / 1000

    for attempt in range(2):
        ping_result = _ping_once(host, timeout_s)
        if ping_result["status"] == "up":
            return ping_result

        if port:
            tcp_result = _tcp_connect_once(host, port, timeout_s)
            if tcp_result["status"] == "up":
                return tcp_result

    return ping_result
