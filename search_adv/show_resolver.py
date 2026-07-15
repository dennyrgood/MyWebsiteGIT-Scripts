# show_resolver.py — Resolve a fuzzy show title to a canonical name via the TVmaze API
# 2026-07-15 19:10 UTC — pre-scan entity resolution: turn "hope street" into the real
#                        show "Hope Street" (2021) before searching; adopt only on a
#                        close match, otherwise surface a suggestion (TV only; no key)

from __future__ import annotations

import difflib
import logging
import re
from dataclasses import dataclass

import requests

logger = logging.getLogger(__name__)

_TVMAZE_SEARCH = "https://api.tvmaze.com/search/shows"
_TIMEOUT = 5

# Minimum normalized-title similarity to ADOPT the resolved name into the search.
# Below this we keep the user's title and only surface the top hit as a suggestion.
# Calibrated so "hope street"→"Hope Street" (1.00) adopts but "hope st"→"413 Hope
# Street" (0.64) does not.
SHOW_MATCH_THRESHOLD = 0.7


@dataclass
class ShowMatch:
    """A candidate canonical show from TVmaze."""

    name: str
    year: str | None       # premiere year, e.g. "2021"
    tvmaze_id: int | None
    similarity: float       # normalized-title similarity to the typed title, [0, 1]
    adopted: bool           # True if similarity >= SHOW_MATCH_THRESHOLD


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()


def resolve_show(title: str, timeout: int = _TIMEOUT) -> ShowMatch | None:
    """
    Look *title* up on TVmaze and return the best-matching canonical show.

    Picks the candidate most similar to *title* (not just TVmaze's own ranking),
    so a wrong top hit can be out-scored. Returns None on network failure, no
    results, or an empty title — callers then just proceed with the typed title.
    """
    title = (title or "").strip()
    if not title:
        return None

    try:
        resp = requests.get(_TVMAZE_SEARCH, params={"q": title}, timeout=timeout)
        resp.raise_for_status()
        results = resp.json()
    except (requests.RequestException, ValueError) as exc:
        logger.debug("TVmaze resolve failed for %r: %s", title, exc)
        return None

    if not results:
        return None

    typed = _norm(title)
    best: ShowMatch | None = None
    for item in results:
        show = item.get("show") or {}
        name = show.get("name") or ""
        if not name:
            continue
        sim = difflib.SequenceMatcher(None, typed, _norm(name)).ratio()
        if best is None or sim > best.similarity:
            premiered = show.get("premiered") or ""
            best = ShowMatch(
                name=name,
                year=premiered[:4] or None,
                tvmaze_id=show.get("id"),
                similarity=sim,
                adopted=sim >= SHOW_MATCH_THRESHOLD,
            )
    if best:
        logger.debug("TVmaze resolved %r → %r (sim %.2f, adopt=%s)",
                     title, best.name, best.similarity, best.adopted)
    return best
