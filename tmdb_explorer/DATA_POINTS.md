# TMDB Explorer — available data points

Every field the tool returns for a title, grouped by where it applies. This is
the actual shape of `/api/details` responses (verified against live payloads,
2026-07-16 — The Matrix / The Office US); the "View raw JSON" toggle on any
detail page shows the same data for a specific title.

Image fields (`poster_path`, `backdrop_path`, `still_path`, `profile_path`)
are path fragments — prepend `https://image.tmdb.org/t/p/<size>` (e.g. `w342`).

## Both movies and TV shows

| Group | Fields |
|---|---|
| Identity | `id` (TMDB id), `title`/`name`, `original_title`/`original_name`, `original_language`, `origin_country`, `adult` |
| Story | `overview` (plot summary), `tagline` |
| Classification | `genres` (list of `{id, name}`), `keywords` (freeform tags: "cyberpunk", "dystopia"…) |
| Age certification | movies: `release_dates` per country (MPAA: R, PG-13…); TV: `content_ratings` (TV-14, TV-MA…) |
| Ratings & popularity | `vote_average` (0–10), `vote_count`, `popularity` |
| Status | `status` (Released / Returning Series / Ended / Canceled…) |
| Companies | `production_companies`, `production_countries`, `spoken_languages` |
| Images | `poster_path`, `backdrop_path` |
| Videos | `videos` — trailers/teasers/clips with YouTube keys |
| External ids | `external_ids` (IMDB id, Wikidata, Facebook/Instagram/Twitter), `homepage` |
| Where to watch | `watch/providers` — per-country stream/free/rent/buy lists (JustWatch data) |
| Related titles | `recommendations` — 20 similar titles with their own ids |

## Movie-only

- `release_date`
- `runtime` (minutes)
- `budget`, `revenue`
- `belongs_to_collection` — franchise (e.g. "The Matrix Collection")
- `imdb_id` (also duplicated at top level)
- `credits` — full cast (actor, character, billing order, headshot) and crew
  (director, writers, composer, everyone)

## TV-only

- `first_air_date` / `last_air_date`
- `number_of_seasons` / `number_of_episodes`, `episode_run_time`
- `networks` (NBC, HBO…), `created_by`
- `type` (Scripted / Reality / Miniseries…), `in_production`
- `last_episode_to_air` / `next_episode_to_air` — full episode records
  (useful for "when's the next episode?")
- `seasons` — per-season summaries (number, episode count, air date, poster)
- `aggregate_credits` — all-seasons cast with each actor's character(s) and
  episode counts (regular `credits` would only reflect the latest season)

## Per season (`/api/season`, the season browser)

Season: `name`, `overview`, `air_date`, `poster_path`, `season_number`,
`vote_average`, and its `episodes` — each episode has:

- `episode_number`, `season_number`, `name`
- `overview` (synopsis), `air_date`, `runtime`
- `still_path` (screenshot), `vote_average` / `vote_count`
- `guest_stars` (name, character, headshot)
- `crew` — that episode's director/writer
- `episode_type` ("standard" / "finale"), `production_code`

## Oddities

- `video` (movie) is just a "direct-to-video" flag — the trailers live in `videos`.
- `softcore` is an undocumented flag TMDB added alongside `adult`.

## Not fetched (but available from TMDB)

Alternative titles, translations, full image galleries, reviews, per-episode
external ids, episode groups (DVD/absolute order). To add one, extend
`MOVIE_APPEND` / `TV_APPEND` in `tmdb_explorer.py` (max 20 appends per call).
