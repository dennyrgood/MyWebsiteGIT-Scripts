import os
import ctypes
import subprocess
from pathlib import Path
from datetime import datetime, timedelta, timezone

# ── CONFIG ────────────────────────────────────────────────────────────────────

BASE_PATH = Path("D:/OneDrive")
if not BASE_PATH.exists():
    BASE_PATH = Path(
        os.environ.get("OneDriveConsumer")
        or os.environ.get("OneDrive")
        or Path.home() / "OneDrive"
    )

HEARTBEAT_FILE = BASE_PATH / "_sync_monitor" / "heartbeat_server.txt"
STALE_THRESHOLD_MINUTES = 5

# ── TOAST (Persistent Action Center) ─────────────────────────────────────────

def send_toast(title: str, message: str) -> None:
    safe_title = title.replace('"', '\\"')
    safe_message = message.replace('"', '\\"').replace('\n', ' ')

    ps = (
        '[Windows.UI.Notifications.ToastNotificationManager, '
        'Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;'
        '$xml = [Windows.UI.Notifications.ToastNotificationManager]::'
        'GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);'
        '$textNodes = $xml.GetElementsByTagName("text");'
        f'$textNodes.Item(0).AppendChild($xml.CreateTextNode("{safe_title}")) | Out-Null;'
        f'$textNodes.Item(1).AppendChild($xml.CreateTextNode("{safe_message}")) | Out-Null;'
        '$toast = [Windows.UI.Notifications.ToastNotification]::new($xml);'
        '[Windows.UI.Notifications.ToastNotificationManager]::'
        'CreateToastNotifier("OneDrive Monitor").Show($toast);'
    )

    try:
        subprocess.run(["powershell", "-Command", ps], capture_output=True)
    except Exception:
        pass  # Silent fail — modal will still show


# ── MODAL (In-Your-Face) ─────────────────────────────────────────────────────

def show_modal(title: str, message: str) -> None:
    MB_ICONWARNING = 0x30
    MB_SYSTEMMODAL = 0x1000
    MB_TOPMOST = 0x00040000

    ctypes.windll.user32.MessageBoxW(
        0,
        message,
        title,
        MB_ICONWARNING | MB_SYSTEMMODAL | MB_TOPMOST
    )


# ── CHECK ─────────────────────────────────────────────────────────────────────

def run_check():
    machine = os.environ.get("COMPUTERNAME", "this machine")

    # File missing
    if not HEARTBEAT_FILE.exists():
        msg = (
            f"Heartbeat file missing on {machine}.\n\n"
            f"Expected:\n{HEARTBEAT_FILE}"
        )
        send_toast("⚠ OneDrive Sync Problem", msg)
        show_modal("ONEDRIVE CRITICAL", msg)
        return

    raw = HEARTBEAT_FILE.read_text().strip()

    # Empty file
    if not raw:
        msg = (
            f"Heartbeat file is empty on {machine}.\n\n"
            f"File:\n{HEARTBEAT_FILE}"
        )
        send_toast("⚠ OneDrive Heartbeat Empty", msg)
        show_modal("ONEDRIVE WARNING", msg)
        return

    # Parse timestamp
    try:
        server_time = datetime.fromisoformat(raw)
        if server_time.tzinfo is None:
            server_time = server_time.replace(tzinfo=timezone.utc)
    except Exception as e:
        msg = (
            f"Could not parse heartbeat on {machine}.\n\n"
            f"Content:\n{raw}\n\nError: {e}"
        )
        send_toast("⚠ OneDrive Monitor Error", msg)
        show_modal("MONITOR ERROR", msg)
        return

    age = datetime.now(timezone.utc) - server_time
    age_mins = int(age.total_seconds() / 60)

    if age > timedelta(minutes=STALE_THRESHOLD_MINUTES):
        msg = (
            f"Server heartbeat is {age_mins} minute(s) old on {machine}.\n\n"
            f"Last server write: {server_time.strftime('%H:%M:%S')} UTC"
        )
        send_toast("⚠ OneDrive Sync Appears Stuck", msg)
        show_modal("ONEDRIVE CRITICAL", msg)


if __name__ == "__main__":
    run_check()
