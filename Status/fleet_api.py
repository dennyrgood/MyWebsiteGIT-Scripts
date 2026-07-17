# fleet_api.py
# FLEET_OPS — Fleet status API
# Serves server_status_all.json and metrics history files to the dashboard
# Last updated: 2026-06-16 14:12 UTC — add /api/history/<host> endpoint

import os
import json
import time
import urllib.request
from datetime import datetime
from flask import Flask, jsonify, make_response, request, send_file, send_from_directory

try:
    import config
except ImportError:
    print("[ERROR] config.py not found. Ensure it is in the same directory.")
    exit(1)

app = Flask(__name__)

STATUS_FILE = os.path.join(config.STATUS_DIR, "server_status_all.json")
WEB_DIR     = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Web")


def get_file_age(filepath):
    """Returns the age of the file in seconds."""
    try:
        mtime = os.path.getmtime(filepath)
        return int(time.time() - mtime)
    except OSError:
        return None


def add_custom_headers(data, status_code=200):
    response = make_response(jsonify(data), status_code)
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['X-Checker-Host'] = getattr(config, 'CHECKER_HOST', 'unknown')
    age = get_file_age(STATUS_FILE)
    response.headers['X-Data-Age'] = str(age) if age is not None else "unknown"
    return response


@app.route('/')
def index():
    return send_file(os.path.join(WEB_DIR, 'index.html'))


@app.route('/<path:path>')
def static_files(path):
    return send_from_directory(WEB_DIR, path)


@app.route('/health', methods=['GET'])
def health_check():
    """Simple endpoint for Cloudflare health monitors."""
    return add_custom_headers({
        "status":       "ok",
        "checker_host": getattr(config, 'CHECKER_HOST', 'unknown'),
        "timestamp":    datetime.now().isoformat()
    })


@app.route('/api/status', methods=['GET'])
def get_status():
    """Reads and returns the master status JSON."""
    if not os.path.exists(STATUS_FILE):
        return add_custom_headers({"error": "Status file not found on host"}, 503)
    try:
        with open(STATUS_FILE, 'r') as f:
            data = json.load(f)
        return add_custom_headers(data)
    except (json.JSONDecodeError, IOError) as e:
        return add_custom_headers({"error": f"Failed to read status data: {str(e)}"}, 503)


@app.route('/api/history/<host>', methods=['GET'])
def get_history(host):
    """
    Returns the metrics history for a host as a JSON array.
    Pulls metrics_history_{host}.json from that host's fleet_metrics_server over Tailscale
    (the checker's own box via 127.0.0.1). The file is JSON-lines; at most 120 entries
    (~1 hour). Unreachable target → empty array, so the dashboard degrades gracefully.
    """
    fetch_host = "127.0.0.1" if host == getattr(config, "CHECKER_HOST", "") else host
    url = f"http://{fetch_host}:{config.METRICS_PORT}/metrics_history_{host}.json"

    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            text = r.read().decode("utf-8-sig")
    except Exception:
        response = make_response(jsonify([]), 200)
        response.headers['Access-Control-Allow-Origin'] = '*'
        return response

    entries = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # skip any malformed lines silently

    response = make_response(jsonify(entries), 200)
    response.headers['Access-Control-Allow-Origin'] = '*'
    return response


if __name__ == '__main__':
    print(f"Starting Fleet API for {getattr(config, 'CHECKER_HOST', 'unknown')}...")
    print(f"Serving data from: {STATUS_FILE}")
    app.run(host='0.0.0.0', port=5010, debug=False)
