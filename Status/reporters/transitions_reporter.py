"""
reporters/transitions_reporter.py — status transition log
Diffs each cycle's assembled state against the previous cycle's (in-memory, per
checker-process) and appends a JSONL line for every host/service status change.
See Status/SPEC_status_transitions_log.md (Part B) for background.
Standard interface: report(state, status_dir, checker_host) — called by engine
after every poll cycle, same signature as json_reporter.report().
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

TRANSITIONS_FILENAME = "status_transitions.jsonl"
MAX_LINES = 1000

# Previous cycle's {tailscale_name: {"host": status, "services": {name: status}}},
# keyed by checker_host. Module-level so it persists across calls within one
# checker process's lifetime, resets on restart (acceptable — see spec).
_previous_state: dict[str, dict] = {}


def report(state: dict, status_dir: Path, checker_host: str) -> None:
    """Diff state against the previous cycle and append any transitions."""
    prev = _previous_state.get(checker_host)
    current = {}
    transitions = []

    for machine in state.get("machines", []):
        tailscale_name = machine["machine"]["tailscale_name"]
        host_status = machine["host"]["status"]
        host_detail = machine["host"].get("detail")

        current[tailscale_name] = {
            "host": host_status,
            "services": {},
        }

        if prev is not None:
            prev_machine = prev.get(tailscale_name)
            if prev_machine is not None and prev_machine["host"] != host_status:
                transitions.append({
                    "ts": state.get("meta", {}).get("timestamp_utc"),
                    "scope": "host",
                    "host": tailscale_name,
                    "service": None,
                    "from": prev_machine["host"],
                    "to": host_status,
                    "detail": host_detail,
                })

        for svc in machine.get("services", []):
            svc_name = svc["name"]
            svc_status = svc["tailscale_check"]["status"]
            svc_detail = svc["tailscale_check"].get("detail")

            current[tailscale_name]["services"][svc_name] = svc_status

            if prev is not None:
                prev_machine = prev.get(tailscale_name)
                if prev_machine is not None:
                    prev_svc_status = prev_machine["services"].get(svc_name)
                    if prev_svc_status is not None and prev_svc_status != svc_status:
                        transitions.append({
                            "ts": state.get("meta", {}).get("timestamp_utc"),
                            "scope": "service",
                            "host": tailscale_name,
                            "service": svc_name,
                            "from": prev_svc_status,
                            "to": svc_status,
                            "detail": svc_detail,
                        })

    _previous_state[checker_host] = current

    if transitions:
        _append_transitions(status_dir / TRANSITIONS_FILENAME, transitions)


def _append_transitions(path: Path, transitions: list) -> None:
    """Append transition lines, then trim the file to the last MAX_LINES entries."""
    try:
        with path.open("a", encoding="utf-8") as f:
            for t in transitions:
                f.write(json.dumps(t, default=str) + "\n")
    except OSError as e:
        logger.error("Failed to append transitions to %s: %s", path, e)
        return

    _trim(path)


def _trim(path: Path) -> None:
    """Keep only the last MAX_LINES lines, written atomically."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        logger.error("Failed to read %s for trim: %s", path, e)
        return

    if len(lines) <= MAX_LINES:
        return

    trimmed = lines[-MAX_LINES:]
    tmp_path = path.with_suffix(".tmp")
    try:
        tmp_path.write_text("\n".join(trimmed) + "\n", encoding="utf-8")
        tmp_path.replace(path)
    except OSError as e:
        logger.error("Failed to write trimmed %s: %s", path, e)
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
