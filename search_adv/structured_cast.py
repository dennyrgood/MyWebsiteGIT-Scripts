# structured_cast.py — Pull clean actor→character pairs from a page's structured data
# 2026-07-15 18:40 UTC — Part B: parse IMDB's __NEXT_DATA__ cast (GraphQL creditGroupings)
#                        so the model gets delimited "Actor — Character" pairs instead of
#                        IMDB's undelimited flat-text run (which forced fragile prompt rules)
# 2026-07-15 22:45 UTC — also parse the plain title/episode-page shape
#                        (mainColumnData.cast.edges) — previously only /fullcredits
#                        pages yielded structured pairs

from __future__ import annotations

import json
import logging
from urllib.parse import urlparse

from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

# Header the model sees before the pairs; _cast_prompt treats this block as authoritative.
CAST_BLOCK_HEADER = "STRUCTURED CAST (authoritative, already paired — actor — character):"


def is_imdb_cast_url(url: str) -> bool:
    """True for IMDB title / fullcredits pages, whose __NEXT_DATA__ carries the cast."""
    try:
        parsed = urlparse(url)
        host = (parsed.hostname or "").lower()
        path = (parsed.path or "").lower()
    except Exception:
        return False
    return "imdb.com" in host and "/title/tt" in path


def extract_imdb_cast(html: str) -> list[tuple[str, str]]:
    """
    Return [(actor, character), …] from an IMDB page's embedded __NEXT_DATA__ JSON.

    Handles two page shapes: /fullcredits (creditGroupings, isolated to the
    "Cast" grouping so crew is excluded) and plain title/episode pages
    (mainColumnData.cast.edges). Returns [] if neither structure is present —
    callers fall back to plain text.
    """
    try:
        soup = BeautifulSoup(html, "lxml")
        tag = soup.find("script", id="__NEXT_DATA__")
        if not tag or not tag.string:
            return []
        data = json.loads(tag.string)
    except (TypeError, ValueError) as exc:
        logger.debug("IMDB __NEXT_DATA__ not parseable: %s", exc)
        return []

    try:
        groupings = (
            data["props"]["pageProps"]["contentData"]["data"]["title"]
            ["creditGroupings"]["edges"]
        )
    except (KeyError, TypeError) as exc:
        logger.debug("IMDB fullcredits cast path not found (%s), trying title page shape", exc)
        return _cast_from_main_column(data)

    pairs: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for g in groupings:
        node = g.get("node", {})
        grouping = node.get("grouping") or {}
        if (grouping.get("text") or "").strip().lower() != "cast":
            continue
        for cred in node.get("credits", {}).get("edges", []):
            cnode = cred.get("node", {})
            actor = (((cnode.get("name") or {}).get("nameText")) or {}).get("text")
            if not actor:
                continue
            roles = cnode.get("creditedRoles", {}).get("edges", [])
            characters = []
            for r in roles:
                rnode = r.get("node", {})
                traits = (rnode.get("category") or {}).get("traits") or []
                # Keep only acting roles; role.text is the character name.
                if "CAST_TRAIT" in traits and rnode.get("text"):
                    characters.append(rnode["text"])
            character = " / ".join(characters) if characters else "(unspecified)"
            key = (actor, character)
            if key not in seen:
                seen.add(key)
                pairs.append(key)
    if pairs:
        logger.debug("Extracted %d structured cast pairs from IMDB", len(pairs))
    return pairs


def _cast_from_main_column(data: dict) -> list[tuple[str, str]]:
    """
    Cast pairs from a plain title/episode page: mainColumnData.cast.edges,
    node.name.nameText.text + node.characters[].name.
    """
    try:
        edges = (
            data["props"]["pageProps"]["mainColumnData"]["cast"]["edges"]
        )
    except (KeyError, TypeError) as exc:
        logger.debug("IMDB title-page cast path not found: %s", exc)
        return []

    pairs: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for edge in edges:
        node = edge.get("node") or {}
        actor = (((node.get("name") or {}).get("nameText")) or {}).get("text")
        if not actor:
            continue
        characters = [
            c["name"] for c in (node.get("characters") or []) if c.get("name")
        ]
        character = " / ".join(characters) if characters else "(unspecified)"
        key = (actor, character)
        if key not in seen:
            seen.add(key)
            pairs.append(key)
    if pairs:
        logger.debug("Extracted %d structured cast pairs from IMDB title page", len(pairs))
    return pairs


def cast_block(pairs: list[tuple[str, str]]) -> str:
    """Render pairs as a delimited block to prepend to a page's extracted text."""
    lines = [CAST_BLOCK_HEADER]
    lines += [f"{actor} — {character}" for actor, character in pairs]
    return "\n".join(lines)


def structured_cast_prefix(url: str, html: str) -> str | None:
    """
    If *url*/*html* is a supported cast source, return a clean cast block to prepend
    to the page text; otherwise None. Currently handles IMDB (the messy source).
    """
    if is_imdb_cast_url(url):
        pairs = extract_imdb_cast(html)
        if pairs:
            return cast_block(pairs)
    return None
