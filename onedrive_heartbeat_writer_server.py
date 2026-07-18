import os
import time
import sys
from pathlib import Path
from datetime import datetime, timezone

# Which machine is running this checker instance

hostname_map = {
    "amsterdamdeskto": "amsterdamdesktop",
}

CHECKER_HOST_IN = os.environ.get("COMPUTERNAME", "unknown").lower()

CHECKER_HOST = hostname_map.get(CHECKER_HOST_IN, CHECKER_HOST_IN)

#print(f"DEBUG: CHECKER_HOST detected: {CHECKER_HOST}", file=sys.stderr)

# Local metrics dir served over Tailscale by fleet_metrics_server.py (no OneDrive).
HEARTBEAT_DIR = Path(os.environ.get("FLEET_METRICS_DIR") or r"C:\fleet_monitor")
HEARTBEAT_FILE = HEARTBEAT_DIR / f"heartbeat_{CHECKER_HOST}.txt"

#print(f"DEBUG: Heartbeat file path: {HEARTBEAT_FILE}", file=sys.stderr)

WRITE_INTERVAL = 150  # 2.5 minutes

iteration = 0
while True:
    iteration += 1
    #print(f"DEBUG: Writing heartbeat #{iteration} to {HEARTBEAT_FILE}", file=sys.stderr, flush=True)
    try:
        HEARTBEAT_DIR.mkdir(parents=True, exist_ok=True)
        HEARTBEAT_FILE.write_text(datetime.now(timezone.utc).isoformat())
        #timestamp = HEARTBEAT_FILE.read_text().strip()
        #print(f"DEBUG: Successfully wrote timestamp: {timestamp}", file=sys.stderr, flush=True)
    except Exception as e:
        pass
        #print(f"DEBUG: ERROR writing to {HEARTBEAT_FILE}: {e}", file=sys.stderr, flush=True)
    time.sleep(WRITE_INTERVAL)


