# show_resolver.py — Resolve a fuzzy show title to a canonical name
# 2026-07-15 19:10 UTC — pre-scan entity resolution via TVmaze (adopt-if-close)
# 2026-07-15 20:00 UTC — layered resolver: TVmaze first, then a forgiving DDG fallback
#                        (TVmaze search is literal — 404s on "star trek next gen"; DDG
#                        corrects abbreviations/typos, e.g. "star trel mext gem" → TNG),
#                        re-validated against TVmaze for the canonical name + year
# 2026-07-15 20:15 UTC — corroboration gate: adopt a DDG resolution only when >=2 top
#                        results agree (else the top junk hit wins, e.g. hope st→Honest);
#                        raised direct TVmaze adopt threshold to 0.85 (st-tng→Strong fluke)

from __future__ import annotations

import difflib
import logging
import re
from dataclasses import dataclass

import requests

from search import search

logger = logging.getLogger(__name__)

_TVMAZE_SEARCH = "https://api.tvmaze.com/search/shows"
_TVMAZE_SINGLE = "https://api.tvmaze.com/singlesearch/shows"
_TIMEOUT = 5

# Similarity to ADOPT a direct TVmaze match without the DDG fallback. High, because
# short strings produce fluke matches (st-tng↔Strong ≈ 0.73). Below this we try DDG.
ADOPT_DIRECT = 0.85
# Minimum number of agreeing top DDG results to trust a fuzzy correction.
DDG_AGREEMENT = 2

# Strip "- Wikipedia" / "| IMDb" / "(TV Series 1987–1994) - IMDb" tails from a result title.
_TITLE_TAIL = re.compile(r"\s*[-–—|]\s*(Wikipedia|IMDb|IMDB|TMDB|Fandom|Memory Alpha).*$", re.I)
_TVSERIES_PAREN = re.compile(r"\s*\((?:TV\s+(?:Mini[- ]?)?Series|TV)\b[^)]*\).*$", re.I)
_YEAR_IN_TITLE = re.compile(r"\b(19\d{2}|20\d{2})\b")
# Trailing "tv series"/"tv show" descriptor left on bare result titles.
_TV_DESCRIPTOR = re.compile(r"\s*[-–—|(]*\s*tv\s+(?:series|show|mini[- ]?series)\)?\s*$", re.I)
# Result titles that are not the show's own page, or are site/social noise.
_SKIP_TITLE = re.compile(
    r"^\s*(list of|watch|category:|talk:|file:)|episodes?\b|cast members|characters\b"
    r"|youtube|tiktok|instagram|facebook|reddit|amazon|\.com|\|",
    re.I,
)


@dataclass
class ShowMatch:
    """A resolved canonical show."""

    name: str
    year: str | None
    tvmaze_id: int | None
    similarity: float       # normalized-title similarity to the typed title, [0, 1]
    adopted: bool           # True if confident enough to search with this name
    source: str = "TVmaze"  # how it was resolved: "TVmaze", "DDG→TVmaze", or "DDG"


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()


def _sim(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, _norm(a), _norm(b)).ratio()


def _tvmaze_best(title: str, timeout: int) -> ShowMatch | None:
    """Best TVmaze /search hit by similarity to *title* (None on failure/no results)."""
    try:
        resp = requests.get(_TVMAZE_SEARCH, params={"q": title}, timeout=timeout)
        resp.raise_for_status()
        results = resp.json()
    except (requests.RequestException, ValueError) as exc:
        logger.debug("TVmaze search failed for %r: %s", title, exc)
        return None
    best: ShowMatch | None = None
    for item in results or []:
        show = item.get("show") or {}
        name = show.get("name") or ""
        if not name:
            continue
        sim = _sim(title, name)
        if best is None or sim > best.similarity:
            premiered = show.get("premiered") or ""
            # adopted decided by resolve_show (against ADOPT_DIRECT); placeholder here.
            best = ShowMatch(name, premiered[:4] or None, show.get("id"), sim, False)
    return best


