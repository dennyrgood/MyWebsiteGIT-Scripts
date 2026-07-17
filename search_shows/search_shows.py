#!/Users/dennishmathes/repos/scripts/search_shows/.venv/bin/python
# search_shows.py — cast / actor / show lookup via structured APIs (TVmaze, OMDb, TMDB)
# 2026-07-16 — replaces search_adv's scrape+LLM pipeline with direct API calls.
#
# Usage:
#   search_shows.py --cast "star trek next generation s02e9"   TV episode: main + guest cast
#   search_shows.py --cast "medium s0101"                      also: 4x10, "season 4 episode 10"
#   search_shows.py --cast "medium season 4"                   season: episode list + main cast
#   search_shows.py --cast "hope street"                       TV series: main cast
#   search_shows.py --cast "the godfather (1972)"              movie: top cast (TMDB/OMDb)
#   search_shows.py --actor "diana muldaur"                    TV credits (TVmaze; TMDB adds movies)
#   search_shows.py --actor "medium s04e10 cynthia"            who played the character + credits
#   search_shows.py "some show title"                          show summary/info
#   ... [--json]
#
# API keys (OMDb/TMDB) load from ~/.config/search_shows/keys.json or
# $OMDB_API_KEY / $TMDB_API_KEY. TVmaze needs no key.

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import time
from pathlib import Path

import requests

TVMAZE = "https://api.tvmaze.com"
TMDB = "https://api.themoviedb.org/3"
TIMEOUT = 10

# Episode notations, ported from search_adv's castref.py (same priority order):
# s0101 (compact SSEE), s04e10 / S4 E10, 4x10, "season 4 [episode 10]", "episode 3".
COMPACT_RE = re.compile(r"\bs(\d{2})(\d{2})\b", re.IGNORECASE)
SHORTHAND_RE = re.compile(r"\bs(\d{1,2})\s*e(\d{1,3})\b", re.IGNORECASE)
NXM_RE = re.compile(r"\b(\d{1,2})x(\d{1,3})\b", re.IGNORECASE)
NATURAL_RE = re.compile(
    r"\bseason\s*(\d{1,2})(?:\s*(?:,|-|\s)\s*episode\s*(\d{1,3}))?\b", re.IGNORECASE
)
EPISODE_ONLY_RE = re.compile(r"\bepisode\s*(\d{1,3})\b", re.IGNORECASE)
# Bare season shorthand with no episode: "medium s02", "medium s2".
SEASON_ONLY_RE = re.compile(r"\bs(\d{1,2})\b", re.IGNORECASE)
YEAR_RE = re.compile(r"\(?\b(19\d{2}|20\d{2})\b\)?\s*$")


def load_keys() -> dict:
    keys = {}
    cfg = Path.home() / ".config" / "search_shows" / "keys.json"
    if cfg.exists():
        try:
            keys = json.loads(cfg.read_text())
        except Exception as e:
            print(f"warning: could not parse {cfg}: {e}", file=sys.stderr)
    if os.environ.get("OMDB_API_KEY"):
        keys["omdb"] = os.environ["OMDB_API_KEY"]
    if os.environ.get("TMDB_API_KEY"):
        keys["tmdb"] = os.environ["TMDB_API_KEY"]
    return keys


def get_json(url: str, params: dict | None = None) -> dict | list | None:
    try:
        # Wikipedia (and others) 403 the default python-requests agent.
        r = requests.get(url, params=params, timeout=TIMEOUT,
                         headers={"User-Agent": "search_shows/1.0 (personal cast lookup tool)"})
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()
    except requests.RequestException as e:
        print(f"warning: {url.split('?')[0]}: {e}", file=sys.stderr)
        return None


def _clean_title(text: str) -> str:
    return re.sub(r"[\s,\-–—:]+$", "", text).strip()


def parse_ref(raw: str) -> dict:
    """Standardise a show/episode/movie reference.

    Returns title/season/episode/year plus 'rest' — any text after the episode
    qualifier (e.g. a character name in "Medium S4E10 Cynthia").
    """
    text = raw.strip()
    ref = {"title": text, "season": None, "episode": None, "year": None, "rest": ""}

    for pat in (COMPACT_RE, SHORTHAND_RE, NXM_RE, NATURAL_RE):
        m = pat.search(text)
        if m:
            ref["season"] = int(m.group(1))
            ref["episode"] = int(m.group(2)) if m.group(2) else None
            ref["title"] = _clean_title(text[: m.start()])
            ref["rest"] = text[m.end() :].strip(" -–—:,")
            return ref

    m = EPISODE_ONLY_RE.search(text)
    if m:
        ref["episode"] = int(m.group(1))
        ref["title"] = _clean_title(text[: m.start()])
        ref["rest"] = text[m.end() :].strip(" -–—:,")
        return ref

    m = SEASON_ONLY_RE.search(text)
    if m and text[: m.start()].strip():  # needs a title before it — don't eat a bare "s2" query
        ref["season"] = int(m.group(1))
        ref["title"] = _clean_title(text[: m.start()])
        ref["rest"] = text[m.end() :].strip(" -–—:,")
        return ref

    y = YEAR_RE.search(text)
    if y:
        ref["year"] = int(y.group(1))
        ref["title"] = _clean_title(YEAR_RE.sub("", text)).strip("()")
    return ref


