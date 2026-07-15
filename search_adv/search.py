# search.py — DuckDuckGo search wrapper for search_adv
# 2025-07-15 14:00 UTC

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from ddgs import DDGS

from utils import DEFAULT_MAX_RESULTS

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SearchResult:
    """A single result returned by the search engine."""

    title: str
    url: str
    snippet: str


def search(
    query: str,
    max_results: int = DEFAULT_MAX_RESULTS,
    site: str | None = None,
    exclude: list[str] | None = None,
) -> list[SearchResult]:
    """
    Query DuckDuckGo and return up to *max_results* results.

    Parameters
    ----------
    query:
        The user's natural-language question or search string.
    max_results:
        Maximum number of results to request.
    site:
        Restrict results to a specific domain (e.g. ``"stackoverflow.com"``).
    exclude:
        List of domains to exclude from results.

    Returns
    -------
    list[SearchResult]
        Ordered list of results (best match first).  Never returns URLs as
        empty strings — results missing a URL are silently dropped.
    """
    effective_query = _build_query(query, site=site, exclude=exclude)
    logger.debug("DDG query: %s", effective_query)

    raw: list[dict[str, str]] = []
    try:
        with DDGS() as ddgs:
            raw = list(ddgs.text(effective_query, max_results=max_results))
    except Exception as exc:  # noqa: BLE001
        logger.warning("DuckDuckGo search failed: %s", exc)
        return []

    results: list[SearchResult] = []
    for item in raw:
        url = (item.get("href") or item.get("url") or "").strip()
        if not url:
            logger.debug("Dropping result with no URL: %s", item)
            continue
        results.append(
            SearchResult(
                title=item.get("title", "").strip(),
                url=url,
                snippet=item.get("body", "").strip(),
            )
        )

    logger.info("Search returned %d results for: %s", len(results), query)
    return results


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _build_query(
    query: str,
    site: str | None,
    exclude: list[str] | None,
) -> str:
    """Compose the final DDG query string with optional site/exclude filters."""
    parts: list[str] = [query]
    if site:
        parts.append(f"site:{site}")
    for domain in (exclude or []):
        parts.append(f"-site:{domain}")
    return " ".join(parts)
