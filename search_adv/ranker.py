# ranker.py — TF-IDF ranking of text chunks against a query
# 2025-07-15 14:00 UTC

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity

from chunker import Chunk
from utils import DEFAULT_TOP_CHUNKS

logger = logging.getLogger(__name__)


@dataclass
class RankedChunk:
    """A chunk paired with its relevance score."""

    chunk: Chunk
    score: float   # cosine similarity in [0, 1]


def rank_chunks(
    query: str,
    chunks: list[Chunk],
    top_n: int = DEFAULT_TOP_CHUNKS,
) -> list[RankedChunk]:
    """
    Rank *chunks* by TF-IDF cosine similarity to *query*.

    Parameters
    ----------
    query:
        The user's original question.
    chunks:
        All chunks harvested from the downloaded pages.
    top_n:
        Maximum number of top-scoring chunks to return.

    Returns
    -------
    list[RankedChunk]
        Top-*n* chunks sorted by descending relevance score.
        Returns an empty list if *chunks* is empty.
    """
    if not chunks:
        logger.warning("rank_chunks called with zero chunks")
        return []

    corpus = [c.text for c in chunks]
    # Prepend query so the vectoriser fits on all relevant vocabulary
    documents = [query] + corpus

    try:
        vectoriser = TfidfVectorizer(
            stop_words="english",
            ngram_range=(1, 2),
            max_features=50_000,
            sublinear_tf=True,
        )
        tfidf_matrix = vectoriser.fit_transform(documents)
    except Exception as exc:  # noqa: BLE001
        logger.error("TF-IDF vectorisation failed: %s", exc)
        return []

    query_vec = tfidf_matrix[0]           # shape (1, vocab)
    chunk_vecs = tfidf_matrix[1:]         # shape (n_chunks, vocab)

    scores: np.ndarray = cosine_similarity(query_vec, chunk_vecs).flatten()

    ranked: list[RankedChunk] = [
        RankedChunk(chunk=chunk, score=float(score))
        for chunk, score in zip(chunks, scores)
    ]
    ranked.sort(key=lambda rc: rc.score, reverse=True)

    selected = ranked[:top_n]
    logger.debug(
        "Ranked %d chunks → top %d (best score %.3f)",
        len(chunks),
        len(selected),
        selected[0].score if selected else 0.0,
    )
    return selected
