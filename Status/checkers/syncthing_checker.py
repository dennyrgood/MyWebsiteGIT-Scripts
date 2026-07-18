"""
checkers/syncthing_checker.py — Syncthing sync status check (Layer 2 API)
Returns standard service result with detail string.

CHANGELOG:
  2026-07-18: Failed items ("pull errors") no longer force the whole service
              DOWN. They now warn (service stays UP, "⚠ N failed item(s)" in
              detail) until the total across folders exceeds
              FAILED_ITEMS_DOWN_THRESHOLD, then escalate to DOWN. Genuine folder
              state=="error" and connection loss still go DOWN immediately.
              ^ If this line is absent, this box is running the OLD version.
"""

import time
import requests
from datetime import datetime, timezone

try:
    from requests.exceptions import ConnectionError as RequestsConnectionError
    from requests.exceptions import ConnectTimeout
except ImportError:
    RequestsConnectionError = object
    ConnectTimeout = object

# Failed items ("pull errors") on otherwise-idle folders are usually benign and
# transient (locked / permission-denied / deleted-on-one-side files), so a few
# are surfaced as a warning while the service stays UP. But if the total across
# all folders climbs past this threshold, something is genuinely wrong (a whole
# folder unwritable, a bad mount) and the service is escalated to DOWN.
FAILED_ITEMS_DOWN_THRESHOLD = 5


def check(tailscale_name: str, port: int, timeout_ms: int) -> dict:
    """
    Check Syncthing sync status on tailscale_name:port.

    Detail strings (up / idle):
        "Synced • 3 folders • v1.27.0 • ↑ 0 B/s ↓ 0 B/s"

    Detail strings (up / actively syncing):
        "Syncing • 2 folder(s) active • 42 items • 128.3 MB remaining • ↑ 2.1 MB/s ↓ 0 B/s"

    Detail strings (down / hard errors only):
        "Connection error to http://surface3-gc:8384"
        "Connection timeout"
        "HTTP 403 — check api_key in SYNCTHING_CONFIG"
        "ERROR • Folder 'docs' error state • 2 pull error(s) in 'docs'"
    """
    start_time = time.monotonic()

    from config import SYNCTHING_CONFIG

    machine_config = SYNCTHING_CONFIG.get(tailscale_name)

    if not machine_config:
        elapsed = round((time.monotonic() - start_time) * 1000)
        return _result(
            status="up",
            response_time_ms=elapsed,
            detail=f"No Syncthing config for {tailscale_name}",
            timestamp=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )

    syncthing_url = machine_config.get("syncthing_url", "").rstrip("/")
    api_key       = machine_config.get("api_key", "").strip()
    headers       = {"X-API-Key": api_key}
    timeout       = timeout_ms / 1000

    try:
        # 1. Liveness ping
        ping = requests.get(
            f"{syncthing_url}/rest/system/ping",
            headers=headers, timeout=timeout, verify=False,
        )
        ping.raise_for_status()
        if ping.json().get("ping") != "pong":
            raise RuntimeError("unexpected ping response")

        # 2. Version
        ver_resp = requests.get(
            f"{syncthing_url}/rest/system/version",
            headers=headers, timeout=timeout, verify=False,
        )
        ver_resp.raise_for_status()
        version = ver_resp.json().get("version", "?")

        # 3. Connections — total bandwidth
        conn_resp = requests.get(
            f"{syncthing_url}/rest/system/connections",
            headers=headers, timeout=timeout, verify=False,
        )
        conn_resp.raise_for_status()
        total  = conn_resp.json().get("total", {})
        in_bps = total.get("inBps",  0) or 0
        out_bps= total.get("outBps", 0) or 0
        bw     = f"↑ {_fmt_bps(out_bps)} ↓ {_fmt_bps(in_bps)}"

        # 4. Folder list from config
        cfg_resp = requests.get(
            f"{syncthing_url}/rest/config",
            headers=headers, timeout=timeout, verify=False,
        )
        cfg_resp.raise_for_status()
        cfg_folders = cfg_resp.json().get("folders", [])
        folder_ids  = [f["id"] for f in cfg_folders]
        # Human-readable label per folder id (falls back to the id itself)
        labels      = {f["id"]: (f.get("label") or f["id"]) for f in cfg_folders}

        # 5. Per-folder sync status
        total_need_files = 0
        total_need_bytes = 0
        active_folders   = 0   # folders currently syncing/scanning
        error_parts      = []  # hard errors only → status=down
        warn_parts       = []  # failed items / pull errors → up but noted
        total_pull_errs  = 0   # sum of pull errors across all folders

        for fid in folder_ids:
            db_resp = requests.get(
                f"{syncthing_url}/rest/db/status",
                headers=headers, params={"folder": fid},
                timeout=timeout, verify=False,
            )
            db_resp.raise_for_status()
            db    = db_resp.json()
            state = db.get("state", "unknown")
            nf    = db.get("needFiles",  0) or 0
            nb    = db.get("needBytes",  0) or 0
            pe    = db.get("pullErrors", 0) or 0

            total_need_files += nf
            total_need_bytes += nb

            if state in ("syncing", "scanning", "sync-preparing"):
                active_folders += 1
            # A folder stuck in the 'error' state is a genuine outage → down.
            if state == "error":
                error_parts.append(f"Folder '{labels[fid]}' error state")
            # Pull errors ("Failed Items") on an otherwise-idle folder are
            # usually benign/transient (locked/permission-denied/deleted files).
            # Surface them as a warning but DON'T take the whole service down.
            elif pe:
                total_pull_errs += pe
                warn_parts.append(
                    f"{pe} failed item{'s' if pe != 1 else ''} in '{labels[fid]}'"
                )

        elapsed = round((time.monotonic() - start_time) * 1000)
        now_z   = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        n       = len(folder_ids)
        warn    = "  ⚠ " + " • ".join(warn_parts) if warn_parts else ""

        # Hard errors (folder error state) → down
        if error_parts:
            return _result("down", elapsed,
                           "ERROR • " + " • ".join(error_parts) + warn, now_z)

        # Too many failed items across folders → escalate to down
        if total_pull_errs > FAILED_ITEMS_DOWN_THRESHOLD:
            return _result(
                "down", elapsed,
                f"ERROR • {total_pull_errs} failed items across folders"
                f" (threshold {FAILED_ITEMS_DOWN_THRESHOLD}){warn}",
                now_z,
            )

        # Actively syncing → up but show progress
        if active_folders > 0 or total_need_files > 0:
            mb     = total_need_bytes / 1_048_576
            detail = (
                f"Syncing • {active_folders or '?'} folder(s) active"
                f" • {total_need_files} items"
                f" • {mb:.1f} MB remaining"
                f" • {bw}{warn}"
            )
            return _result("up", elapsed, detail, now_z)

        # All idle and fully in sync (possibly with benign failed items)
        detail = f"Synced • {n} folder{'s' if n != 1 else ''} • {version} • {bw}{warn}"
        return _result("up", elapsed, detail, now_z)

    except ConnectTimeout:
        elapsed = round((time.monotonic() - start_time) * 1000)
        return _result("down", elapsed, "Connection timeout",
                       datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))

    except RequestsConnectionError:
        elapsed = round((time.monotonic() - start_time) * 1000)
        return _result("down", elapsed, f"Connection error to {syncthing_url}",
                       datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))

    except requests.exceptions.HTTPError as exc:
        elapsed = round((time.monotonic() - start_time) * 1000)
        code  = exc.response.status_code if exc.response is not None else "?"
        hint  = " — check api_key in SYNCTHING_CONFIG" if code == 403 else ""
        return _result("down", elapsed, f"HTTP {code}{hint}",
                       datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))

    except Exception as exc:
        elapsed = round((time.monotonic() - start_time) * 1000)
        return _result("down", elapsed, f"Syncthing error: {exc}",
                       datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))


