#!/usr/bin/env python3
r"""
fleet_metrics_server.py — serve this machine's fleet_monitor/ dir over Tailscale.

Runs on every fleet machine. The checker pulls heartbeat_/machine_info_/metrics_history_
files from here via HTTP instead of via OneDrive sync. Files are served straight off disk
on each request, so "the file you inspect on disk" == "what the checker receives".

Tailnet-internal only. Bind is 0.0.0.0; restrict the port to the checker machines with a
Tailscale ACL if you want it locked down. Stdlib only (no Flask) so it runs unmodified on
macOS / Ubuntu / Windows with no extra installs.

Metrics dir (override with FLEET_METRICS_DIR):
  Windows:    C:\fleet_monitor
  Mac/Linux:  ~/fleet_monitor
Port (override with FLEET_METRICS_PORT): 9100

Created: 2026-07-17 — replaces the OneDrive _sync_monitor file transport.
"""

import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def _default_dir() -> Path:
    env = os.environ.get("FLEET_METRICS_DIR")
    if env:
        return Path(env)
    if os.name == "nt":
        return Path(r"C:\fleet_monitor")
    return Path.home() / "fleet_monitor"


METRICS_DIR = _default_dir()
PORT = int(os.environ.get("FLEET_METRICS_PORT", "9100"))

# Only these files are servable, and the name must be a bare filename — the character
# class excludes "/" and "\", so no path traversal is possible.
_ALLOWED = re.compile(r"^(heartbeat|machine_info|metrics_history|watchdog)_[A-Za-z0-9._-]+\.(txt|json|log)$")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.lstrip("/")
        if not _ALLOWED.match(name):
            self.send_error(404)
            return

        fpath = METRICS_DIR / name
        if not fpath.is_file():
            self.send_error(404)
            return

        try:
            body = fpath.read_bytes()
        except OSError:
            self.send_error(500)
            return

        ctype = "application/json" if name.endswith(".json") else "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # stay quiet; this runs unattended under a service manager


def main():
    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"fleet_metrics_server serving {METRICS_DIR} on 0.0.0.0:{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
