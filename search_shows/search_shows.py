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
        r = requests.get(url, params=params, timeout=TIMEOUT)
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

    y = YEAR_RE.search(text)
    if y:
        ref["year"] = int(y.group(1))
        ref["title"] = _clean_title(YEAR_RE.sub("", text)).strip("()")
    return ref


# ---------------------------------------------------------------- TV (TVmaze)

def tv_cast(ref: dict) -> dict | None:
    show = get_json(f"{TVMAZE}/singlesearch/shows", {"q": ref["title"]})
    if not show:
        return None
    out = {
        "kind": "tv",
        "show": show["name"],
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
    return out


def find_character(ref: dict, character: str, keys: dict) -> dict | None:
    """Who played *character*? Match against the episode (or whole-show) cast,
    then return that actor's credits."""
    tv = tv_cast(ref)
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
    if not match:
        return {
            "kind": "actor",
            "name": None,
            "error": f'No character matching "{character}" in {tv["show"]}'
            + (f' {tv["episode"]}' if tv.get("episode") else ""),
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
                return {
                    "kind": "movie",
                    "title": found["results"][0]["title"],
                    "released": found["results"][0].get("release_date"),
                    "source": "TMDB",
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
                "cast": [
                    {"character": "", "actor": a.strip()}
                    for a in data.get("Actors", "").split(",")
                    if a.strip()
                ],
                "plot": data.get("Plot"),
            }
    return None


# ---------------------------------------------------------------- actor

def actor_credits(name: str, keys: dict) -> dict | None:
    out = None
    people = get_json(f"{TVMAZE}/search/people", {"q": name}) or []
    if people:
        p = people[0]["person"]
        credits = (
            get_json(
                f"{TVMAZE}/people/{p['id']}/castcredits",
                {"embed[]": ["show", "character"]},
            )
            or []
        )
        out = {
            "kind": "actor",
            "name": p["name"],
            "birthday": p.get("birthday"),
            "tv_credits": [
                {
                    "show": c["_embedded"]["show"]["name"],
                    "character": c["_embedded"]["character"]["name"],
                    "premiered": c["_embedded"]["show"].get("premiered"),
                }
                for c in credits
            ],
        }
    if keys.get("tmdb"):
        found = get_json(
            f"{TMDB}/search/person", {"api_key": keys["tmdb"], "query": name}
        )
        if found and found.get("results"):
            pid = found["results"][0]["id"]
            mc = get_json(
                f"{TMDB}/person/{pid}/movie_credits", {"api_key": keys["tmdb"]}
            )
            if mc:
                movies = sorted(
                    (c for c in mc.get("cast", []) if c.get("release_date")),
                    key=lambda c: c["release_date"],
                    reverse=True,
                )
                out = out or {"kind": "actor", "name": found["results"][0]["name"], "tv_credits": []}
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

def show_info(query: str) -> dict | None:
    show = get_json(f"{TVMAZE}/singlesearch/shows", {"q": query})
    if not show:
        return None
    summary = re.sub(r"<[^>]+>", "", show.get("summary") or "")
    return {
        "kind": "show",
        "show": show["name"],
        "premiered": show.get("premiered"),
        "status": show.get("status"),
        "network": (show.get("network") or show.get("webChannel") or {}).get("name"),
        "genres": show.get("genres"),
        "summary": summary,
        "url": show.get("url"),
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
    if kind == "tv":
        print(f"{result['show']} ({(result.get('premiered') or '?')[:4]})")
        if result.get("episode"):
            print(f"Episode: {result['episode']}  ({result.get('airdate') or 'no airdate'})")
            if result["guest_cast"]:
                print("\nGuest cast:")
                print_pairs(result["guest_cast"], "character", "actor")
        if result.get("episodes") is not None:
            print(f"\nSeason {result['season']} episodes:")
            for e in result["episodes"]:
                print(f"  E{e['number']:02d}  {e['name']}  ({e.get('airdate') or 'no airdate'})")
        print("\nMain cast:")
        print_pairs(result["main_cast"], "character", "actor")
        if result.get("url"):
            print(f"\nSource: {result['url']}")
    elif kind == "movie":
        print(f"{result['title']}  (released {result.get('released')})  [{result['source']}]")
        if result.get("plot"):
            print(result["plot"])
        print("\nCast:")
        print_pairs(result["cast"], "actor", "character")
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
        print(result["name"] + (f"  (b. {result['birthday']})" if result.get("birthday") else ""))
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
        if result.get("url"):
            print(f"\nSource: {result['url']}")


def main() -> int:
    p = argparse.ArgumentParser(description="Cast/actor/show lookup via TVmaze, OMDb, TMDB")
    p.add_argument("query", nargs="*", help="show title (info mode)")
    p.add_argument("--cast", metavar="REF", help='e.g. "hope street s01e03", "the godfather (1972)"')
    p.add_argument("--actor", metavar="NAME", help="actor name for credits")
    p.add_argument("--movie", action="store_true", help="with --cast: force movie lookup")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args()

    keys = load_keys()
    start = time.time()

    if args.cast:
        ref = parse_ref(args.cast)
        if args.movie or (ref["year"] and not ref["season"]):
            result = movie_cast(ref, keys) or tv_cast(ref)
        else:
            result = tv_cast(ref) or movie_cast(ref, keys)
    elif args.actor:
        aref = parse_ref(args.actor)
        if aref["rest"] and (aref["season"] or aref["episode"]):
            # "Medium S4E10 Cynthia" — find who played the character, then credits.
            result = find_character(aref, aref["rest"], keys)
        else:
            result = actor_credits(args.actor, keys)
    elif args.query:
        result = show_info(" ".join(args.query))
    else:
        p.print_help()
        return 2

    if not result:
        print("Nothing found.", file=sys.stderr)
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
