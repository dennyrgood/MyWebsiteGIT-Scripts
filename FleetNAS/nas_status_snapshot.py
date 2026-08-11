#!/usr/bin/env python3
"""
nas_status_snapshot.py — merge FleetNAS-specific health data into machine_info.

Created: 2026-08-11 UTC. Reads the same three signals nas-health-monitor.sh
already alerts on (SMART per drive, RAID array state, UPS/NUT), reduces them
to a compact summary, and merges it under machine_info["nas"] so the fleet
dashboard tile can show it — without duplicating nas-health-monitor.sh's
alert/streak/email logic, which stays the source of truth for actual alerts.
This script only ever reports current state; it has no memory between runs.

Deliberately NOT merged into Status/heartbeat_writer_linux.py — that file is
shared with WBU/CWHU and has no business knowing about SMART drives or NUT.

Run by run_heartbeat_nas.sh, after heartbeat_writer_linux.py has written
machine_info_{host}.json — this script loads it, adds the "nas" key, and
rewrites it. Needs root (smartctl/mdadm), same as nas-health-monitor.sh;
both run from root's crontab.

Reuses the same "unreadable is not healthy" principle as nas-health-monitor.sh
(see its header/gotchas): a failed SMART/RAID/UPS read is reported as
"unreadable", never silently coerced into "ok".
"""

import argparse
import json
import re
import subprocess
from pathlib import Path

DRIVES = ("sda", "sdb", "sdc")
SMARTCTL = "/sbin/smartctl"
MDADM = "/sbin/mdadm"
RAID_DEV = "/dev/md1"
UPS_NAME = "ups0"
UPS_HOST = "localhost"


def read_smart(drive: str) -> dict:
    """Mirrors nas-health-monitor.sh's read_smart(): rc bit 2 = truly unreadable;
    these WD80EFPX drives always set bit 4 on perfectly healthy data, so a
    nonzero rc alone must not mean unreadable."""
    try:
        proc = subprocess.run([SMARTCTL, "-H", "-A", f"/dev/{drive}"],
                               capture_output=True, text=True, timeout=15)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"state": "unreadable"}

    if proc.returncode & 2:
        return {"state": "unreadable"}

    out = proc.stdout
    health_m = re.search(r"SMART overall-health.*:\s*(\S+)", out)
    realloc_m = re.search(r"Reallocated_Sector_Ct\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out) \
        or re.search(r"^\s*5\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out, re.MULTILINE)
    pending_m = re.search(r"Current_Pending_Sector\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out) \
        or re.search(r"^\s*197\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out, re.MULTILINE)
    temp_m = re.search(r"Temperature_(?:Celsius|Internal)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out) \
        or re.search(r"Airflow_Temperature_Cel\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", out)

    if not (health_m and realloc_m and pending_m and temp_m):
        return {"state": "unreadable"}

    return {
        "state": "ok",
        "health": health_m.group(1),
        "realloc": int(realloc_m.group(1)),
        "pending": int(pending_m.group(1)),
        "temp_c": int(temp_m.group(1)),
    }


def get_smart_summary() -> dict:
    per_drive = {d: read_smart(d) for d in DRIVES}
    unreadable = [d for d, v in per_drive.items() if v["state"] == "unreadable"]
    failing = [d for d, v in per_drive.items()
               if v["state"] == "ok" and (v["health"] != "PASSED" or v["realloc"] > 0 or v["pending"] > 0)]
    if unreadable:
        status = "unreadable"
    elif failing:
        status = "failing"
    else:
        status = "healthy"
    temps = [v["temp_c"] for v in per_drive.values() if v["state"] == "ok"]
    return {
        "status": status,
        "max_temp_c": max(temps) if temps else None,
        "unreadable_drives": unreadable,
        "failing_drives": failing,
    }


def get_raid_state() -> dict:
    try:
        # No sudo prefix: this script is already run as root by root's cron
        # (same as nas-health-monitor.sh, which does use sudo — but that one
        # is designed to also be runnable un-sudo'd for manual testing).
        proc = subprocess.run([MDADM, "--detail", RAID_DEV],
                               capture_output=True, text=True, timeout=15)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"state": "unreadable"}

    out = proc.stdout
    if not out.strip():
        return {"state": "unreadable"}

    m = re.search(r"State\s*:\s*(.+)", out)
    if not m:
        return {"state": "unreadable"}
    state = m.group(1).strip()

    pct = None
    pm = re.search(r"Rebuild Status\s*:\s*(\d+)%", out)
    if pm:
        pct = int(pm.group(1))

    return {"state": state, "rebuild_pct": pct}


def get_ups_status() -> dict:
    try:
        proc = subprocess.run(["upsc", f"{UPS_NAME}@{UPS_HOST}"],
                               capture_output=True, text=True, timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"status": None, "charge_pct": None}

    out = proc.stdout
    status_m = re.search(r"^ups\.status:\s*(.+)$", out, re.MULTILINE)
    charge_m = re.search(r"^battery\.charge:\s*(\d+)", out, re.MULTILINE)
    return {
        "status": status_m.group(1).strip() if status_m else None,
        "charge_pct": int(charge_m.group(1)) if charge_m else None,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine-info-file", required=True)
    args = ap.parse_args()

    path = Path(args.machine_info_file)
    info = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}

    info["nas"] = {
        "smart": get_smart_summary(),
        "raid": get_raid_state(),
        "ups": get_ups_status(),
    }

    path.write_text(json.dumps(info, indent=4), encoding="utf-8")
    print(f"nas status merged into {path}")


if __name__ == "__main__":
    main()
