# TMDB Explorer

Local web GUI for looking up a movie or TV show on TMDB and browsing everything
the API returns for it: search by title / TMDB id / IMDB id (`tt…`), pick a
result, and get the full record — facts, cast (with per-season episode counts
for TV), crew, certifications, trailers, US watch providers, keywords,
recommendations, a season/episode browser with guest stars, and a raw-JSON view.

See [DATA_POINTS.md](DATA_POINTS.md) for the full list of fields the tool
returns for movies, TV shows, seasons, and episodes.

## Setup (one time)

```sh
cd ~/repos/scripts/tmdb_explorer
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

The TMDB API key is read from `~/.config/search_shows/keys.json` (`"tmdb"`
field) — same file the search_shows tool uses. The key never reaches the
browser; the backend proxies all TMDB calls and caches responses in memory.

## Run

```sh
.venv/bin/python tmdb_explorer.py
```

Then open http://localhost:5035 (or `http://<tailscale-name>:5035` from a
phone). Port 5035: 5000 is macOS AirPlay, 5020/5025/5030 are the other local
GUIs.

## Endpoints (for scripting against it)

- `GET /api/search?q=<query>&type=multi|movie|tv&year=<yyyy>` — query may be a
  title, a bare TMDB id, or an IMDB id
- `GET /api/details?type=movie|tv&id=<tmdb_id>` — full record with
  `append_to_response` bundles
- `GET /api/season?id=<tmdb_id>&season=<n>` — episodes + guest stars
