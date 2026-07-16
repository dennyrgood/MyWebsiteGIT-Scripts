#!/usr/bin/env python3
"""TMDB explorer — local web GUI for looking up movies/TV shows and browsing
the full record TMDB returns for them.

Serves tmdb_explorer.html and proxies all TMDB calls so the API key (read from
~/.config/search_shows/keys.json, "tmdb" field) never reaches the browser.
Responses are cached in memory for the life of the process. Binds to 0.0.0.0
so it's reachable over Tailscale/LAN (e.g. from a phone).

Start:  .venv/bin/python tmdb_explorer.py  →  http://<host>:5035
(5000 is macOS AirPlay; 5020/5025/5030 are taken by the other local GUIs)
"""

import json
import re
import sys
from pathlib import Path

import requests
from flask import Flask, jsonify, request, send_file

HERE = Path(__file__).resolve().parent
KEYS_FILE = Path.home() / ".config" / "search_shows" / "keys.json"
TMDB_BASE = "https://api.themoviedb.org/3"
TIMEOUT = 15

MOVIE_APPEND = "credits,release_dates,videos,external_ids,watch/providers,keywords,recommendations"
TV_APPEND = "aggregate_credits,content_ratings,videos,external_ids,watch/providers,keywords,recommendations"

app = Flask(__name__)
_cache: dict[str, dict] = {}


class TmdbError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def _api_key() -> str:
    try:
        key = json.loads(KEYS_FILE.read_text())["tmdb"]
    except (OSError, ValueError, KeyError) as exc:
        raise TmdbError(500, f'could not read "tmdb" key from {KEYS_FILE}: {exc}')
    if not key:
        raise TmdbError(500, f'empty "tmdb" key in {KEYS_FILE}')
    return key


def tmdb_get(path: str, **params) -> dict:
    """GET a TMDB endpoint, with session-lifetime caching keyed on path+params."""
    cache_key = path + "?" + "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    if cache_key in _cache:
        return _cache[cache_key]
    try:
        resp = requests.get(
            f"{TMDB_BASE}{path}",
            params={**params, "api_key": _api_key()},
            timeout=TIMEOUT,
        )
    except requests.RequestException as exc:
        raise TmdbError(502, f"TMDB request failed: {exc}")
    if resp.status_code != 200:
        try:
            msg = resp.json().get("status_message", resp.reason)
        except ValueError:
            msg = resp.reason
        raise TmdbError(resp.status_code, f"TMDB: {msg}")
    data = resp.json()
    _cache[cache_key] = data
    return data


@app.errorhandler(TmdbError)
def _tmdb_error(exc: TmdbError):
    return jsonify({"error": exc.message}), exc.status


@app.get("/")
def index():
    return send_file(HERE / "tmdb_explorer.html", max_age=0)


def _summarize(r: dict) -> dict:
    """Trim a movie/TV record down to what the search-result list shows."""
    return {
        "id": r["id"],
        "media_type": r["media_type"],
        "title": r.get("title") or r.get("name") or "(untitled)",
        "year": (r.get("release_date") or r.get("first_air_date") or "")[:4],
        "overview": r.get("overview") or "",
        "poster_path": r.get("poster_path"),
    }


@app.get("/api/search")
def search():
    q = (request.args.get("q") or "").strip()
    stype = request.args.get("type", "multi")
    year = (request.args.get("year") or "").strip()
    if not q:
        raise TmdbError(400, "query is required")
    if stype not in ("multi", "movie", "tv"):
        raise TmdbError(400, f"bad type: {stype}")
    types = ["movie", "tv"] if stype == "multi" else [stype]

    if re.fullmatch(r"tt\d+", q):
        # IMDB id → /find
        data = tmdb_get(f"/find/{q}", external_source="imdb_id")
        results = [dict(r, media_type="movie") for r in data.get("movie_results", [])]
        results += [dict(r, media_type="tv") for r in data.get("tv_results", [])]
    elif q.isdigit():
        # raw TMDB id — ambiguous between movie and tv, so try what's allowed
        results = []
        for mt in types:
            try:
                results.append(dict(tmdb_get(f"/{mt}/{q}"), media_type=mt))
            except TmdbError as exc:
                if exc.status != 404:
                    raise
    elif stype == "multi" and not year:
        data = tmdb_get("/search/multi", query=q)
        results = [r for r in data.get("results", []) if r.get("media_type") in ("movie", "tv")]
    else:
        # /search/multi ignores year, so with a year (or a single type) search
        # movie and/or tv separately and merge by popularity
        results = []
        for mt in types:
            params = {"query": q}
            if year:
                params["year" if mt == "movie" else "first_air_date_year"] = year
            for r in tmdb_get(f"/search/{mt}", **params).get("results", []):
                results.append(dict(r, media_type=mt))
        results.sort(key=lambda r: r.get("popularity", 0), reverse=True)

    return jsonify({"results": [_summarize(r) for r in results]})


@app.get("/api/details")
def details():
    mt = request.args.get("type")
    tmdb_id = request.args.get("id", "")
    if mt not in ("movie", "tv"):
        raise TmdbError(400, f"bad type: {mt}")
    if not tmdb_id.isdigit():
        raise TmdbError(400, f"bad id: {tmdb_id}")
    append = MOVIE_APPEND if mt == "movie" else TV_APPEND
    return jsonify(tmdb_get(f"/{mt}/{tmdb_id}", append_to_response=append))


@app.get("/api/season")
def season():
    tmdb_id = request.args.get("id", "")
    number = request.args.get("season", "")
    if not tmdb_id.isdigit() or not re.fullmatch(r"\d+", number):
        raise TmdbError(400, "id and season must be numeric")
    return jsonify(tmdb_get(f"/tv/{tmdb_id}/season/{number}"))


if __name__ == "__main__":
    if not KEYS_FILE.exists():
        sys.exit(f"keys file not found: {KEYS_FILE}")
    app.run(host="0.0.0.0", port=5035)