def _tvmaze_singlesearch(name: str, timeout: int) -> ShowMatch | None:
    """Confirm/canonicalise *name* via TVmaze singlesearch (None if unknown)."""
    try:
        resp = requests.get(_TVMAZE_SINGLE, params={"q": name}, timeout=timeout)
        if resp.status_code != 200:
            return None
        show = resp.json()
    except (requests.RequestException, ValueError) as exc:
        logger.debug("TVmaze singlesearch failed for %r: %s", name, exc)
        return None
    canon = show.get("name") or ""
    if not canon:
        return None
    premiered = show.get("premiered") or ""
    return ShowMatch(canon, premiered[:4] or None, show.get("id"), 1.0, True)


def _clean_show_title(result_title: str) -> tuple[str, str | None] | None:
    """Extract (show name, year) from a search-result title, or None if unusable."""
    if not result_title or _SKIP_TITLE.search(result_title):
        return None
    year_m = _YEAR_IN_TITLE.search(result_title)
    year = year_m.group(1) if year_m else None
    name = _TVSERIES_PAREN.sub("", result_title)
    name = _TITLE_TAIL.sub("", name).strip()
    name = _TV_DESCRIPTOR.sub("", name).strip()
    # Drop a trailing bare year if it leaked through.
    name = re.sub(r"\s*\(?\b(?:19|20)\d{2}\b\)?\s*$", "", name).strip()
    if len(name) < 2 or _SKIP_TITLE.search(name):
        return None
    return name, year


def _resolve_via_ddg(title: str) -> tuple[str, str | None] | None:
    """
    Corroborated canonical name from the web: (name, year), or None.

    DDG tolerates typos/abbreviations, but its top hit alone can be junk
    ("hope st" → "Honest"). So only trust a name that >= DDG_AGREEMENT of the top
    results agree on — genuine corrections ("star trel mext gem" → TNG) recur,
    ambiguous input does not.
    """
    try:
        results = search(f"{title} tv series", max_results=5)
    except Exception as exc:  # noqa: BLE001
        logger.debug("DDG resolution search failed for %r: %s", title, exc)
        return None

    cleaned = [c for c in (_clean_show_title(r.title or "") for r in results) if c]
    if not cleaned:
        return None

    counts: dict[str, int] = {}
    display: dict[str, tuple[str, str | None]] = {}
    for name, year in cleaned:
        key = _norm(name)
        counts[key] = counts.get(key, 0) + 1
        display.setdefault(key, (name, year))
        if year and display[key][1] is None:  # prefer a variant that carries a year
            display[key] = (name, year)

    key, n = max(counts.items(), key=lambda kv: kv[1])
    if n < DDG_AGREEMENT:
        logger.debug("DDG resolution for %r not corroborated (best agree=%d)", title, n)
        return None
    logger.debug("DDG corroborated %r → %r (agree=%d)", title, display[key][0], n)
    return display[key]


def resolve_show(title: str, timeout: int = _TIMEOUT) -> ShowMatch | None:
    """
    Resolve *title* to a canonical show. Layered:

    1. TVmaze /search — adopt on a strong match (fast, authoritative for clean names).
    2. Otherwise a corroborated DDG lookup (forgiving of abbreviations/typos),
       re-validated against TVmaze for the canonical name + year.
    3. Otherwise return the best weak TVmaze match (or None) for the caller to
       surface as a suggestion / stop.
    """
    title = (title or "").strip()
    if not title:
        return None

    tv = _tvmaze_best(title, timeout)
    if tv and tv.similarity >= ADOPT_DIRECT:
        tv.adopted = True
        return tv

    ddg = _resolve_via_ddg(title)
    if ddg:
        ddg_name, ddg_year = ddg
        canon = _tvmaze_singlesearch(ddg_name, timeout)
        if canon:
            canon.similarity = _sim(title, canon.name)
            canon.source = "DDG→TVmaze"
            return canon  # adopted=True
        # TVmaze doesn't know it (obscure/movie-ish) — trust the corroborated DDG name.
        return ShowMatch(ddg_name, ddg_year, None, _sim(title, ddg_name), True, source="DDG")

    # Weak or no match → not adopted; caller suggests / stops.
    if tv:
        tv.adopted = False
    return tv
