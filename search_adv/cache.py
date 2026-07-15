# cache.py — Disk-based page cache using diskcache
# 2025-07-15 14:00 UTC

from __future__ import annotations

import hashlib
import logging
from typing import Optional

import diskcache

from utils import CACHE_DIR, CACHE_TTL_SECONDS

logger = logging.getLogger(__name__)

# Module-level singleton; initialised lazily
_cache: Optional[diskcache.Cache] = None
_enabled: bool = True


def configure(enabled: bool = True, directory: str = CACHE_DIR) -> None:
    """
    Initialise (or re-initialise) the cache.

    Call this once at startup before any :func:`get` / :func:`put` calls.
    Passing ``enabled=False`` disables all caching (``--no-cache`` flag).
    """
    global _cache, _enabled
    _enabled = enabled
    if enabled:
        _cache = diskcache.Cache(directory)
        logger.debug("Cache initialised at %s (TTL %ds)", directory, CACHE_TTL_SECONDS)
    else:
        _cache = None
        logger.debug("Cache disabled")


def _key(url: str) -> str:
    """Stable cache key derived from the URL."""
    return hashlib.sha256(url.encode()).hexdigest()


def get(url: str) -> Optional[bytes]:
    """
    Return cached bytes for *url*, or ``None`` if not cached / expired.
    """
    if not _enabled or _cache is None:
        return None
    key = _key(url)
    value = _cache.get(key)
    if value is not None:
        logger.debug("Cache hit: %s", url)
    return value  # type: ignore[return-value]


def put(url: str, content: bytes) -> None:
    """Store *content* for *url* with the configured TTL."""
    if not _enabled or _cache is None:
        return
    key = _key(url)
    _cache.set(key, content, expire=CACHE_TTL_SECONDS)
    logger.debug("Cached %d bytes for %s", len(content), url)


def close() -> None:
    """Release cache resources."""
    global _cache
    if _cache is not None:
        _cache.close()
        _cache = None
