# chunker.py — Split extracted text into overlapping word chunks
# 2025-07-15 14:00 UTC

from __future__ import annotations

import logging
from dataclasses import dataclass

from utils import CHUNK_OVERLAP_WORDS, CHUNK_SIZE_WORDS

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class Chunk:
    """A single text chunk with provenance metadata."""

    text: str
    source_url: str
    chunk_number: int   # 0-indexed within the source document


def chunk_text(
    text: str,
    source_url: str,
    chunk_size: int = CHUNK_SIZE_WORDS,
    overlap: int = CHUNK_OVERLAP_WORDS,
) -> list[Chunk]:
    """
    Split *text* into overlapping word-based chunks.

    Parameters
    ----------
    text:
        The full extracted text from a page.
    source_url:
        URL of the originating page — embedded in every chunk for citation.
    chunk_size:
        Target chunk size in words.
    overlap:
        Number of words shared between consecutive chunks.

    Returns
    -------
    list[Chunk]
        Ordered list of chunks.  An empty list is returned if *text* has
        no words.

    Notes
    -----
    Overlapping chunks improve recall: a relevant sentence near a chunk
    boundary will appear in full in at least one chunk.
    """
    words = text.split()
    if not words:
        return []

    stride = max(1, chunk_size - overlap)
    chunks: list[Chunk] = []
    idx = 0
    chunk_number = 0

    while idx < len(words):
        window = words[idx : idx + chunk_size]
        chunk_text_str = " ".join(window)
        chunks.append(
            Chunk(
                text=chunk_text_str,
                source_url=source_url,
                chunk_number=chunk_number,
            )
        )
        idx += stride
        chunk_number += 1

    logger.debug(
        "Chunked %d words into %d chunks (size=%d, overlap=%d) for %s",
        len(words),
        len(chunks),
        chunk_size,
        overlap,
        source_url,
    )
    return chunks