# ------------------------------------------------------------- title resolver

_LEADING_ARTICLE_RE = re.compile(r"^(the|a|an)\s+", re.IGNORECASE)


def _similar(a: str, b: str) -> float:
    a = _LEADING_ARTICLE_RE.sub("", a.strip())
    b = _LEADING_ARTICLE_RE.sub("", b.strip())
    return difflib.SequenceMatcher(None, a.casefold(), b.casefold()).ratio()


def wiki_suggest(text: str) -> str | None:
    """Wikipedia's search suggestion — a free spelling corrector ('toy storie 5'
    → 'toy story 5'). Returns None when Wikipedia has no better idea."""
    d = get_json(
        "https://en.wikipedia.org/w/api.php",
        {"action": "query", "list": "search", "srsearch": text, "srlimit": 1,
         "srinfo": "suggestion", "format": "json"},
    )
    try:
        return d["query"]["searchinfo"]["suggestion"]
    except (KeyError, TypeError):
        return None


def _tv_candidates(title: str, keys: dict) -> list[tuple[str, str, str]]:
    out = []
    for m in get_json(f"{TVMAZE}/search/shows", {"q": title}) or []:
        out.append((m["show"]["name"], (m["show"].get("premiered") or "")[:4], "tv"))
    if not out and keys.get("tmdb"):
        f = get_json(f"{TMDB}/search/tv", {"api_key": keys["tmdb"], "query": title})
        for r in (f or {}).get("results", [])[:6]:
            out.append((r["name"], (r.get("first_air_date") or "")[:4], "tv"))
    return out


def _movie_candidates(title: str, keys: dict) -> list[tuple[str, str, str]]:
    out = []
    if keys.get("tmdb"):
        f = get_json(f"{TMDB}/search/movie", {"api_key": keys["tmdb"], "query": title})
        for r in (f or {}).get("results", [])[:6]:
            out.append((r["title"], (r.get("release_date") or "")[:4], "movie"))
    if not out and keys.get("omdb"):
        f = get_json("https://www.omdbapi.com/",
                     {"apikey": keys["omdb"], "s": title, "type": "movie"})
        for r in (f or {}).get("Search", [])[:6]:
            out.append((r["Title"], r.get("Year", "")[:4], "movie"))
    return out


def collect_candidates(title: str, keys: dict, movie: bool | None = False) -> list[dict]:
    """Title candidates from the mode-appropriate APIs: [{name, year, type}].

    movie=True: movies only. movie=False: TV only. movie=None: auto — the
    reference has no season/episode/year to disambiguate (e.g. a bare "Toy
    Story 3", which is a movie with no parenthesised year), so try both and
    let ranking sort it out.
    """
    seen: set = set()
    cands: list[dict] = []

    def add_all(rows: list[tuple[str, str, str]]) -> None:
        for name, year, typ in rows:
            k = (name.casefold(), typ, year)  # include year: same-titled movies (Dune '84/'21) aren't duplicates
            if name and k not in seen:
                seen.add(k)
                cands.append({"name": name, "year": year, "type": typ})

    if movie is True:
        add_all(_movie_candidates(title, keys))
    elif movie is False:
        add_all(_tv_candidates(title, keys))
    else:
        add_all(_tv_candidates(title, keys))
        add_all(_movie_candidates(title, keys))
    # Rank by closeness to what was typed — TMDB/TVmaze order by their own
    # relevance (often popularity/recency), which can bury the actual best
    # textual match (e.g. "Toy Story 5" ranked above "Toy Story" for a plain
    # "toy story" query).
    cands.sort(key=lambda c: _similar(title, c["name"]), reverse=True)
    return cands


