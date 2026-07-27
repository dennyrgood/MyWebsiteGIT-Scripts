"""
checkers/http_checker.py — Generic HTTP GET checker
Used for Layer 2 (Tailscale service checks) and Layer 3 (public endpoint checks).
Any valid HTTP response = passing. Timeout or connection failure = failing.
Not used directly — called by service-specific checkers and the engine for public checks.

A single failed attempt (timeout, connection error, or 5xx) is retried once before
being reported as down — on relayed/mobile hosts (e.g. TravelBeast) a single HTTP
round-trip can occasionally exceed timeout_ms even though the service is healthy,
and service-specific checkers like comfyui_checker make multiple sequential calls
per check, compounding that risk.
"""

import urllib.request
import urllib.error
import time
from datetime import datetime, timezone


def _attempt(url: str, timeout_ms: int) -> dict:
    timeout_s = timeout_ms / 1000
    start = time.monotonic()
    status = "down"
    http_code = None
    detail = None
    raw_body = None

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FleetChecker/1.0"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            http_code = resp.status
            raw_body = resp.read(4096)  # read up to 4KB for JSON parsing
            status = "up"

    except urllib.error.HTTPError as e:
        # HTTPError means server responded — still alive
        http_code = e.code
        status = "up"
        if http_code >= 500:
            status = "down"
            detail = f"HTTP {http_code}"
        else:
            detail = f"HTTP {http_code}"
        try:
            raw_body = e.read(4096)
        except Exception:
            pass

    except urllib.error.URLError as e:
        reason = str(e.reason)
        if "timed out" in reason.lower() or "timeout" in reason.lower():
            detail = "Connection timeout"
        elif "name or service not known" in reason.lower() or "nodename" in reason.lower():
            detail = "DNS resolution failed"
        else:
            detail = f"Connection error: {reason}"

    except TimeoutError:
        detail = "Connection timeout"

    except Exception as e:
        detail = f"Unexpected error: {e}"

    elapsed_ms = round((time.monotonic() - start) * 1000)

    return {
        "status": status,
        "http_code": http_code,
        "response_time_ms": elapsed_ms,
        "detail": detail,
        "timestamp_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "raw_body": raw_body,
    }


def get(url: str, timeout_ms: int) -> dict:
    """
    Perform an HTTP GET to url, retrying once before reporting failure.
    Any HTTP response including 3xx, 4xx = passing (service is alive).
    Timeout, connection failure, or 5xx = failing on both attempts = failing.

    Returns:
        {
            "status": "up" | "down",
            "http_code": int | None,
            "response_time_ms": int,   # time of the attempt actually returned
            "detail": str | None,
            "timestamp_utc": str,
            "raw_body": bytes | None,   # available for callers that need to parse JSON
        }
    """
    result = _attempt(url, timeout_ms)
    if result["status"] == "up":
        return result
    return _attempt(url, timeout_ms)
