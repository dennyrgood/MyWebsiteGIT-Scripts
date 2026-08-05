"""
heartbeat_checker_windows.pyw — runs on Win11 client machines
Reads the server's heartbeat file from the synced OneDrive folder
and alerts if it's stale (meaning sync has stopped working).

Save as .pyw so it runs silently (no console window).

Setup:
  pip install plyer psutil

Schedule via Task Scheduler every 5 minutes:
  Run setup_checker_windows.ps1  (provided separately)
  OR set up manually:
    Program:   pythonw.exe
    Arguments: "C:\path\to\heartbeat_checker_windows.pyw"
    Trigger:   Repeat every 5 minutes indefinitely
"""

import os
from pathlib import Path
from datetime import datetime, timedelta, timezone
import subprocess

# ── CONFIG ────────────────────────────────────────────────────────────────────

ONEDRIVE_PATH = Path(os.environ.get("OneDriveConsumer") or os.environ.get("OneDrive") or
                     Path.home() / "OneDrive")

HEARTBEAT_FILE = ONEDRIVE_PATH / "_sync_monitor" / "heartbeat_server.txt"

# Alert if server heartbeat is older than this
STALE_THRESHOLD_MINUTES = 5

# ── NOTIFY ────────────────────────────────────────────────────────────────────

def notify(title: str, message: str) -> None:
    # Use Windows ToastNotifier — persistent, stays in Action Center
    safe_title = title.replace('"', '\\"')
    safe_message = message.replace('"', '\\"').replace('\n', ' ')
    ps = (
        '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;'
        '$template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02;'
        '$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template);'
        '$text = $xml.GetElementsByTagName("text");'
        f'$text[0].InnerText = "{safe_title}";'
        f'$text[1].InnerText = "{safe_message}";'
        '$toast = [Windows.UI.Notifications.ToastNotification]::new($xml);'
        '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("OneDrive Monitor").Show($toast);'
    )
    try:
        subprocess.run(["powershell", "-Command", ps], capture_output=True)
    except Exception:
        # Last resort: tkinter
        import tkinter as tk
        from tkinter import messagebox
        root = tk.Tk()
        root.withdraw()
        messagebox.showwarning(title, message)
        root.destroy()

# ── CHECK ─────────────────────────────────────────────────────────────────────

def run_check():
    machine = os.environ.get("COMPUTERNAME", "this machine")

    # File missing entirely
    if not HEARTBEAT_FILE.exists():
        notify(
            "⚠️ OneDrive Sync Problem",
            f"Server heartbeat file not found on {machine}.\n"
            f"OneDrive may not be syncing at all.\n\n"
            f"Expected: {HEARTBEAT_FILE}"
        )
        return

    # Read the timestamp written by the server
    raw = HEARTBEAT_FILE.read_text().strip()

    if not raw:
        notify(
            "⚠️ OneDrive Heartbeat Empty",
            f"Heartbeat file exists on {machine} but has no content.\n"
            f"The server writer may not be running yet.\n\n"
            f"File: {HEARTBEAT_FILE}"
        )
        return

    try:
        server_time = datetime.fromisoformat(raw)
        if server_time.tzinfo is None:
            server_time = server_time.replace(tzinfo=timezone.utc)
    except Exception as e:
        notify(
            "⚠️ OneDrive Monitor Error",
            f"Could not parse heartbeat timestamp on {machine}.\n"
            f"Content was: '{raw}'\nError: {e}"
        )
        return

    age = datetime.now(timezone.utc) - server_time
    age_mins = int(age.total_seconds() / 60)

    if age > timedelta(minutes=STALE_THRESHOLD_MINUTES):
        notify(
            "⚠️ OneDrive Sync Appears Stuck",
            f"Server heartbeat is {age_mins} minute(s) old on {machine}.\n"
            f"OneDrive may have stopped syncing.\n\n"
            f"Last server write: {server_time.strftime('%H:%M:%S')} UTC"
        )

if __name__ == "__main__":
    run_check()