def resolve_title(
    ref: dict, keys: dict, movie: bool | None = False, force_list: bool = False
) -> tuple[str | None, dict | None]:
    """Resolve ref['title'] against the APIs, fixing spelling via Wikipedia if
    nothing matches. On a confident match, updates ref['title'] in place and
    returns (note, None); when ambiguous (or *force_list*) returns
    (None, choices_record) — e.g. "toy story" with force_list shows every
    Toy Story entry instead of auto-picking the closest title match."""
    typed = ref["title"]
    title = typed
    cands = collect_candidates(title, keys, movie)
    corrected = None
    if not cands:
        sug = wiki_suggest(title)
        if sug and sug.casefold() != title.casefold():
            corrected, title = sug, sug
            cands = collect_candidates(title, keys, movie)
    if not cands:
        # Unresolved even after a spelling-suggestion retry — hand back the
        # failed suggestion (if any) so the caller can report it instead of a
        # bare "nothing found".
        return (f'spelling suggestion "{corrected}" also had no matches' if corrected else None), None

    # An explicit year (typed, or already carried on ref from a picker re-query)
    # disambiguates same-titled entries outright — "Dune (1984)" shouldn't
    # re-prompt just because "Dune" (2021) also exists. Skipped when browsing
    # on purpose (force_list) — a year alongside --list still means "show me
    # everything close to this", not "narrow to one".
    if ref.get("year") and not force_list:
        year_matches = [c for c in cands if c["year"] == str(ref["year"])]
        if len(year_matches) == 1:
            cands = year_matches

    if force_list:
        return _build_choices(ref, typed, corrected, cands, cap=20)

    best = cands[0]
    best_sim = _similar(title, best["name"])
    # Anything essentially tied with the best match (within 5%) is real
    # ambiguity — e.g. "Dune" (2021 movie) vs "Dune" (1984 movie), or "office"
    # matching both an exact-title movie and "The Office" (TV, article-stripped
    # exact match). A merely-similar runner-up (a barely-relevant sequel)
    # doesn't count — only near-ties with the top score do.
    rivals = [c for c in cands[1:] if best_sim - _similar(title, c["name"]) <= 0.05]
    if len(cands) == 1 or (not rivals and best_sim >= 0.8):
        note = None
        if best["name"].casefold() != typed.casefold():
            note = f'"{typed}" → "{best["name"]}"' + (
                f' (spelling: "{corrected}")' if corrected else ""
            )
        ref["title"] = best["name"]
        ref["resolved_type"] = best["type"]
        if best["type"] == "movie" and best.get("year") and not ref.get("year"):
            ref["year"] = int(best["year"]) if best["year"].isdigit() else ref["year"]
        return note, None

    # Genuinely ambiguous — hand back a choice list.
    return _build_choices(ref, typed, corrected, cands, cap=8)


def _build_choices(
    ref: dict, typed: str, corrected: str | None, cands: list[dict], cap: int
) -> tuple[None, dict]:
    qual = ""
    if ref["season"] and ref["episode"]:
        qual = f" s{ref['season']:02d}e{ref['episode']:02d}"
    elif ref["season"]:
        qual = f" s{ref['season']:02d}"
    elif ref["episode"]:
        qual = f" episode {ref['episode']}"
    rest = f" {ref['rest']}" if ref.get("rest") else ""
    for c in cands:
        c.pop("_kind_ambiguous", None)
        year = f" ({c['year']})" if c["year"] else ""
        c["requery"] = f"{c['name']}{year}{qual}{rest}"
    return None, {
        "kind": "choices",
        "query": typed,
        "corrected": corrected,
        "candidates": cands[:cap],
    }


# ---------------------------------------------------------------- TV (TVmaze)

def _tv_seasons(show_id: int) -> list[dict]:
    seasons = get_json(f"{TVMAZE}/shows/{show_id}/seasons") or []
    return [
        {
            "number": s["number"],
            "episode_count": s.get("episodeOrder"),
            "premiered": s.get("premiereDate"),
        }
        for s in seasons
        if s.get("number") is not None
    ]


def _pick_tvmaze_show(title: str, year: int | None = None) -> dict | None:
    """Best TVmaze match for *title* — honouring *year* so same-titled shows
    ("The Office" 2001 vs 2005) resolve to the one actually asked for instead
    of whichever TVmaze ranks first."""
    matches = get_json(f"{TVMAZE}/search/shows", {"q": title}) or []
    if year:
        for m in matches:
            if (m["show"].get("premiered") or "")[:4] == str(year):
                return m["show"]
    return matches[0]["show"] if matches else None


