# TMDB Explorer — "Copy spreadsheet row" button: how it works & how to maintain it

This document is self-contained. Drop it into a Claude Code session (open it, or
`@tmdb_explorer/COPY_ROW_GUIDE.md`) and you can maintain the feature with a
one-line prompt — see **"Driving changes from a session"** at the end.

---

## What the feature does

On every movie and TV **detail page** in `tmdb_explorer.html` there is a
**📋 Copy spreadsheet row** button. Pressing it copies **one tab-separated (TSV)
row** to the clipboard, laid out to match the *Movies and Shows* spreadsheet
column-for-column, so you can select column A of a new row in Excel and paste
once. TMDB-derived columns are filled; your manual/formula columns are left
blank. Movie-only fields are blank on a show, and TV-only fields are blank on a
movie. Excel auto-converts ISO dates (`2024-12-25` → `12/25/24`) and
auto-linkifies pasted URLs.

Everything lives in **`tmdb_explorer.html`**, in the inline `<script>`, in the
section marked `/* ---------- spreadsheet clipboard row ---------- */`.

---

## The mental model (only two things matter)

The whole feature is driven by **two data structures**. To maintain it you edit
one or both; you almost never touch the rest.

1. **`SHEET_COLUMNS`** — an array with **one entry per spreadsheet column, in
   sheet order (A, B, C, …)**. Each entry is either:
   - a **string** = the name of a field in `ROW_FIELDS` → that column gets filled, or
   - **`null`** = leave that column blank (your manual / formula columns).

   The array's **length must equal the number of columns in the sheet.** Its
   order must match the sheet's column order exactly.

2. **`ROW_FIELDS`** — a lookup of `name → function(d, tv)` that pulls a value out
   of the TMDB detail object `d`. `tv` is `true` for a show, `false` for a movie.
   Return `""` for "nothing in this cell."

`sheetRow(d, type)` then walks `SHEET_COLUMNS`, calls the mapped extractor for
each (or emits `""` for `null`), sanitizes each value (tabs/newlines inside a
value become spaces), and joins with tabs. `copyRow()` copies the result.

> `d` is the full `/api/details` response **including** the appended blocks
> (`credits`/`aggregate_credits`, `release_dates`/`content_ratings`,
> `external_ids`, `videos`, `watch/providers`, `keywords`, `recommendations`),
> so any field listed in the catalog below is available in the browser.

---

## Current mapping (29-column "ReadyForDHM" layout)

| Col | Header | Filled with | Notes |
|----|--------|-------------|-------|
| A | Code | — | manual |
| B | Sub | — | manual/formula |
| C | With | — | manual/formula |
| D | Avail | — | manual/formula |
| E | title_tmdb | `title` | clean title (`name`/`title`) |
| F | genres | `genres` | comma-joined |
| G | Seasons made (Movie=0) | `seasons_made` | `number_of_seasons`; **0** for movies |
| H | Download from S##E## or Movie | `download_from` | `"Movie"` for movies; blank for shows |
| I | File Location Status | — | manual |
| J | last_air_date | `last_air_date` | show: last aired; **movie: primary `release_date`** |
| K | Next BROADCAST - DELETE | — | manual |
| L | tmdb_status | `tmdb_status` | `status` (Returning Series / Released…) |
| M | certification | `certification` | US rating (helper) |
| N | overview | `overview` | |
| O | cast_top5 | `cast_top5` | top 5, `Name (Character)` joined by `; ` |
| P | networks | `networks` | TV only |
| Q | runtime | `runtime` | minutes; movie `runtime` / TV `episode_run_time[0]` |
| R | type | `type` | TV only (Scripted…) |
| S | origin_country | `origin_country` | comma-joined |
| T | in_production | `in_production` | TV only, `Yes`/`No` |
| U | created_by | `created_by` | TV only |
| V | last_episode_to_air | `last_episode_to_air` | TV only, `S1E8 — Name (date)` |
| W | next_episode_to_air | `next_episode_to_air` | TV only |
| X | number_of_seasons | `number_of_seasons` | TV only |
| Y | number_of_episodes | `number_of_episodes` | TV only |
| Z | TMDB_hyperlink | `tmdb_url` | `https://www.themoviedb.org/<type>/<id>` |
| AA | tmdb_id | `tmdb_id` | |
| AB | imdb_id | `imdb_id` | |
| AC | tvdb_id | `tvdb_id` | TV only |

