#!/usr/bin/env python3
"""Thin local web GUI for search_adv.

Serves search_adv_web.html and runs search_adv.py as a subprocess — the CLI
stays the single source of truth. Binds to 127.0.0.1 only (the endpoint
executes a subprocess).

Start:  .venv/bin/python search_adv_web.py  →  http://127.0.0.1:5025
"""

import subprocess
import sys
from pathlib import Path

from flask import Flask, jsonify, request, send_file

HERE = Path(__file__).resolve().parent
PYTHON = HERE / ".venv" / "bin" / "python"
SUBPROCESS_TIMEOUT = 300  # cast runs take ~1 min; leave headroom

app = Flask(__name__)


@app.get("/")
def index():
    return send_file(HERE / "search_adv_web.html", max_age=0)


@app.get("/favicon.ico")
def favicon():
    return send_file(HERE / "favicon.ico")


def _build_args(body: dict) -> list[str]:
    """Build the CLI arg list from named fields — never a raw shell string."""
    args: list[str] = []

    mode = body.get("mode", "query")
    query = str(body.get("query", "")).strip()
    if not query:
        raise ValueError("query is required")
    if mode == "cast":
        args += ["--cast", query]
    elif mode == "actor":
        args += ["--actor", query]
    else:
        args.append(query)

    for flag, key in [
        ("--model", "model"),
        ("--endpoint", "endpoint"),
        ("--site", "site"),
    ]:
        val = str(body.get(key, "")).strip()
        if val:
            args += [flag, val]

    for flag, key in [
        ("--results", "results"),
        ("--chunks", "chunks"),
        ("--timeout", "timeout"),
        ("--ollama-timeout", "ollama_timeout"),
    ]:
        val = str(body.get(key, "")).strip()
        if val:
            args += [flag, str(int(val))]  # ints only

    exclude = str(body.get("exclude", "")).strip()
    if exclude:
        args += ["--exclude", *exclude.split()]

    if body.get("no_cache"):
        args.append("--no-cache")
    if mode == "cast":
        if body.get("no_resolve"):
            args.append("--no-resolve")
        if body.get("validate"):
            args.append("--validate")

    # --validate prints plain text and exits; everything else gets --json
    if not body.get("validate"):
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
            [str(PYTHON), str(HERE / "search_adv.py"), *args],
            cwd=HERE,
            capture_output=True,
            text=True,
            timeout=SUBPROCESS_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return jsonify({"error": f"search_adv timed out after {SUBPROCESS_TIMEOUT}s"}), 504

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
    app.run(host="0.0.0.0", port=5025)