def tv_cast(ref: dict, keys: dict | None = None) -> dict | None:
    show = _pick_tvmaze_show(ref["title"], ref.get("year"))
    resolved_via = None
    if not show and keys and keys.get("tmdb"):
        # TVmaze search is not typo/abbreviation tolerant ("star trek next gen"
        # finds nothing) — resolve the canonical title via TMDB and retry.
        found = get_json(
            f"{TMDB}/search/tv", {"api_key": keys["tmdb"], "query": ref["title"]}
        )
        if found and found.get("results"):
            canonical = found["results"][0]["name"]
            show = _pick_tvmaze_show(canonical, ref.get("year"))
            if show:
                resolved_via = f'"{ref["title"]}" → "{canonical}" (TMDB)'
    if not show:
        return None
    out = {
        "resolved_via": resolved_via,
        "kind": "tv",
        "show": show["name"],
        "show_id": show["id"],
        "premiered": show.get("premiered"),
        "url": show.get("url"),
        "main_cast": [],
        "guest_cast": [],
    }
    cast = get_json(f"{TVMAZE}/shows/{show['id']}/cast") or []
    out["main_cast"] = [
        {"character": c["character"]["name"], "actor": c["person"]["name"]} for c in cast
    ]
    if ref["season"] and ref["episode"]:
        ep = get_json(
            f"{TVMAZE}/shows/{show['id']}/episodebynumber",
            {"season": ref["season"], "number": ref["episode"]},
        )
        if ep:
            out["episode"] = f"S{ref['season']:02d}E{ref['episode']:02d} — {ep['name']}"
            out["airdate"] = ep.get("airdate")
            out["episode_summary"] = re.sub(r"<[^>]+>", "", ep.get("summary") or "") or None
            guests = get_json(f"{TVMAZE}/episodes/{ep['id']}/guestcast") or []
            out["guest_cast"] = [
                {"character": g["character"]["name"], "actor": g["person"]["name"]}
                for g in guests
            ]
        else:
            out["episode"] = (
                f"S{ref['season']:02d}E{ref['episode']:02d} — not found on TVmaze"
            )
    elif ref["season"]:
        # Season-only reference: list that season's episodes alongside the main cast.
        eps = get_json(f"{TVMAZE}/shows/{show['id']}/episodes") or []
        out["season"] = ref["season"]
        out["episodes"] = [
            {"number": e["number"], "name": e["name"], "airdate": e.get("airdate")}
            for e in eps
            if e.get("season") == ref["season"]
        ]
    else:
        # Bare series query — surface the season list so it can be browsed
        # instead of requiring the user to already know a season exists.
        out["seasons"] = _tv_seasons(show["id"])
    return out


def find_character(ref: dict, character: str, keys: dict) -> dict | None:
    """Who played *character*? Match against the episode (or whole-show) cast,
    then return that actor's credits."""
    tv = tv_cast(ref, keys)
    if not tv:
        return None
    pool = tv["guest_cast"] + tv["main_cast"]
    cq = character.casefold()
    match = next(
        (
            c
            for c in pool
            if cq in c["character"].casefold() or c["character"].casefold() in cq
        ),
        None,
    )
    if not match:
        import difflib

        names = [c["character"] for c in pool]
        close = difflib.get_close_matches(character, names, n=1, cutoff=0.6)
        if close:
            match = next(c for c in pool if c["character"] == close[0])
    if not match and not ref["season"] and not ref["episode"]:
        # Not a character — maybe an episode remembered by title ("the office
        # dinner party"). High bar (0.8) so a vague word like "party" doesn't
        # confidently land on one of several party episodes.
        eps = get_json(f"{TVMAZE}/shows/{tv['show_id']}/episodes") or []
        best = max(eps, key=lambda e: _similar(character, e.get("name") or ""), default=None)
        if best and _similar(character, best.get("name") or "") >= 0.8:
            eref = dict(ref, season=best["season"], episode=best["number"])
            out = tv_cast(eref, keys)
            if out:
                out["resolved_via"] = f'"{character}" → episode "{best["name"]}"'
                return out
    if not match:
        qual = ""
        if ref["season"] and ref["episode"]:
            qual = f" s{ref['season']:02d}e{ref['episode']:02d}"
        elif ref["season"]:
            qual = f" s{ref['season']:02d}"
        return {
            "kind": "actor",
            "name": None,
            "error": f'No character matching "{character}" in {tv["show"]}'
            + (f' {tv["episode"]}' if tv.get("episode") else ""),
            "show": tv["show"],
            # Lets the GUI make each listed character a clickable retry.
            "requery_prefix": f"{tv['show']}{qual}",
            "characters_seen": [c["character"] for c in pool],
        }
    out = actor_credits(match["actor"], keys) or {"kind": "actor", "name": match["actor"]}
    out["character_match"] = {
        "character": match["character"],
        "actor": match["actor"],
        "show": tv["show"],
        "episode": tv.get("episode"),
    }
    return out


def character_fallback(raw: str, keys: dict) -> dict | None:
    """Last resort for "show + character" with no episode ("chicago pd voight"):
    peel trailing word(s) off as a character name and match against the show's
    cast — the natural couch question doesn't come with an episode number."""
    words = raw.split()
    miss = None
    for n in (1, 2):
        if len(words) <= n:
            break
        show_part = " ".join(words[:-n])
        char_part = " ".join(words[-n:])
        result = find_character(parse_ref(show_part), char_part, keys)
        if result and not result.get("error"):
            return result
        # Keep a character-miss only when the show itself was a solid match —
        # otherwise a typo'd actor name would surface some random show's cast.
        if result and miss is None and _similar(show_part, result.get("show") or "") >= 0.6:
            miss = result
    return miss


# ------------------------------------------------------------ movies (OMDb / TMDB)

