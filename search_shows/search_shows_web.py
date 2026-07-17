#!/usr/bin/env python3
"""Thin local web GUI for search_shows.

Serves search_shows_web.html and runs search_shows.py as a subprocess — the
CLI stays the single source of truth. Binds to 0.0.0.0 so it's reachable over
Tailscale/LAN (e.g. from a phone); args are passed as a list, never a shell
string, so there's no injection surface.

Start:  .venv/bin/python search_shows_web.py  →  http://<host>:5020
(5025 is the general search_adv GUI; 5000 is taken by macOS AirPlay)
"""

import subprocess
import sys
from pathlib import Path

from flask import Flask, jsonify, request, send_file

HERE = Path(__file__).resolve().parent
PYTHON = HERE / ".venv" / "bin" / "python"
SUBPROCESS_TIMEOUT = 60  # pure API lookups; normally well under 5 s

app = Flask(__name__)


@app.get("/")
def index():
    return send_file(HERE / "search_shows_web.html", max_age=0)


@app.get("/favicon.ico")
def favicon():
    return send_file(HERE / "favicon.ico")


@app.get("/apple-touch-icon.png")
@app.get("/apple-touch-icon-precomposed.png")
def apple_touch_icon():
    return send_file(HERE / "apple-touch-icon.png")


def _build_args(body: dict) -> list[str]:
    """Build the CLI arg list from named fields — never a raw shell string."""
    mode = body.get("mode", "show")
    query = str(body.get("query", "")).strip()
    if not query:
        raise ValueError("query is required")
    if mode == "cast":
        args = ["--cast", query]
        if body.get("movie"):
            args.append("--movie")
    elif mode == "actor":
        args = ["--actor", query]
    else:
        args = [query]
    if body.get("list_matches"):
        args.append("--list")
    args.append("--json")
    return args


@app.post("/api/run")
def run():
    try:
        args = _build_args(request.get_json(force=True) or {})
    except (ValueError, TypeError) as exc:
        return jsonify({"error": str(exc)}), 400

    try:
        proc = subprocess.run(
            [str(PYTHON), str(HERE / "search_shows.py"), *args],
            cwd=HERE,
            capture_output=True,
            text=True,
            timeout=SUBPROCESS_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return jsonify({"error": f"search_shows timed out after {SUBPROCESS_TIMEOUT}s"}), 504

    return jsonify(
        {
            "exit_code": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "args": args,
        }
    )


if __name__ == "__main__":
    if not PYTHON.exists():
        sys.exit(f"venv python not found: {PYTHON}")
    app.run(host="0.0.0.0", port=5020)
