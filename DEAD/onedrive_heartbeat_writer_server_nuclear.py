#
# If the Onedrive gives me greief later with not sync'ng
#

import os
import time
from pathlib import Path
from datetime import datetime, timezone

# Resolve OneDrive Path
ONEDRIVE_PATH = Path(
    os.environ.get("OneDriveConsumer")
    or os.environ.get("OneDrive")
    or Path.home() / "OneDrive"
)

# Rename to avoid potential "underscore" ignore rules
HEARTBEAT_DIR = ONEDRIVE_PATH / "SyncMonitor" 
CHECKER_HOST = os.environ.get("COMPUTERNAME", "unknown").lower()
HEARTBEAT_FILE = HEARTBEAT_DIR / f"heartbeat_{CHECKER_HOST}.txt"
TEMP_FILE = HEARTBEAT_DIR / f"heartbeat_{CHECKER_HOST}.tmp"

WRITE_INTERVAL = 150 

while True:
    try:
        HEARTBEAT_DIR.mkdir(parents=True, exist_ok=True)
        
        # ATOMIC WRITE: Write to .tmp then rename to .txt
        # This is the most reliable way to trigger a OneDrive sync
        timestamp = datetime.now(timezone.utc).isoformat()
        TEMP_FILE.write_text(timestamp, encoding="utf-8")
        
        # os.replace is atomic on Windows; it replaces the destination 
        # and triggers a single "File Changed" event for OneDrive.
        os.replace(TEMP_FILE, HEARTBEAT_FILE)
        
    except Exception as e:
        # If you need to debug, uncomment this:
        # print(f"Error: {e}", file=sys.stderr)
        pass

    time.sleep(WRITE_INTERVAL)