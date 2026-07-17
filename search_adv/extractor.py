# extractor.py — Clean main-article text from raw HTML
# 2025-07-15 14:00 UTC
# 2025-07-15 15:00 UTC — suppress readability logger (null byte / control char errors are handled by BS4 fallback)

from __future__ import annotations

import logging

from bs4 import BeautifulSoup
from readability import Document

from downloader import ContentType, DownloadResult
from pdf_reader import extract_text_from_pdf
from utils import NOISE_TAGS, normalize_whitespace

logger = logging.getLogger(__name__)

# Minimum character length to consider extracted text usable
_MIN_TEXT_LENGTH = 200


def extract(result: DownloadResult) -> str:
    """
    Extract clean, readable text from a :class:`~downloader.DownloadResult`.

    Dispatch logic:
    * PDF  → :func:`~pdf_reader.extract_text_from_pdf`
    * HTML → readability-lxml, falling back to BeautifulSoup
    * TEXT → decode and return as-is
    * UNKNOWN → attempt HTML extraction

    Returns an empty string if nothing usable can be extracted.
    """
    if result.content_type == ContentType.PDF:
        return extract_text_from_pdf(result.content)

    if result.content_type == ContentType.TEXT:
        try:
            return normalize_whitespace(result.content.decode("utf-8", errors="replace"))
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed to decode text content from %s: %s", result.url, exc)
            return ""

    # HTML or UNKNOWN — try readability first
    raw_html = result.content.decode("utf-8", errors="replace")
    text = _extract_with_readability(raw_html)

    if len(text) < _MIN_TEXT_LENGTH:
        logger.debug(
            "readability yielded only %d chars for %s — falling back to BS4",
            len(text),
            result.url,
        )
        text = _extract_with_bs4(raw_html)

    if len(text) < _MIN_TEXT_LENGTH:
        logger.warning(
            "Extraction produced very short text (%d chars) for %s",
            len(text),
            result.url,
        )

    return text


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _extract_with_readability(html: str) -> str:
    """Use readability-lxml to pull the main article text."""
    try:
        import logging as _logging
        _logging.getLogger("readability.readability").setLevel(_logging.CRITICAL)
        doc = Document(html)
        # summary() returns HTML; parse it with BS4 to get plain text
        summary_html = doc.summary(html_partial=True)
        soup = BeautifulSoup(summary_html, "lxml")
        return normalize_whitespace(soup.get_text(separator=" "))
    except Exception as exc:  # noqa: BLE001
        logger.debug("readability failed: %s", exc)
        return ""


def _extract_with_bs4(html: str) -> str:
    """
    Use BeautifulSoup as a fallback extractor.

    Removes known noise tags, then concatenates remaining visible text.
    """
    try:
        soup = BeautifulSoup(html, "lxml")

        # Remove noise elements
        for tag_name in NOISE_TAGS:
            for tag in soup.find_all(tag_name):
                tag.decompose()

        # Also strip common ad/menu class patterns
        for tag in soup.find_all(True, attrs={"class": _is_noise_class}):
            tag.decompose()

        text = soup.get_text(separator=" ")
        return normalize_whitespace(text)
    except Exception as exc:  # noqa: BLE001
        logger.debug("BS4 extraction failed: %s", exc)
        return ""


_NOISE_PATTERNS = (
    "cookie", "banner", "popup", "modal", "overlay",
    "advertisement", "ad-", "-ad", "sidebar", "menu",
    "nav", "footer", "header",
)


def _is_noise_class(classes: list[str] | None) -> bool:
    """Return True if any CSS class name looks like a noise/boilerplate element."""
    if not classes:
        return False
    joined = " ".join(classes).lower()
    return any(pat in joined for pat in _NOISE_PATTERNS)