def movie_cast(ref: dict, keys: dict) -> dict | None:
    # TMDB first (full credits), OMDb as fallback (top 4 actors).
    if keys.get("tmdb"):
        params = {"api_key": keys["tmdb"], "query": ref["title"]}
        if ref["year"]:
            params["year"] = ref["year"]
        found = get_json(f"{TMDB}/search/movie", params)
        if found and found.get("results"):
            mid = found["results"][0]["id"]
            credits = get_json(f"{TMDB}/movie/{mid}/credits", {"api_key": keys["tmdb"]})
            if credits:
                others = [
                    f"{r['title']} ({(r.get('release_date') or '?')[:4]})"
                    for r in found["results"][1:6]
                ]
                return {
                    "kind": "movie",
                    "title": found["results"][0]["title"],
                    "released": found["results"][0].get("release_date"),
                    "source": "TMDB",
                    "url": f"https://www.themoviedb.org/movie/{mid}",
                    "plot": found["results"][0].get("overview") or None,
                    "other_matches": others,
                    "cast": [
                        {"character": c.get("character", ""), "actor": c["name"]}
                        for c in credits.get("cast", [])[:25]
                    ],
                }
    if keys.get("omdb"):
        params = {"apikey": keys["omdb"], "t": ref["title"]}
        if ref["year"]:
            params["y"] = ref["year"]
        data = get_json("https://www.omdbapi.com/", params)
        if data and data.get("Response") == "True":
            return {
                "kind": "movie",
                "title": data["Title"],
                "released": data.get("Released"),
                "source": "OMDb",
                "url": f"https://www.imdb.com/title/{data['imdbID']}/" if data.get("imdbID") else None,
                "cast": [
                    {"character": "", "actor": a.strip()}
                    for a in data.get("Actors", "").split(",")
                    if a.strip()
                ],
                "plot": data.get("Plot"),
            }
    return None


# ---------------------------------------------------------------- actor

def _tvmaze_person_candidates(name: str) -> list[dict]:
    out = []
    for r in get_json(f"{TVMAZE}/search/people", {"q": name}) or []:
        p = r["person"]
        out.append({
            "name": p["name"], "detail": f"b. {p['birthday']}" if p.get("birthday") else "",
            "source": "tvmaze", "tvmaze_id": p["id"], "tmdb_id": None, "popularity": 0.0,
        })
    return out


def _tmdb_person_candidates(name: str, keys: dict) -> list[dict]:
    out = []
    if not keys.get("tmdb"):
        return out
    found = get_json(f"{TMDB}/search/person", {"api_key": keys["tmdb"], "query": name})
    for r in (found or {}).get("results", [])[:10]:
        known = ", ".join(
            (k.get("title") or k.get("name", "")) for k in r.get("known_for", [])[:2]
        )
        out.append({
            "name": r["name"], "detail": f"known for {known}" if known else "",
            "source": "tmdb", "tvmaze_id": None, "tmdb_id": r["id"],
            "popularity": float(r.get("popularity") or 0),
        })
    return out


def collect_person_candidates(name: str, keys: dict) -> list[dict]:
    """Merge TVmaze + TMDB person candidates, deduped by name.

    Ranked by TMDB popularity, not text similarity — for a partial/surname-only
    query ("cranston"), every candidate matches the text about equally well
    (they all contain "Cranston"); popularity is what actually distinguishes
    Bryan Cranston from a dozen unrelated extras sharing the surname.
    """
    seen: set = set()
    cands: list[dict] = []
    for c in _tvmaze_person_candidates(name) + _tmdb_person_candidates(name, keys):
        k = c["name"].casefold()
        if k in seen:
            # Merge: keep the richer detail/popularity, note both ids.
            existing = next(x for x in cands if x["name"].casefold() == k)
            if c["tmdb_id"] is not None:
                existing["tmdb_id"] = c["tmdb_id"]
                existing["popularity"] = max(existing["popularity"], c["popularity"])
            if c["tvmaze_id"] is not None:
                existing["tvmaze_id"] = c["tvmaze_id"]
            if c["detail"] and not existing["detail"]:
                existing["detail"] = c["detail"]
            continue
        seen.add(k)
        cands.append(c)
    cands.sort(key=lambda c: (c["popularity"], _similar(name, c["name"])), reverse=True)
    return cands


