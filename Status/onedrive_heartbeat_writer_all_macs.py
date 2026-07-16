#!/usr/bin/env python3
"""
onedrive_heartbeat_writer_all_macs.py — macOS heartbeat + machine info + metrics history writer
Writes heartbeat_{host}.txt, machine_info_{host}.json, and metrics_history_{host}.json
to OneDrive _sync_monitor/{host}/
Main loop: 150s (every 5th 30s tick) — heartbeat + machine_info
History:   every 30s tick

Self-identifies via socket.gethostname() mapped through HOSTNAME_MAP, so the
same file runs unmodified on any of the three Macs instead of needing a
per-machine copy with a hardcoded HOST constant.

Created: 2026-06-15 23:00 UTC
Updated: 2026-06-16 14:12 UTC — add metrics_history append/trim on 30s tick; single loop with counter
Updated: 2026-07-10 UTC — consolidate mac.py/macMM.py/macMBA2.py into one hostname-aware script
"""

import json
import os
import re
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────

# Maps each Mac's raw socket.gethostname() to the canonical fleet host name
# already used as the OneDrive _sync_monitor/{host}/ directory name.
HOSTNAME_MAP = {
    "Denniss-MacBook-Air.local": "denniss-macbook-air",
    "Denniss-2ndMBA":            "denniss-2nd-macbook-air",
    # mb2 renamed 2026-07-16 to match its tailnet name (fixes Ollama's
    # DNS-rebinding 403 on hostname URLs); cover both raw spellings.
    "denniss-2nd-macbook-air.local": "denniss-2nd-macbook-air",
    "Mathes-Mac-mini.local":     "mathes-mac-mini",
}
HOST = HOSTNAME_MAP.get(socket.gethostname(), socket.gethostname())

TICK_SECONDS       = 30
MACHINE_INFO_EVERY = 5   # ticks — 5 × 30s = 150s
HISTORY_MAX_LINES  = 120

ONEDRIVE_PATH = Path.home() / "OneDrive"
OUTPUT_DIR    = ONEDRIVE_PATH / "_sync_monitor" / HOST


# ── Data collection ────────────────────────────────────────────

def get_ram() -> tuple[float, float]:
    """Returns (ram_total_gb, ram_used_gb) matching Activity Monitor methodology."""
    out = subprocess.check_output(["sysctl", "-n", "hw.memsize"]).decode().strip()
    total_bytes = int(out)
    total_gb = round(total_bytes / (1024 ** 3), 1)

    vm = subprocess.check_output(["vm_stat"]).decode()

    m = re.search(r"page size of (\d+) bytes", vm)
    page_size = int(m.group(1)) if m else 16384

    def pages(label):
        m = re.search(rf"{label}:\s+(\d+)", vm)
        return int(m.group(1)) if m else 0

    active     = pages("Pages active")
    wired      = pages("Pages wired down")
    compressor = pages("Pages occupied by compressor")
    used_bytes = (active + wired + compressor) * page_size
    used_gb = round(used_bytes / (1024 ** 3), 1)
    return total_gb, used_gb


def get_cpu_percent() -> float:
    """Returns CPU usage percent (1-second sample via top)."""
    try:
        out = subprocess.check_output(
            ["top", "-l", "2", "-n", "0", "-s", "1"],
            stderr=subprocess.DEVNULL
        ).decode()
        matches = re.findall(r"CPU usage:\s+([\d.]+)%\s+user,\s+([\d.]+)%\s+sys", out)
        if matches:
            user, sys_ = matches[-1]
            return round(float(user) + float(sys_), 1)
    except Exception:
        pass
    return 0.0


def get_disks() -> list[dict]:
    """Returns list of disk dicts. Includes /, /System/Volumes/Data, /Volumes/*."""
    out = subprocess.check_output(["df", "-g"]).decode()
    disks = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        filesystem = parts[0]
        if not filesystem.startswith("/dev/"):
            continue
        mount = parts[8]
        if mount not in ("/", "/System/Volumes/Data") and not mount.startswith("/Volumes/"):
            continue
        total_gb = float(parts[1])
        used_gb  = float(parts[2])
        free_gb  = float(parts[3])
        disks.append({
            "drive":    mount,
            "total_gb": round(total_gb, 1),
            "used_gb":  round(used_gb, 1),
            "free_gb":  round(free_gb, 1),
        })
    return disks


def get_last_reboot() -> str:
    """Returns last reboot as 'Mon DD HH:MM' string."""
    try:
        out = subprocess.check_output(["sysctl", "-n", "kern.boottime"]).decode()
        m = re.search(r"\}\s+(.+)$", out.strip())
        if m:
            dt = datetime.strptime(m.group(1).strip(), "%a %b %d %H:%M:%S %Y")
            return dt.strftime("%b %-d %H:%M")
    except Exception:
        pass
    return "unknown"


