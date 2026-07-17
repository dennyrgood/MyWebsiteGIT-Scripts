# pdf_reader.py — PDF text extraction using pypdf
# 2025-07-15 14:00 UTC

from __future__ import annotations

import io
import logging

from pypdf import PdfReader

from utils import normalize_whitespace

logger = logging.getLogger(__name__)


def extract_text_from_pdf(content: bytes) -> str:
    """
    Extract plain text from raw PDF *content* bytes.

    Parameters
    ----------
    content:
        Raw bytes of a PDF file.

    Returns
    -------
    str
        Concatenated text from all pages, or an empty string if extraction
        fails entirely.
    """
    try:
        reader = PdfReader(io.BytesIO(content))
    except Exception as exc:  # noqa: BLE001
        logger.warning("Failed to open PDF: %s", exc)
        return ""

    pages: list[str] = []
    for i, page in enumerate(reader.pages):
        try:
            text = page.extract_text() or ""
            text = normalize_whitespace(text)
            if text:
                pages.append(text)
        except Exception as exc:  # noqa: BLE001
            logger.debug("Failed to extract text from PDF page %d: %s", i, exc)

    combined = "\n\n".join(pages)
    logger.debug("Extracted %d characters from %d PDF pages", len(combined), len(pages))
    return combined
