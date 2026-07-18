# TMDB Explorer

Local web GUI for looking up a movie or TV show on TMDB and browsing everything
the API returns for it: search by title / TMDB id / IMDB id (`tt…`), pick a
result, and get the full record — facts, cast (with per-season episode counts
for TV), crew, certifications, trailers, US watch providers, keywords,
recommendations, a season/episode browser with guest stars, per-person pages,
and a raw-JSON view. Runs on this machine (`mb`) under launchd and is reachable
over Tailscale/LAN (e.g. from a phone).

## Components

Single-purpose files; there is no build step.

| File | Role |
|------|------|
| `tmdb_explorer.py` | Flask backend. Reads the TMDB key, proxies all TMDB calls (key never reaches the browser), caches responses in memory, serves the HTML and the `/api/*` endpoints. |
| `tmdb_explorer.html` | The entire frontend — a hash-routed single-page app with inline CSS/JS. Search, movie/TV/person detail pages, season browser, the "all data points" table, and the **📋 Copy spreadsheet row** button. |
| `enrich_xlsx.py` | Standalone CLI (not part of the web app). Bulk-enriches an existing `.xlsx` of titles with TMDB columns, editing the file surgically at the zip/XML level so formulas and external references survive. |
| `requirements.txt` | `flask`, `requests`. (`enrich_xlsx.py` needs no extra deps; it uses the stdlib + `requests`.) |
| `DATA_POINTS.md` | Reference: every field the tool fetches for movies, shows, seasons, episodes. |
| `COPY_ROW_GUIDE.md` | How the copy-row button works and how to maintain it (add/remove/remap columns), plus a full catalog of usable TMDB fields. |

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

To test a change without disturbing the live service, run a copy on a spare port
and hard-reload (the SPA caches its JS, so an open tab won't refetch it):

```sh
.venv/bin/python -c "import tmdb_explorer as t; t.app.run(host='0.0.0.0', port=5099)"
```

## Deploy

The live instance at `http://mb.ldmathes.cc:5035` runs from **this checkout**
under launchd and serves `tmdb_explorer.html` fresh on each request.

```sh
cd ~/repos/scripts
git add tmdb_explorer/<changed files>          # commit only what you changed
git commit -m "tmdb_explorer: <what changed>"
launchctl kickstart -k gui/$(id -u)/com.dennis.tmdb-explorer
```

Then **hard-reload** the browser tab (Cmd+Shift+R).

## Endpoints (for scripting against it)

- `GET /api/search?q=<query>&type=multi|movie|tv&year=<yyyy>` — query may be a
  title, a bare TMDB id, or an IMDB id
- `GET /api/details?type=movie|tv&id=<tmdb_id>` — full record with
  `append_to_response` bundles
- `GET /api/person?id=<tmdb_id>` — person record with combined credits
- `GET /api/season?id=<tmdb_id>&season=<n>` — episodes + guest stars

## Copy spreadsheet row

On a movie or TV detail page, **📋 Copy spreadsheet row** puts one tab-separated
row on the clipboard, laid out to match the *Movies and Shows* spreadsheet, ready
to paste at column A of a new row. Column order and per-column mapping are driven
by two arrays (`SHEET_COLUMNS`, `ROW_FIELDS`) in `tmdb_explorer.html`. To change
which columns get filled or adopt a new sheet layout, see
**[COPY_ROW_GUIDE.md](COPY_ROW_GUIDE.md)**.

## Bulk enrichment (`enrich_xlsx.py`)

```sh
.venv/bin/python enrich_xlsx.py INPUT.xlsx [OUTPUT.xlsx]
```

Matches each row to TMDB by a themoviedb.org/imdb.com link already in the sheet
(no fuzzy matching) and appends TMDB columns to every row, fetching live (no
cache). Its column set lives in the `COLUMNS` list in that file. It shares field
logic with the copy-row button but is maintained independently — see the note at
the bottom of [COPY_ROW_GUIDE.md](COPY_ROW_GUIDE.md).

## Docs

- **[DATA_POINTS.md](DATA_POINTS.md)** — every field the tool returns.
- **[COPY_ROW_GUIDE.md](COPY_ROW_GUIDE.md)** — copy-row button internals,
  maintenance recipes, and the TMDB field catalog.