---

## Maintenance recipes

### A. Change what populates an existing column
Find the column in `SHEET_COLUMNS`, change its string to a different field name
(or to a new one you add to `ROW_FIELDS`). Example — make column L hold the
tagline instead of status: change `"tmdb_status"` to `"tagline"` and add
`tagline: d => d.tagline || "",` to `ROW_FIELDS`.

### B. Stop populating a column (make it manual)
Change that column's entry in `SHEET_COLUMNS` to `null`. Leave `ROW_FIELDS`
alone (an unused extractor is harmless).

### C. Add a new column to the sheet
1. Insert `null` (or a field name) into `SHEET_COLUMNS` **at the position that
   matches where the column sits in the sheet**. Order is everything.
2. If it's app-filled, make sure the field exists in `ROW_FIELDS` (add it if not
   — see recipe E).
3. Verify the array length now equals the sheet's column count.

### D. Delete a column from the sheet
Remove its entry from `SHEET_COLUMNS` (so every later column shifts left by one,
matching the sheet). The array length must drop by one.

### E. Add a brand-new derived field
Add an entry to `ROW_FIELDS`: `name: (d, tv) => <expression>`. Use the catalog
below for the right path. Then reference `"name"` from `SHEET_COLUMNS`. Rules:
- Return `""` (not `null`/`undefined`) when there's no value.
- For lists, join to a string, e.g. `(d.networks || []).map(n => n.name).join(", ")`.
- Use `tv` to branch movie vs show, e.g. `(d, tv) => tv ? d.name : d.title`.
- Numbers are fine to return as numbers; they're stringified on output.

### F. Reorder columns / adopt a whole new layout
Rebuild `SHEET_COLUMNS` from the new header row, left to right, one entry per
column. This is the "send me the new header and I remap" case — it's just this
one array.

---

## Full catalog of usable TMDB fields

Ready-to-paste expressions for a `ROW_FIELDS` extractor `(d, tv) => …`.
"Applies": **both** / **movie** / **tv**. Helpers `usCertMovie`, `usCertTv`,
`money`, `runtimeStr`, `castTop5`, `epText` already exist in the file.

### Identity / story / classification (both)
| Want | Expression | Example |
|------|-----------|---------|
| TMDB id | `d.id` | `108545` |
| title | `tv ? d.name : d.title` | `3 Body Problem` |
| original title | `tv ? d.original_name : d.original_title` | `3 Body Problem` |
| original language | `d.original_language` | `en` |
| origin country | `(d.origin_country || []).join(", ")` | `US` |
| overview | `d.overview` | `Across continents…` |
| tagline | `d.tagline` | `Long live the fighters.` |
| status | `d.status` | `Returning Series` |
| genres | `(d.genres || []).map(g => g.name).join(", ")` | `Drama, Sci-Fi` |
| keywords | `((d.keywords?.keywords) || (d.keywords?.results) || []).map(k => k.name).join(", ")` | `alien, dystopia` |
| popularity | `d.popularity` | `13.1` |
| vote average | `d.vote_average` | `7.5` |
| vote count | `d.vote_count` | `1563` |
| adult flag | `d.adult ? "Yes" : "No"` | `No` |
| homepage | `d.homepage` | `https://…` |
| poster path | `d.poster_path` | `/abc.jpg` |
| backdrop path | `d.backdrop_path` | `/def.jpg` |
| production companies | `(d.production_companies || []).map(c => c.name).join(", ")` | `Legendary` |
| production countries | `(d.production_countries || []).map(c => c.name).join(", ")` | `United States` |
| spoken languages | `(d.spoken_languages || []).map(l => l.english_name).join(", ")` | `English` |
| certification (US) | `tv ? usCertTv(d) : usCertMovie(d)` | `TV-MA` / `R` |