def resolve_person(
    name: str, keys: dict, force_list: bool = False
) -> tuple[str | None, dict | None, dict | None]:
    """Resolve a (possibly partial) actor name. Returns (note, choices, winner)
    where winner carries the ids needed to fetch credits without re-searching
    by name (and re-triggering the same ambiguity)."""
    typed = name
    cands = collect_person_candidates(name, keys)
    corrected = None
    if not cands:
        sug = wiki_suggest(name)
        if sug and sug.casefold() != name.casefold():
            corrected, name = sug, sug
            cands = collect_person_candidates(name, keys)
    if not cands:
        note = f'spelling suggestion "{corrected}" also had no matches' if corrected else None
        return note, None, None

    if not force_list:
        best = cands[0]
        best_sim = _similar(name, best["name"])
        second_pop = cands[1]["popularity"] if len(cands) > 1 else 0.0
        # Dominant: this candidate is far more notable than the runner-up —
        # the actual signal that "cranston" means Bryan Cranston, since text
        # similarity alone can't tell him apart from namesake extras.
        dominant = best["popularity"] >= 1.0 and (
            second_pop == 0 or best["popularity"] / max(second_pop, 0.01) >= 3
        )
        # No popularity data at all (no TMDB key, or TVmaze-only hits) — fall
        # back to the same near-tie-on-text-similarity test used for titles.
        no_signal = best["popularity"] == 0 and all(c["popularity"] == 0 for c in cands)
        rivals = [c for c in cands[1:] if best_sim - _similar(name, c["name"]) <= 0.05]
        confident = len(cands) == 1 or best_sim >= 0.95 or dominant or (
            no_signal and not rivals and best_sim >= 0.6
        )
        if confident:
            note = None
            if best["name"].casefold() != typed.casefold():
                note = f'"{typed}" → "{best["name"]}"' + (
                    f' (spelling: "{corrected}")' if corrected else ""
                )
            return note, None, best

    for c in cands:
        c["requery"] = c["name"]
    return None, {
        "kind": "choices",
        "choice_of": "actor",
        "query": typed,
        "corrected": corrected,
        "candidates": cands[:20 if force_list else 8],
    }, None


def actor_credits(name: str, keys: dict, winner: dict | None = None) -> dict | None:
    """Fetch credits for an actor. *winner*, if given, carries the ids already
    resolved by resolve_person — using them avoids re-searching by *name*,
    which for a partial/ambiguous name would just reintroduce the ambiguity."""
    out = None
    tvmaze_id = winner["tvmaze_id"] if winner else None
    tmdb_id = winner["tmdb_id"] if winner else None
    resolved_name = winner["name"] if winner else name

    if tvmaze_id is None:
        # Search by the already-resolved name (e.g. "Tom Hanks"), not the raw,
        # possibly-partial input ("tom han") — searching by the latter here
        # would silently reintroduce the exact ambiguity resolve_person just
        # settled, and can land on a totally different, unrelated person.
        people = get_json(f"{TVMAZE}/search/people", {"q": resolved_name}) or []
        if people and _similar(resolved_name, people[0]["person"]["name"]) >= 0.9:
            tvmaze_id = people[0]["person"]["id"]
            resolved_name = people[0]["person"]["name"]
    if tvmaze_id is not None:
        p = get_json(f"{TVMAZE}/people/{tvmaze_id}") or {}
        credits = (
            get_json(
                f"{TVMAZE}/people/{tvmaze_id}/castcredits",
                {"embed[]": ["show", "character"]},
            )
            or []
        )
        out = {
            "kind": "actor",
            "name": p.get("name", resolved_name),
            "birthday": p.get("birthday"),
            "deathday": p.get("deathday"),
            "url": p.get("url"),
            "tv_credits": [
                {
                    "show": c["_embedded"]["show"]["name"],
                    "character": c["_embedded"]["character"]["name"],
                    "premiered": c["_embedded"]["show"].get("premiered"),
                }
                for c in credits
            ],
        }

    if tmdb_id is None and keys.get("tmdb"):
        found = get_json(
            f"{TMDB}/search/person", {"api_key": keys["tmdb"], "query": resolved_name}
        )
        if found and found.get("results"):
            tmdb_id = found["results"][0]["id"]
            resolved_name = found["results"][0]["name"]
    if tmdb_id is not None:
        mc = get_json(f"{TMDB}/person/{tmdb_id}/movie_credits", {"api_key": keys["tmdb"]})
        if mc:
            movies = sorted(
                (c for c in mc.get("cast", []) if c.get("release_date")),
                key=lambda c: c["release_date"],
                reverse=True,
            )
            out = out or {"kind": "actor", "name": resolved_name, "tv_credits": []}
            out["movie_credits"] = [
                {
                    "title": c["title"],
                    "character": c.get("character", ""),
                    "released": c["release_date"],
                }
                for c in movies[:40]
            ]
    return out


# ---------------------------------------------------------------- show info