def _fmt_bps(bps: float) -> str:
    """Format bytes/sec into a human-readable rate string."""
    if bps >= 1_048_576:
        return f"{bps / 1_048_576:.1f} MB/s"
    if bps >= 1_024:
        return f"{bps / 1_024:.1f} KB/s"
    return f"{int(bps)} B/s"


def _result(status: str, response_time_ms: int, detail: str, timestamp: str) -> dict:
    """Create standardized service check result."""
    return {
        "status":           status,
        "response_time_ms": response_time_ms,
        "detail":           detail if detail else None,
        "timestamp_utc":    timestamp,
    }


# ---------------------------------------------------------------------------
# main() — manual debug / standalone test
# ---------------------------------------------------------------------------

def main():
    import sys, os
    from pprint import pprint
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.dirname(script_dir)
    for p in (script_dir, parent_dir):
        if p not in sys.path:
            sys.path.insert(0, p)

    print("=" * 60)
    print("Syncthing Checker — Manual Debug Mode")
    print("=" * 60)

    if len(sys.argv) == 1:
        print("\nUsage: python syncthing_checker.py [machine_name] [port]\n")
        print("Examples:")
        print("  python syncthing_checker.py surface3-gc 8384")
        print("  python syncthing_checker.py mathes-mac-mini 8384")
        from config import SYNCTHING_CONFIG
        print("\nConfigured Syncthing targets:")
        for name, cfg in SYNCTHING_CONFIG.items():
            if cfg:
                url     = cfg.get("syncthing_url", "N/A")
                key     = cfg.get("api_key", "")
                has_key = "✓" if key and key.strip() else "✗ MISSING"
                preview = f"{key[:4]}…{key[-4:]}" if len(key) >= 8 else "(short?)"
                print(f"  • {name:25s}  {url}  key: {has_key} {preview}")
            else:
                print(f"  • {name:25s}  (no config — returns up/no-config)")
        return None

    machine_name = sys.argv[1]
    port         = int(sys.argv[2]) if len(sys.argv) > 2 else 8384
    timeout_ms   = 3000

    print(f"\nTesting: {machine_name}:{port}")
    print("-" * 60)

    result = None
    try:
        result = check(machine_name, port, timeout_ms)
        pprint(result)
        print("\n" + "=" * 60)
        if result["status"] == "up":
            print(f"Result: ✓ UP ({result['response_time_ms']}ms)")
            if result.get("detail"):
                print(f"Detail: {result['detail']}")
        else:
            print(f"Result: ✗ DOWN ({result['response_time_ms']}ms)")
            if result.get("detail"):
                print(f"Error : {result['detail']}")
        print("=" * 60)
    except Exception as exc:
        print(f"\nERROR: {exc}")
        import traceback
        traceback.print_exc()

    return result


if __name__ == "__main__":
    main()