### Movie-only
| Want | Expression | Example |
|------|-----------|---------|
| release date | `d.release_date` | `2024-12-25` |
| runtime (min) | `d.runtime` | `141` |
| runtime (h m) | `runtimeStr(d.runtime)` | `2h 21m` |
| budget | `d.budget` (or `money(d.budget)`) | `$190,000,000` |
| revenue | `d.revenue` (or `money(d.revenue)`) | `$714,844,358` |
| collection | `d.belongs_to_collection?.name || ""` | `Dune Collection` |
| imdb id | `d.imdb_id || d.external_ids?.imdb_id` | `tt1160419` |

### TV-only
| Want | Expression | Example |
|------|-----------|---------|
| first air date | `d.first_air_date` | `2024-03-21` |
| last air date | `d.last_air_date` | `2024-03-21` |
| number of seasons | `d.number_of_seasons` | `1` |
| number of episodes | `d.number_of_episodes` | `8` |
| episode runtime | `(d.episode_run_time || [])[0]` | `50` |
| type | `d.type` | `Scripted` |
| in production | `d.in_production ? "Yes" : "No"` | `Yes` |
| networks | `(d.networks || []).map(n => n.name).join(", ")` | `Netflix` |
| created by | `(d.created_by || []).map(c => c.name).join(", ")` | `David Benioff, …` |
| last episode | `epText(d.last_episode_to_air)` | `S1E8 — Wallfacer (2024-03-21)` |
| next episode | `epText(d.next_episode_to_air)` | `S2E1 — … (2026-…)` |
| # seasons incl specials | `(d.seasons || []).length` | `2` |

### People — cast & crew
| Want | Expression | Notes |
|------|-----------|-------|
| top-5 cast | `castTop5(d, tv)` | `Name (Character); …` |
| movie director(s) | `(d.credits?.crew || []).filter(c => c.job === "Director").map(c => c.name).join(", ")` | movie |
| movie writers | `(d.credits?.crew || []).filter(c => c.department === "Writing").map(c => c.name).join(", ")` | movie |
| full cast names | `(tv ? d.aggregate_credits : d.credits)?.cast?.map(c => c.name).join(", ") || ""` | long |

> Movies use `d.credits` (`cast[].character`, `crew[].job/department`); shows use
> `d.aggregate_credits` (`cast[].roles[].character`, `crew[].jobs[].job`, plus
> `total_episode_count`).

### External ids (both — `d.external_ids`)
| Want | Expression |
|------|-----------|
| imdb | `d.external_ids?.imdb_id` |
| tvdb | `d.external_ids?.tvdb_id` |
| wikidata | `d.external_ids?.wikidata_id` |
| facebook | `d.external_ids?.facebook_id` |
| instagram | `d.external_ids?.instagram_id` |
| twitter/x | `d.external_ids?.twitter_id` |

### Links, providers, videos, recommendations (both)
| Want | Expression |
|------|-----------|
| TMDB page URL | `` `https://www.themoviedb.org/${tv ? "tv" : "movie"}/${d.id}` `` |
| IMDB page URL | `` d.external_ids?.imdb_id ? `https://www.imdb.com/title/${d.external_ids.imdb_id}/` : "" `` |
| US stream providers | `(d["watch/providers"]?.results?.US?.flatrate || []).map(p => p.provider_name).join(", ")` |
| US rent providers | `(d["watch/providers"]?.results?.US?.rent || []).map(p => p.provider_name).join(", ")` |
| trailer YouTube key | `(d.videos?.results || []).find(v => v.site === "YouTube" && v.type === "Trailer")?.key || ""` |
| # recommendations | `(d.recommendations?.results || []).length` |

Image paths are fragments — prefix `https://image.tmdb.org/t/p/w342` (or another
size) if you want a full URL.

---

## Testing a change (before deploying)