def get_os_info() -> tuple[str, str, str, bool]:
    """Returns (last_wu_date, last_wu_kb, last_wu_reboot, pending_reboot)."""
    last_wu_date   = "unknown"
    last_wu_kb     = "unknown"
    last_wu_reboot = "unknown"
    pending_reboot = False

    try:
        out = subprocess.check_output(
            ["softwareupdate", "--history"],
            stderr=subprocess.DEVNULL
        ).decode()
        os_lines = [l for l in out.splitlines() if l.strip().startswith("macOS ")]
        if os_lines:
            last = os_lines[-1]
            m = re.match(r"(macOS\s+\S+\s+[\d.]+)\s+[\d.]+\s+(\d{2}/\d{2}/\d{4}),\s+([\d:]+)", last)
            if m:
                last_wu_kb = m.group(1).strip()
                dt = datetime.strptime(f"{m.group(2)} {m.group(3)}", "%m/%d/%Y %H:%M:%S")
                last_wu_date   = dt.strftime("%b %-d %H:%M")
                last_wu_reboot = last_wu_date
    except Exception:
        pass

    try:
        out = subprocess.check_output(
            ["softwareupdate", "-l"],
            stderr=subprocess.STDOUT
        ).decode()
        if "restart" in out.lower() or "recommended" in out.lower():
            pending_reboot = True
    except Exception:
        pass

    return last_wu_date, last_wu_kb, last_wu_reboot, pending_reboot


def get_os_build() -> str:
    try:
        product = subprocess.check_output(["sw_vers", "-productVersion"]).decode().strip()
        build   = subprocess.check_output(["sw_vers", "-buildVersion"]).decode().strip()
        return f"{product} ({build})"
    except Exception:
        return "unknown"


# ── Write functions ────────────────────────────────────────────

def write_heartbeat(output_dir: Path, host: str):
    ts = datetime.now(timezone.utc).isoformat()
    hb_file = output_dir / f"heartbeat_{host}.txt"
    hb_file.write_text(ts, encoding="utf-8")


def write_machine_info(output_dir: Path, host: str):
    ram_total, ram_used = get_ram()
    cpu  = get_cpu_percent()
    disks = get_disks()
    last_reboot = get_last_reboot()
    last_wu_date, last_wu_kb, last_wu_reboot, pending_reboot = get_os_info()
    os_build = get_os_build()
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    info = {
        "host":           host,
        "timestamp_utc":  ts,
        "ram_total_gb":   ram_total,
        "ram_used_gb":    ram_used,
        "cpu_percent":    cpu,
        "disks":          disks,
        "last_reboot":    last_reboot,
        "last_wu_date":   last_wu_date,
        "last_wu_kb":     last_wu_kb,
        "last_wu_reboot": last_wu_reboot,
        "os_build":       os_build,
        "pending_reboot": pending_reboot,
    }

    info_file = output_dir / f"machine_info_{host}.json"
    info_file.write_text(json.dumps(info, indent=4), encoding="utf-8")


def write_history_entry(output_dir: Path, host: str):
    """Appends one JSON line to metrics_history_{host}.json and trims to HISTORY_MAX_LINES."""
    try:
        ram_total, ram_used = get_ram()
        ram_pct = round(ram_used / ram_total * 100) if ram_total > 0 else None

        cpu_pct = get_cpu_percent()
        cpu_pct = round(cpu_pct) if cpu_pct is not None else None

        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        entry = json.dumps({
            "ts":       ts,
            "ram_pct":  ram_pct,
            "cpu_pct":  cpu_pct,
            "vram_pct": None,   # No GPU on Macs
            "gpu_pct":  None,
        }, separators=(",", ":"))

        history_file = output_dir / f"metrics_history_{host}.json"

        existing = []
        if history_file.exists():
            existing = history_file.read_text(encoding="utf-8").splitlines()

        all_lines = existing + [entry]
        trimmed   = all_lines[-HISTORY_MAX_LINES:]

        history_file.write_text("\n".join(trimmed) + "\n", encoding="utf-8")

    except Exception as e:
        print(f"[{datetime.now(timezone.utc).isoformat()}] history write ERROR: {e}")


# ── Main loop ──────────────────────────────────────────────────
# Tick every 30s. Every 5th tick also writes heartbeat + machine_info.

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"[{datetime.now(timezone.utc).isoformat()}] Starting writer for {HOST}")
    print(f"  Raw hostname: {socket.gethostname()}")
    print(f"  Output dir: {OUTPUT_DIR}")
    print(f"  History tick: {TICK_SECONDS}s — machine_info every {MACHINE_INFO_EVERY} ticks ({TICK_SECONDS * MACHINE_INFO_EVERY}s)")

    tick_count = 0

    while True:
        try:
            # Always write history entry
            write_history_entry(OUTPUT_DIR, HOST)

            # Every 5th tick: write heartbeat + machine_info
            if tick_count % MACHINE_INFO_EVERY == 0:
                write_heartbeat(OUTPUT_DIR, HOST)
                write_machine_info(OUTPUT_DIR, HOST)
                print(f"[{datetime.now(timezone.utc).isoformat()}] machine_info + heartbeat written (tick {tick_count})")
            else:
                print(f"[{datetime.now(timezone.utc).isoformat()}] history written (tick {tick_count})")

        except Exception as e:
            print(f"[{datetime.now(timezone.utc).isoformat()}] ERROR: {e}")

        tick_count += 1
        time.sleep(TICK_SECONDS)


if __name__ == "__main__":
    main()
