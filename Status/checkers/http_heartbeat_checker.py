"""
checkers/http_heartbeat_checker.py — writer-liveness check over Tailscale HTTP.

Replaces onedrive_heartbeat_checker: fetches heartbeat_{target_host}.txt from the target
machine's fleet_metrics_server (port FLEET_METRICS_PORT, default 9100) instead of reading
an OneDrive-synced file. Because the fetch is live, a "stale" reading now means the writer
process actually stopped — not that a sync lagged.

Stale threshold: 5 minutes.
Created: 2026-07-17
"""

import os
import urllib.request
from datetime import datetime, timezone, timedelta

DEFAULT_STALE_THRESHOLD_MINUTES = 5
METRICS_PORT = int(os.environ.get("FLEET_METRICS_PORT", "9100"))


def check(tailscale_name: str, port: int, timeout_ms: int, **kwargs) -> dict:
    """
    Fetch the target host's heartbeat over Tailscale HTTP and judge freshness.

    kwargs:
        target_host (str): tailscale name of the machine whose heartbeat to check.
    """
    start = datetime.now(timezone.utc)

    def _now_iso() -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    def _elapsed_ms() -> int:
        return round((datetime.now(timezone.utc) - start).total_seconds() * 1000)

    target_host = kwargs.get("target_host")
    if not target_host:
        return {
            "status": "down",
            "response_time_ms": _elapsed_ms(),
            "detail": f"Missing 'target_host' parameter — check service config for {tailscale_name}",
            "timestamp_utc": _now_iso(),
        }

    url = f"http://{target_host}:{METRICS_PORT}/heartbeat_{target_host}.txt"
    timeout_s = (timeout_ms / 1000) if timeout_ms else 3

    try:
        with urllib.request.urlopen(url, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8-sig").strip()
    except Exception as e:
        return {
            "status": "down",
            "response_time_ms": _elapsed_ms(),
            "detail": f"Fetch error from {url}: {e}",
            "timestamp_utc": _now_iso(),
        }

    if not raw:
        return {
            "status": "down",
            "response_time_ms": _elapsed_ms(),
            "detail": "Empty heartbeat — writer may have crashed",
            "timestamp_utc": _now_iso(),
        }

    try:
        server_time = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if server_time.tzinfo is None:
            server_time = server_time.replace(tzinfo=timezone.utc)
    except Exception as e:
        return {
            "status": "down",
            "response_time_ms": _elapsed_ms(),
            "detail": f"Parse error: invalid timestamp '{raw[:20]}' — {e}",
            "timestamp_utc": _now_iso(),
        }

    age = datetime.now(timezone.utc) - server_time
    age_seconds = int(age.total_seconds())

    if age > timedelta(minutes=DEFAULT_STALE_THRESHOLD_MINUTES):
        return {
            "status": "down",
            "response_time_ms": _elapsed_ms(),
            "detail": f"Stale: {age_seconds / 60:.1f} min old on {target_host}, threshold {DEFAULT_STALE_THRESHOLD_MINUTES} min",
            "timestamp_utc": _now_iso(),
        }

    return {
        "status": "up",
        "response_time_ms": _elapsed_ms(),
        "detail": f"{age_seconds} sec old on {target_host}",
        "timestamp_utc": _now_iso(),
    }


if __name__ == "__main__":
    import argparse
    import json

    ap = argparse.ArgumentParser(description="HTTP heartbeat checker (standalone test)")
    ap.add_argument("--target", required=True, help="Target host, e.g. amsterdamdesktop")
    args = ap.parse_args()

    print(json.dumps(check("test", 0, 3000, target_host=args.target), indent=2))