The row logic is pure JS. This harness loads the **actual** `<script>` from the
HTML (no divergence) and prints a row for a show and a movie against live TMDB.
`node` and a TMDB key at `~/.config/search_shows/keys.json` are all it needs.

```js
// rowcheck.js
const fs = require('fs');
const s = fs.readFileSync('tmdb_explorer.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
globalThis.window={addEventListener(){}}; globalThis.document={querySelector(){return null},addEventListener(){}};
globalThis.navigator={}; globalThis.location={hash:''};
eval(s + '\nglobalThis.__t={sheetRow};');
(async () => {
  const KEY = JSON.parse(fs.readFileSync(process.env.HOME+'/.config/search_shows/keys.json','utf8')).tmdb;
  const g = async (mt,id,ap) => (await (await fetch(`https://api.themoviedb.org/3/${mt}/${id}?api_key=${KEY}&append_to_response=${ap}`)).json());
  const show = async (label,d,t) => console.log('\n'+label+'\n'+__t.sheetRow(d,t).split('\t').map((v,i)=>`${i+1}: ${v}`).join('\n'));
  await show('TV',   await g('tv','108545','aggregate_credits,content_ratings,external_ids'), 'tv');
  await show('MOVIE',await g('movie','661539','credits,release_dates,external_ids'), 'movie');
})();
```
Run from the `tmdb_explorer/` dir: `node rowcheck.js`. Confirm the field count
equals your column count and values land where expected.

To test in a real browser without disturbing live 5035, run a copy on another
port and hard-reload (the SPA caches its JS):
```
.venv/bin/python -c "import tmdb_explorer as t; t.app.run(host='0.0.0.0', port=5099)"
```

---

## Deploying

The live instance at `http://mb.ldmathes.cc:5035` runs from this checkout under
launchd and serves `tmdb_explorer.html` fresh each request.

```
cd ~/repos/scripts
git add tmdb_explorer/tmdb_explorer.html          # commit ONLY this file
git commit -m "tmdb_explorer: <what changed>"
launchctl kickstart -k gui/$(id -u)/com.dennis.tmdb-explorer
```
Then **hard-reload** the browser tab (Cmd+Shift+R) — an open SPA tab won't
refetch its JS otherwise. (Committing only the HTML avoids sweeping up unrelated
uncommitted work elsewhere in the repo.)

---

## Related: the bulk enricher (`enrich_xlsx.py`)

There is a **second** tool that maps the same TMDB fields: the standalone
`enrich_xlsx.py` CLI, which enriches an **existing** `.xlsx` in bulk (adds
columns to every row) rather than copying one row at a time. It has its own
parallel mapping — a `COLUMNS` list (with `CLEAR_COLS`) near the top of that
file — using the same field logic (`_cast_top5`, `_us_cert_*`, etc.).

The two are **independent by design** — different jobs (bulk file vs paste one
row) and, currently, different target layouts (the CLI reflects the older
bulk-enrichment column set; this button reflects the ReadyForDHM layout). They
are **not** auto-synced. If you change what a field *means* (e.g. "certification
should prefer the UK rating"), update it in **both** places so bulk and
interactive output agree. Pure layout/column changes usually only affect
whichever tool's target sheet changed.

## Driving changes from a session

Open this file (or `@tmdb_explorer/COPY_ROW_GUIDE.md`) and give a one-line
instruction, e.g.:

- *"Add a column between M and N called `budget`, filled with the movie budget, blank for shows."*
- *"Column O should be the full cast names instead of top-5."*
- *"Stop filling column H; make it manual."*
- *"Here's the new header row: `<paste>` — remap `SHEET_COLUMNS` to it."*
- *"Add a `trailer_url` field (YouTube trailer link) and put it in a new last column."*

Expected assistant workflow: edit `SHEET_COLUMNS` and/or `ROW_FIELDS` in
`tmdb_explorer.html` only; keep the array length equal to the sheet's column
count; verify with the `rowcheck.js` harness above; then commit just the HTML and
`launchctl kickstart` to deploy.
