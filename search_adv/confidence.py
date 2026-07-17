# confidence.py — Heuristic confidence scoring independent of the LLM
# 2025-07-15 14:00 UTC
# 2025-07-15 15:00 UTC — rebalanced weights; added 3-source floor to avoid Low on good results

from __future__ import annotations

import logging
from dataclasses import dataclass
from urllib.parse import urlparse

from ranker import RankedChunk
from utils import (
    AUTHORITATIVE_DOMAINS,
    AUTHORITATIVE_TLDS,
    CONFIDENCE_HIGH_THRESHOLD,
    CONFIDENCE_MEDIUM_THRESHOLD,
)

logger = logging.getLogger(__name__)


@dataclass
class ConfidenceResult:
    """Confidence assessment for a RAG answer."""

    score: int          # 0–100
    label: str          # "High", "Medium", or "Low"
    details: dict[str, float]   # breakdown of contributing signals


def compute_confidence(ranked_chunks: list[RankedChunk]) -> ConfidenceResult:
    """
    Estimate answer confidence from retrieval-side signals.

    Signals combined (all normalised to [0, 1]):

    1. **retrieval_score** — average TF-IDF cosine similarity of top chunks.
    2. **source_agreement** — fraction of distinct source URLs present in
       the top chunks (more unique sources = more corroboration).
    3. **authority_bonus** — fraction of chunks whose source is an
       authoritative domain/TLD.
    4. **chunk_coverage** — a mild bonus for having multiple supporting
       chunks (saturates at 5).

    Parameters
    ----------
    ranked_chunks:
        The top-ranked chunks selected for the prompt.

    Returns
    -------
    ConfidenceResult
        Numerical score (0–100), categorical label, and a breakdown dict.
    """
    if not ranked_chunks:
        return ConfidenceResult(score=0, label="Low", details={})

    # 1. Retrieval score
    scores = [rc.score for rc in ranked_chunks]
    retrieval_score = sum(scores) / len(scores)

    # 2. Source agreement (distinct URLs / total chunks, capped at 1.0)
    unique_urls = len({rc.chunk.source_url for rc in ranked_chunks})
    source_agreement = min(unique_urls / max(len(ranked_chunks), 1), 1.0)

    # 3. Authority bonus
    authoritative_count = sum(
        1 for rc in ranked_chunks if _is_authoritative(rc.chunk.source_url)
    )
    authority_bonus = authoritative_count / len(ranked_chunks)

    # 4. Chunk coverage (how many chunks we have, saturates at 5)
    chunk_coverage = min(len(ranked_chunks) / 5.0, 1.0)

    # Weighted combination → 0–100
    raw = (
        0.30 * retrieval_score      # reduced — short queries score low here unfairly
        + 0.30 * source_agreement   # more weight on corroboration
        + 0.25 * authority_bonus    # more weight on source quality
        + 0.15 * chunk_coverage     # slight bump for coverage
    )
    # Floor: if we have 3+ sources and any retrieval signal, bump to at least Medium
    if unique_urls >= 3 and retrieval_score > 0.05:
        raw = max(raw, 0.42)
    score = min(100, max(0, int(round(raw * 100))))

    label: str
    if score >= CONFIDENCE_HIGH_THRESHOLD:
        label = "High"
    elif score >= CONFIDENCE_MEDIUM_THRESHOLD:
        label = "Medium"
    else:
        label = "Low"

    details = {
        "retrieval_score": round(retrieval_score, 3),
        "source_agreement": round(source_agreement, 3),
        "authority_bonus": round(authority_bonus, 3),
        "chunk_coverage": round(chunk_coverage, 3),
    }
    logger.debug("Confidence: %d (%s) — %s", score, label, details)
    return ConfidenceResult(score=score, label=label, details=details)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _is_authoritative(url: str) -> bool:
    """Return True if *url* belongs to a trusted/authoritative source."""
    try:
        parsed = urlparse(url)
        hostname = parsed.hostname or ""
    except Exception:  # noqa: BLE001
        return False

    for domain in AUTHORITATIVE_DOMAINS:
        if hostname == domain or hostname.endswith(f".{domain}"):
            return True

    for tld in AUTHORITATIVE_TLDS:
        if hostname.endswith(tld):
            return True

    return False
