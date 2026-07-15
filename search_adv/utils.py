# utils.py — Shared constants and utility helpers for search_adv
# 2025-07-15 14:00 UTC

from __future__ import annotations

import re
import time
from typing import Final

# ---------------------------------------------------------------------------
# Network / HTTP
# ---------------------------------------------------------------------------

DEFAULT_USER_AGENT: Final[str] = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)
DEFAULT_TIMEOUT: Final[int] = 15          # seconds
DEFAULT_RETRIES: Final[int] = 3
RETRY_BACKOFF: Final[float] = 1.5        # seconds between retries

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

DEFAULT_MAX_RESULTS: Final[int] = 8

# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

CHUNK_SIZE_WORDS: Final[int] = 1000
CHUNK_OVERLAP_WORDS: Final[int] = 150

# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------

DEFAULT_TOP_CHUNKS: Final[int] = 5

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

CACHE_DIR: Final[str] = ".search_adv_cache"
CACHE_TTL_SECONDS: Final[int] = 86_400   # 24 hours

# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------

DEFAULT_OLLAMA_ENDPOINT: Final[str] = "http://imagebeast:11434"
DEFAULT_MODEL: Final[str] = "gemma4:26b-a4b-it-qat"
OLLAMA_TEMPERATURE: Final[float] = 0.2
OLLAMA_TOP_P: Final[float] = 0.9
OLLAMA_REPEAT_PENALTY: Final[float] = 1.1
OLLAMA_NUM_CTX: Final[int] = 8192

# ---------------------------------------------------------------------------
# Confidence thresholds
# ---------------------------------------------------------------------------

CONFIDENCE_HIGH_THRESHOLD: Final[int] = 70
CONFIDENCE_MEDIUM_THRESHOLD: Final[int] = 40

# Official/authoritative TLDs and domains that boost confidence
AUTHORITATIVE_TLDS: Final[tuple[str, ...]] = (
    ".gov", ".edu", ".org", ".int",
)
AUTHORITATIVE_DOMAINS: Final[tuple[str, ...]] = (
    "wikipedia.org", "britannica.com", "nature.com",
    "ncbi.nlm.nih.gov", "scholar.google.com",
)

# ---------------------------------------------------------------------------
# HTML boilerplate tag removal
# ---------------------------------------------------------------------------

NOISE_TAGS: Final[tuple[str, ...]] = (
    "script", "style", "nav", "header", "footer", "aside",
    "noscript", "iframe", "form", "button", "svg", "figure",
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_WHITESPACE_RE = re.compile(r"\s+")


def normalize_whitespace(text: str) -> str:
    """Collapse runs of whitespace into a single space and strip."""
    return _WHITESPACE_RE.sub(" ", text).strip()


def word_count(text: str) -> int:
    """Return approximate word count of *text*."""
    return len(text.split())


def elapsed_str(seconds: float) -> str:
    """Human-readable elapsed time string."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(int(seconds), 60)
    return f"{m}m {s}s"


def retry_sleep(attempt: int) -> None:
    """Exponential back-off sleep between retry attempts (1-indexed)."""
    time.sleep(RETRY_BACKOFF ** (attempt - 1))
