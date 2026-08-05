#!/Library/Frameworks/Python.framework/Versions/3.13/bin/python3
"""
heartbeat_checker_macos.py
Run as a Login Item — loops forever, checks every 5 minutes.
Runs in your full user session so Finder dialogs work reliably.

See setup instructions at the bottom.
"""

import subprocess
import socket
import time
from pathlib import Path
from datetime import datetime, timedelta, timezone

# ── CONFIG ────────────────────────────────────────────────────────────────────

ONEDRIVE_PATH   = Path.home() / "OneDrive"
HEARTBEAT_FILE  = ONEDRIVE_PATH / "_sync_monitor" / "heartbeat_server.txt"
STALE_THRESHOLD      = 5    # minutes
CHECK_INTERVAL       = 300  # seconds (5 minutes)
TERMINAL_NOTIFIER    = "/opt/homebrew/bin/terminal-notifier"  # full path required for Login Item context

# ── HELPERS ───────────────────────────────────────────────────────────────────

def is_online() -> bool:
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "3", "8.8.8.8"],
            capture_output=True, timeout=5
        )
        return result.returncode == 0
    except Exception:
        return False


def notify(title: str, message: str) -> None:
    try:
        subprocess.run(
            [TERMINAL_NOTIFIER,
             "-title", title,
             "-message", message,
             "-sound", "Basso",
             "-ignoreDnD",
             "-sender", "com.apple.Terminal",
             "-group", str(int(datetime.now(timezone.utc).timestamp()))],
            timeout=5
        )
    except FileNotFoundError:
        # Fallback if terminal-notifier not found
        safe_title = title.replace('"', '\\"')
        safe_msg   = message.replace('"', '\\"')
        subprocess.run([
            "osascript", "-e",
            f'display notification "{safe_msg}" with title "{safe_title}" sound name "Basso"'
        ])


def check():
    if not is_online():
        return

    machine = socket.gethostname()

    if not HEARTBEAT_FILE.exists():
        notify("⚠️ OneDrive Sync Problem",
               f"Heartbeat file not found on {machine}.\nOneDrive may not be syncing.")
        return

    raw = HEARTBEAT_FILE.read_text().strip()
    if not raw:
        notify("⚠️ OneDrive Heartbeat Empty",
               f"Heartbeat file is empty on {machine}.\nServer writer may not be running.")
        return

    try:
        server_time = datetime.fromisoformat(raw)
        if server_time.tzinfo is None:
            server_time = server_time.replace(tzinfo=timezone.utc)
    except Exception as e:
        notify("⚠️ OneDrive Monitor Error", f"Could not parse timestamp.\nError: {e}")
        return

    age      = datetime.now(timezone.utc) - server_time
    age_mins = int(age.total_seconds() / 60)

    if age > timedelta(minutes=STALE_THRESHOLD):
        notify("⚠️ OneDrive Sync Appears Stuck",
               f"Heartbeat is {age_mins} min old on {machine}.\n"
               f"Last server write: {server_time.strftime('%H:%M:%S')} UTC")


# ── LOOP ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    while True:
        check()
        time.sleep(CHECK_INTERVAL)


# ══════════════════════════════════════════════════════════════════════════════
# SETUP AS A LOGIN ITEM
# ══════════════════════════════════════════════════════════════════════════════
#
# macOS won't add a .py directly as a login item, so wrap it in an app:
#
# 1. Open Script Editor (Applications → Utilities → Script Editor)
#
# 2. Paste this ONE line (edit the path):
#
#    do shell script "/usr/bin/python3 /Users/YOURUSERNAME/repos/scripts/onedrive_heartbeat_checker_macos.py"
#
# 3. File → Export
#      File Format: Application
#      Save as: OneDriveMonitor.app  (anywhere, e.g. ~/Applications)
#
# 4. System Settings → General → Login Items → + → select OneDriveMonitor.app
#
# 5. Test without rebooting:
#    open ~/Applications/OneDriveMonitor.app
#
# To verify it's running:
#    pgrep -fl heartbeat_checker_macos