def show_info(query: str, keys: dict | None = None, year: int | None = None) -> dict | None:
    matches = get_json(f"{TVMAZE}/search/shows", {"q": query}) or []
    if not matches and keys and keys.get("tmdb"):
        # Same abbreviation fallback as tv_cast: resolve the title via TMDB, retry.
        found = get_json(f"{TMDB}/search/tv", {"api_key": keys["tmdb"], "query": query})
        if found and found.get("results"):
            matches = get_json(
                f"{TVMAZE}/search/shows", {"q": found["results"][0]["name"]}
            ) or []
    if not matches:
        return None
    show = matches[0]["show"]
    if year:
        # Same-titled shows ("The Office" 2001/2005): an explicit year picks
        # the right one instead of whichever TVmaze ranks first.
        for m in matches:
            if (m["show"].get("premiered") or "")[:4] == str(year):
                show = m["show"]
                break
    others = [
        f"{m['show']['name']} ({(m['show'].get('premiered') or '?')[:4]})"
        for m in matches
        if m["show"]["id"] != show["id"]
    ][:5]
    summary = re.sub(r"<[^>]+>", "", show.get("summary") or "")
    return {
        "kind": "show",
        "query": query,
        "other_matches": others,
        "show": show["name"],
        "premiered": show.get("premiered"),
        "status": show.get("status"),
        "network": (show.get("network") or show.get("webChannel") or {}).get("name"),
        "genres": show.get("genres"),
        "summary": summary,
        "url": show.get("url"),
        "seasons": _tv_seasons(show["id"]),
    }


# ---------------------------------------------------------------- output

def print_pairs(rows: list[dict], left: str, right: str) -> None:
    if not rows:
        return
    width = max(len(r[left]) for r in rows)
    for r in rows:
        print(f"  {r[left]:<{width}}  {r[right]}")


def render(result: dict) -> None:
    kind = result["kind"]
    if kind == "choices":
        print(f'Multiple possible matches for "{result["query"]}"'
              + (f' (spelling suggestion: "{result["corrected"]}")' if result.get("corrected") else "")
              + ":")
        for i, c in enumerate(result["candidates"], 1):
            if result.get("choice_of") == "actor":
                detail = f"  ({c['detail']})" if c.get("detail") else ""
                print(f"  {i}. {c['name']}{detail}  →  re-run with: {c['requery']}")
            else:
                year = f" ({c['year']})" if c["year"] else ""
                print(f"  {i}. [{c['type']}] {c['name']}{year}  →  re-run with: {c['requery']}")
        return
    if kind == "tv":
        if result.get("resolved_via"):
            print(f"Resolved: {result['resolved_via']}")
        print(f"{result['show']} ({(result.get('premiered') or '?')[:4]})")
        if result.get("episode"):
            print(f"Episode: {result['episode']}  ({result.get('airdate') or 'no airdate'})")
            if result.get("episode_summary"):
                print(result["episode_summary"])
            if result["guest_cast"]:
                print("\nGuest cast:")
                print_pairs(result["guest_cast"], "character", "actor")
        if result.get("episodes") is not None:
            print(f"\nSeason {result['season']} episodes:")
            for e in result["episodes"]:
                print(f"  E{e['number']:02d}  {e['name']}  ({e.get('airdate') or 'no airdate'})")
        if result.get("seasons"):
            print(f"\nSeasons ({len(result['seasons'])}):")
            for s in result["seasons"]:
                ec = f", {s['episode_count']} episodes" if s.get("episode_count") else ""
                print(f"  Season {s['number']}  ({(s.get('premiered') or '?')[:4]}{ec})")
        print("\nMain cast:")
        print_pairs(result["main_cast"], "character", "actor")
        if result.get("url"):
            print(f"\nSource: {result['url']}")
    elif kind == "movie":
        if result.get("resolved_via"):
            print(f"Resolved: {result['resolved_via']}")
        print(f"{result['title']}  (released {result.get('released')})  [{result['source']}]")
        if result.get("plot"):
            print(result["plot"])
        print("\nCast:")
        print_pairs(result["cast"], "actor", "character")
        if result.get("other_matches"):
            print("\nNot it? Other matches:", " · ".join(result["other_matches"]))
    elif kind == "actor":
        if result.get("error"):
            print(result["error"])
            if result.get("characters_seen"):
                print("Characters found:", ", ".join(result["characters_seen"]))
            return
        cm = result.get("character_match")
        if cm:
            where = f" in {cm['show']}" + (f" {cm['episode']}" if cm.get("episode") else "")
            print(f"{cm['character']}{where} was played by {cm['actor']}\n")
        if result.get("resolved_via"):
            print(f"Resolved: {result['resolved_via']}")
        bd = f"b. {result['birthday']}" if result.get("birthday") else ""
        dd = f"d. {result['deathday']}" if result.get("deathday") else ""
        detail = ", ".join(x for x in (bd, dd) if x)
        print(result["name"] + (f"  ({detail})" if detail else ""))
        if result.get("tv_credits"):
            print("\nTV (TVmaze):")
            for c in result["tv_credits"]:
                print(f"  {c['show']} ({(c.get('premiered') or '?')[:4]}) — {c['character']}")
        if result.get("movie_credits"):
            print("\nMovies (TMDB):")
            for c in result["movie_credits"]:
                print(f"  {c['title']} ({c['released'][:4]}) — {c['character']}")
    elif kind == "show":
        print(f"{result['show']} ({(result.get('premiered') or '?')[:4]}) — {result.get('status')}")
        if result.get("network"):
            print(f"Network: {result['network']}")
        if result.get("genres"):
            print(f"Genres: {', '.join(result['genres'])}")
        if result.get("summary"):
            print(f"\n{result['summary']}")
        if result.get("seasons"):
            print(f"\nSeasons ({len(result['seasons'])}):")
            for s in result["seasons"]:
                ec = f", {s['episode_count']} episodes" if s.get("episode_count") else ""
                print(f"  Season {s['number']}  ({(s.get('premiered') or '?')[:4]}{ec})")
        print(f"\nCast: re-run with --cast \"{result['show']}\"")
        if result.get("other_matches"):
            print("\nOther matches:", " · ".join(result["other_matches"]))
        if result.get("url"):
            print(f"\nSource: {result['url']}")


