"""
reporters/json_reporter.py — JSON file reporter
Receives completed state from the engine.
Writes one JSON file per machine + one master JSON file to the local STATUS_DIR.
Also writes an append-only log file per checker instance.
Standard interface: report(state) — called by engine after every poll cycle.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)


def report(state: dict, status_dir: Path, checker_host: str) -> None:
    """
    Write all status JSON files to status_dir.

    state structure (assembled by engine):
        {
            "meta": {...},
            "summary": {...},
            "machines": [ per-machine dicts ]
        }
    """
    status_dir.mkdir(parents=True, exist_ok=True)

    # --- Write per-machine files ---
    for machine in state.get("machines", []):
        tailscale_name = machine["machine"]["tailscale_name"]
        filename = f"server_status_{tailscale_name}.json"
        _write_json(status_dir / filename, machine)

    # --- Write master file ---
    _write_json(status_dir / "server_status_all.json", state)

    # --- Append to checker log ---
    log_file = status_dir / f"checker_{checker_host}.log"
    _append_log(log_file, state)


def _write_json(path: Path, data: dict) -> None:
    """Atomically write JSON to path using a temp file."""
    tmp_path = path.with_suffix(".tmp")
    try:
        tmp_path.write_text(
            json.dumps(data, indent=2, default=str),
            encoding="utf-8",
        )
        tmp_path.replace(path)
    except OSError as e:
        logger.error("Failed to write %s: %s", path, e)
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass


def _append_log(log_path: Path, state: dict) -> None:
    """Append a one-line summary entry to the checker log."""
    meta = state.get("meta", {})
    summary = state.get("summary", {})

    timestamp = meta.get("timestamp_utc", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    machines_up = summary.get("machines_up", "?")
    machines_total = summary.get("machines_total", "?")
    services_up = summary.get("services_up", "?")
    services_total = summary.get("services_total", "?")
    public_up = summary.get("public_endpoints_up", "?")
    public_total = summary.get("public_endpoints_total", "?")

    line = (
        f"{timestamp} | "
        f"machines {machines_up}/{machines_total} | "
        f"services {services_up}/{services_total} | "
        f"public {public_up}/{public_total}\n"
    )

    try:
        with log_path.open("a", encoding="utf-8") as f:
            f.write(line)
    except OSError as e:
        logger.error("Failed to write log %s: %s", log_path, e)
