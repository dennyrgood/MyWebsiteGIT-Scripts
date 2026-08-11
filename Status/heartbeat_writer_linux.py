#!/usr/bin/env python3
# heartbeat_writer_linux.py — one-shot Linux heartbeat + machine info writer
# Created: 2026-06-28 UTC — Ubuntu equivalent of onedrive_heartbeat_writer_mac.py.
# Collects CPU/RAM/disk/OS metrics once, writes heartbeat_{host}.txt,
# machine_info_{host}.json, and appends one entry to metrics_history_{host}.json,
# then exits. Driven by cron via run_heartbeat.sh.
# Updated: 2026-06-28 UTC — add get_immich_stats(); writes immich_photos/immich_videos to machine_info
# Updated: 2026-06-28 UTC — get_immich_stats() accepts api_key; passes x-api-key header (stats endpoint requires auth)
# Updated: 2026-06-29 UTC — get_immich_stats() uses host param instead of localhost (Docker not bound to localhost on some machines)
# Updated: 2026-08-11 UTC — get_disks() also accepts /volume1 (FleetNAS's btrfs data volume mount)
# Updated: 2026-08-11 UTC — get_disks() skips zero-size mounts (e.g. UGREEN's /mnt/factory)

import argparse
import json
import re
import subprocess
import time
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

HISTORY_MAX_LINES = 120


def get_ram() -> tuple[float, float]:
    data = Path("/proc/meminfo").read_text()
    total_kb = int(re.search(r"MemTotal:\s+(\d+)", data).group(1))
    avail_kb = int(re.search(r"MemAvailable:\s+(\d+)", data).group(1))
    return round(total_kb / 1024 ** 2, 1), round((total_kb - avail_kb) / 1024 ** 2, 1)


def get_cpu_percent() -> float:
    def read_stat():
        vals = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:8]))
        return sum(vals), vals[3]
    t1, i1 = read_stat()
    time.sleep(1)
    t2, i2 = read_stat()
    dt = t2 - t1
    return round((1 - (i2 - i1) / dt) * 100, 1) if dt > 0 else 0.0


def get_disks() -> list[dict]:
    out = subprocess.check_output(["df", "-k"]).decode()
    disks = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6 or not parts[0].startswith("/dev/"):
            continue
        mount = parts[5]
        if mount != "/" and not any(mount.startswith(p) for p in ("/media/", "/mnt/", "/data", "/volume1")):
            continue
        total_kb, used_kb, free_kb = int(parts[1]), int(parts[2]), int(parts[3])
        if total_kb == 0:
            continue  # zero-size mounts (e.g. UGREEN's /mnt/factory) are noise, not disks
        disks.append({
            "drive":    mount,
            "total_gb": round(total_kb / 1024 ** 2, 1),
            "used_gb":  round(used_kb  / 1024 ** 2, 1),
            "free_gb":  round(free_kb  / 1024 ** 2, 1),
        })
    return disks


def get_last_reboot() -> str:
    try:
        secs = float(Path("/proc/uptime").read_text().split()[0])
        dt = datetime.now(timezone.utc) - timedelta(seconds=secs)
        return dt.strftime("%b %-d %H:%M")
    except Exception:
        return "unknown"


def get_os_info() -> tuple[str, str, str, bool]:
    last_wu_date = last_wu_kb = last_wu_reboot = "unknown"
    pending_reboot = Path("/var/run/reboot-required").exists()
    try:
        text = Path("/var/log/apt/history.log").read_text(errors="replace")
        entries = [e for e in re.split(r"\n(?=Start-Date:)", text.strip()) if e.strip()]
        if entries:
            last = entries[-1]
            m_date = re.search(r"Start-Date:\s+(.+)", last)
            m_cmd  = re.search(r"Commandline:\s+(.+)", last)
            if m_date:
                dt = datetime.strptime(m_date.group(1).strip(), "%Y-%m-%d  %H:%M:%S")
                last_wu_date = last_wu_reboot = dt.strftime("%b %-d %H:%M")
            if m_cmd:
                last_wu_kb = m_cmd.group(1).strip()[:60]
    except Exception:
        pass
    return last_wu_date, last_wu_kb, last_wu_reboot, pending_reboot


def get_immich_stats(host: str = "localhost", port: int = 2283, api_key: str = "") -> tuple[int | None, int | None]:
    try:
        url = f"http://{host}:{port}/api/server/statistics"
        req = urllib.request.Request(url)
        if api_key:
            req.add_header("x-api-key", api_key)
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            return data.get("photos"), data.get("videos")
    except Exception:
        return None, None


def get_os_build() -> str:
    try:
        data = Path("/etc/os-release").read_text()
        m = re.search(r'PRETTY_NAME="([^"]+)"', data)
        return m.group(1) if m else "unknown"
    except Exception:
        return "unknown"


def run(host: str, output_dir: Path, immich_api_key: str = "") -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    ram_total, ram_used = get_ram()
    cpu = get_cpu_percent()
    disks = get_disks()
    last_reboot = get_last_reboot()
    last_wu_date, last_wu_kb, last_wu_reboot, pending_reboot = get_os_info()
    os_build = get_os_build()
    immich_photos, immich_videos = get_immich_stats(host=host, api_key=immich_api_key)

    (output_dir / f"heartbeat_{host}.txt").write_text(
        datetime.now(timezone.utc).isoformat(), encoding="utf-8"
    )

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
        "immich_photos":  immich_photos,
        "immich_videos":  immich_videos,
    }
    (output_dir / f"machine_info_{host}.json").write_text(
        json.dumps(info, indent=4), encoding="utf-8"
    )

    ram_pct = round(ram_used / ram_total * 100) if ram_total > 0 else None
    entry = json.dumps({
        "ts": ts, "ram_pct": ram_pct, "cpu_pct": round(cpu),
        "vram_pct": None, "gpu_pct": None,
    }, separators=(",", ":"))
    history_file = output_dir / f"metrics_history_{host}.json"
    existing = history_file.read_text(encoding="utf-8").splitlines() if history_file.exists() else []
    history_file.write_text("\n".join((existing + [entry])[-HISTORY_MAX_LINES:]) + "\n", encoding="utf-8")

    print(f"[{ts}] heartbeat + machine_info + history written for {host} -> {output_dir}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--host",           required=True)
    ap.add_argument("--output-dir",     required=True)
    ap.add_argument("--immich-api-key", default="")
    args = ap.parse_args()
    run(args.host, Path(args.output_dir), immich_api_key=args.immich_api_key)
