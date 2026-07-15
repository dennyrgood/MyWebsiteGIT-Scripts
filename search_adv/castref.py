# castref.py — Standardise a user cast/show/movie reference into a canonical CastRef
# 2026-07-15 18:00 UTC — input boundary cleaner: one parser for every notation
#                        (s0101, s04e10, S4E10, 4x10, "season N episode M", "Title YEAR"),
#                        replacing the scattered regex passes in actor.py

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

Kind = Literal["episode", "series", "movie"]

# Compact SSEE with no separator: s0101 → S01E01 (two-digit season, two-digit episode).
_COMPACT_RE = re.compile(r"\bS(\d{2})(\d{2})\b", re.IGNORECASE)
# Shorthand: S4E10, s04e10, S4 E10.
_SHORTHAND_RE = re.compile(r"\bS(\d{1,2})\s*E(\d{1,2})\b", re.IGNORECASE)
# NxM form: 4x10, 04x10.
_NXM_RE = re.compile(r"\b(\d{1,2})x(\d{1,3})\b", re.IGNORECASE)
# Natural language: "season 4 episode 10" (episode optional so "season 4" alone works).
_NATURAL_RE = re.compile(
    r"\bseason\s*(\d{1,2})(?:\s*(?:,|-|\s)\s*episode\s*(\d{1,3}))?\b",
    re.IGNORECASE,
)
# Standalone "episode N" (season assumed from context / unknown).
_EPISODE_ONLY_RE = re.compile(r"\bepisode\s*(\d{1,3})\b", re.IGNORECASE)
# A 4-digit year, either bare trailing or parenthesised: "The Godfather 1972", "Alien (1979)".
_YEAR_RE = re.compile(r"\(?\b(19\d{2}|20\d{2})\b\)?")


@dataclass
class CastRef:
    """A user reference to a show/episode/movie, standardised at the input boundary."""

    kind: Kind
    title: str
    season: int | None
    episode: int | None
    year: int | None
    raw: str

    @property
    def episode_phrase(self) -> str | None:
        """Natural-language season/episode phrase for search queries, or None."""
        if self.season is not None and self.episode is not None:
            return f"season {self.season} episode {self.episode}"
        if self.season is not None:
            return f"season {self.season}"
        if self.episode is not None:
            return f"episode {self.episode}"
        return None

    def canonical(self) -> str:
        """Human-readable interpretation, echoed to the user before searching."""
        if self.kind == "episode":
            se = ""
            if self.season is not None and self.episode is not None:
                se = f" S{self.season:02d}E{self.episode:02d}"
            elif self.season is not None:
                se = f" season {self.season}"
            elif self.episode is not None:
                se = f" episode {self.episode}"
            return f'TV episode — "{self.title}"{se}'
        if self.kind == "series":
            return f'TV series — "{self.title}"'
        year = f" ({self.year})" if self.year else ""
        return f'Movie — "{self.title}"{year}'


def _clean_title(text: str) -> str:
    """Trim trailing separators/whitespace left after slicing off the episode/year part."""
    return re.sub(r"[\s,\-–—:]+$", "", text).strip()


def parse_reference(raw: str) -> CastRef:
    """
    Standardise an arbitrary user reference into a CastRef.

    Handles, in priority order:
      "medium s0101"                        → episode, Medium, S1E1
      "medium s04e10"                       → episode, Medium, S4E10
      "star trek next generation s07e07"    → episode, Star Trek Next Generation, S7E7
      "the office 4x10"                     → episode, The Office, S4E10
      "medium season 4 episode 10"          → episode, Medium, S4E10
      "medium season 4"                     → episode (season only), Medium, S4
      "The Godfather 1972" / "Alien (1979)" → movie, with year
      "Breaking Bad"                        → series
    """
    text = raw.strip()

    # 1) Shorthand / compact / NxM episode notations. Try each; take the earliest match.
    for pat, (s_grp, e_grp) in (
        (_COMPACT_RE, (1, 2)),
        (_SHORTHAND_RE, (1, 2)),
        (_NXM_RE, (1, 2)),
    ):
        m = pat.search(text)
        if m:
            season = int(m.group(s_grp))
            episode = int(m.group(e_grp))
            title = _clean_title(text[: m.start()])
            return CastRef("episode", title, season, episode, None, raw)

    # 2) Natural-language "season N [episode M]".
    m = _NATURAL_RE.search(text)
    if m:
        season = int(m.group(1))
        episode = int(m.group(2)) if m.group(2) else None
        title = _clean_title(text[: m.start()])
        return CastRef("episode", title, season, episode, None, raw)

    # 3) Standalone "episode N".
    m = _EPISODE_ONLY_RE.search(text)
    if m:
        episode = int(m.group(1))
        title = _clean_title(text[: m.start()])
        return CastRef("episode", title, None, episode, None, raw)

    # 4) Trailing / parenthesised year → movie.
    m = _YEAR_RE.search(text)
    if m:
        year = int(m.group(1))
        # Only treat as a movie year if it sits at the end of the string (title YEAR),
        # not an incidental number mid-title.
        if m.end() >= len(text.rstrip()) - 0:
            title = _clean_title(text[: m.start()])
            if title:
                return CastRef("movie", title, None, None, year, raw)

    # 5) Bare title → series.
    return CastRef("series", _clean_title(text), None, None, None, raw)


def is_bare_qualifier(text: str) -> bool:
    """
    True if *text* is ONLY an episode/season qualifier with no title of its own,
    e.g. "s01e01", "S4E10", "4x10", "season 1 episode 1", "episode 3".

    Used to recover a stray trailing token that the shell split off from --cast
    (e.g. `--cast "hope street" s01e01`, where s01e01 lands on a separate arg).
    """
    if not text or not text.strip():
        return False
    ref = parse_reference(text)
    return ref.title == "" and (ref.season is not None or ref.episode is not None)


def expand_shorthand(text: str) -> str:
    """
    Expand episode shorthand to natural language IN PLACE, preserving surrounding text.

    Used by the actor-identification path where the input carries an extra character
    name (e.g. "Medium S4E10 Cynthia" → "Medium season 4 episode 10 Cynthia") and the
    structured CastRef split would drop the trailing name.
    """
    def _expand(m: re.Match) -> str:
        return f"season {int(m.group(1))} episode {int(m.group(2))}"
    text = _COMPACT_RE.sub(_expand, text)
    text = _SHORTHAND_RE.sub(_expand, text)
    return _NXM_RE.sub(_expand, text)