def main() -> int:
    p = argparse.ArgumentParser(description="Cast/actor/show lookup via TVmaze, OMDb, TMDB")
    p.add_argument("query", nargs="*", help="show title (info mode)")
    p.add_argument("--cast", metavar="REF", help='e.g. "hope street s01e03", "the godfather (1972)"')
    p.add_argument("--actor", metavar="REF",
                   help='actor name, or show + character ("chicago pd voight", '
                        '"medium s1e1 joe") to find who played them')
    p.add_argument("--movie", action="store_true", help="with --cast: force movie lookup")
    p.add_argument("--list", action="store_true", dest="list_matches",
                   help="show every match instead of auto-picking the best one "
                        '("toy story" --list → all Toy Story movies; "cranston" --list → every Cranston)')
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args()

    keys = load_keys()
    start = time.time()
    note = None

    if args.cast:
        ref = parse_ref(args.cast)
        if args.movie:
            resolve_as: bool | None = True
        elif ref["season"] or ref["episode"]:
            resolve_as = False
        else:
            # No season/episode to disambiguate — e.g. "Toy Story 3" is a
            # movie with no parenthesised year, and a parenthesised year alone
            # doesn't imply movie either ("The Office (2005)" is TV). Search
            # both kinds and let ranking/year-matching sort it out, rather than
            # assuming one kind and never trying the other.
            resolve_as = None
        note, choices = resolve_title(ref, keys, movie=resolve_as, force_list=args.list_matches)
        if choices:
            result = choices
        elif ref["rest"] and (ref["season"] or ref["episode"]):
            # Trailing text after the episode is a character name — same behaviour
            # as --actor, so either mode accepts "medium s0101 george".
            result = find_character(ref, ref["rest"], keys)
        elif args.movie:
            result = movie_cast(ref, keys)  # forced movie: no silent TV fallback
        elif ref.get("resolved_type") == "movie":
            result = movie_cast(ref, keys)
        elif ref.get("resolved_type") == "tv":
            result = tv_cast(ref, keys)
        else:
            # Unresolved by resolve_title (no API candidates at all) — last-ditch
            # attempt against both, in the order the reference itself implies.
            result = (
                (movie_cast(ref, keys) or tv_cast(ref, keys))
                if resolve_as
                else (tv_cast(ref, keys) or movie_cast(ref, keys))
            )
            if not result:
                # Maybe "show + character" typed into cast mode.
                result = character_fallback(args.cast, keys)
        if result and note and not result.get("resolved_via"):
            result["resolved_via"] = note
    elif args.actor:
        aref = parse_ref(args.actor)
        if aref["rest"] and (aref["season"] or aref["episode"]):
            # "Medium S4E10 Cynthia" — find who played the character, then credits.
            result = find_character(aref, aref["rest"], keys)
        else:
            note, choices, winner = resolve_person(args.actor, keys, force_list=args.list_matches)
            if choices:
                result = choices
            else:
                result = actor_credits(args.actor, keys, winner)
                if result and note:
                    result["resolved_via"] = note
                if not result:
                    # Not a person — maybe "show + character" ("chicago pd voight").
                    result = character_fallback(args.actor, keys)
    elif args.query:
        sref = parse_ref(" ".join(args.query))
        # No mode flag here to say TV vs movie — try both and let ranking sort
        # it out, same as a bare --cast title with no year.
        note, choices = resolve_title(sref, keys, movie=None, force_list=args.list_matches)
        if choices:
            result = choices
        elif sref.get("resolved_type") == "movie":
            result = movie_cast(sref, keys)
            if result and note:
                result["resolved_via"] = note
        else:
            result = show_info(sref["title"], keys, sref.get("year"))
            if result and note:
                result["resolved_via"] = note
    else:
        p.print_help()
        return 2

    if not result:
        looked_for = args.cast or args.actor or " ".join(args.query)
        print(f'Nothing found for "{looked_for}"'
              + (f' (searched title: "{parse_ref(looked_for)["title"]}")' if args.cast else "")
              + (f" — {note}" if note else "")
              + ".", file=sys.stderr)
        return 1

    result["elapsed"] = round(time.time() - start, 2)
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        render(result)
        print(f"\n({result['elapsed']}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
