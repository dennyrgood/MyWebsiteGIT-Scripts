# browser.py — Optional headless Chromium fetcher via Playwright
# 2025-07-15 17:30 UTC
# 2025-07-15 18:30 UTC — networkidle wait strategy with domcontentloaded fallback;
#                        increased default timeouts (30s/3s)
# 2026-07-15 18:40 UTC — Part B: prepend structured cast (IMDB __NEXT_DATA__) to the
#                        returned text so the model gets clean actor—character pairs

from __future__ import annotations

import logging
import re

from bs4 import BeautifulSoup

from structured_cast import structured_cast_prefix
from utils import NOISE_TAGS, normalize_whitespace

logger = logging.getLogger(__name__)

# Domains that block normal HTTP requests and need a real browser
BROWSER_DOMAINS: frozenset[str] = frozenset(
    [
        "imdb.com",
        "fandom.com",
        "sciencedirect.com",
        "linkedin.com",
        "reddit.com",
        "pinterest.com",
    ]
)

# Playwright availability flag — set at import time
_PLAYWRIGHT_AVAILABLE: bool = False
try:
    from playwright.sync_api import sync_playwright  # noqa: F401
    _PLAYWRIGHT_AVAILABLE = True
except ImportError:
    pass


def is_available() -> bool:
    """Return True if Playwright is installed and usable."""
    return _PLAYWRIGHT_AVAILABLE


def needs_browser(url: str) -> bool:
    """Return True if *url* is on a known-blocked domain."""
    from urllib.parse import urlparse
    try:
        host = urlparse(url).hostname or ""
    except Exception:
        return False
    return any(host == d or host.endswith(f".{d}") for d in BROWSER_DOMAINS)


def fetch_with_browser(
    url: str,
    timeout_ms: int = 30_000,
    wait_ms: int = 3_000,
) -> str | None:
    """
    Fetch *url* using headless Chromium and return extracted plain text.

    Parameters
    ----------
    url:
        The URL to fetch.
    timeout_ms:
        Page navigation timeout in milliseconds.
    wait_ms:
        Extra wait after load for JS rendering (milliseconds).

    Returns
    -------
    str | None
        Extracted plain text, or None if Playwright is unavailable or fetch fails.
    """
    if not _PLAYWRIGHT_AVAILABLE:
        logger.debug("Playwright not available — skipping browser fetch for %s", url)
        return None

    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

    logger.debug("Browser fetch: %s", url)
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True)
            context = browser.new_context(
                user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/125.0.0.0 Safari/537.36"
                ),
                viewport={"width": 1280, "height": 800},
                locale="en-US",
            )
            page = context.new_page()

            # Block images/fonts/media to speed things up
            page.route(
                "**/*",
                lambda route: route.abort()
                if route.request.resource_type in ("image", "font", "media", "stylesheet")
                else route.continue_(),
            )

            try:
                page.goto(url, timeout=timeout_ms, wait_until="networkidle")
                page.wait_for_timeout(wait_ms)
            except PWTimeout:
                # networkidle can timeout on heavy pages — try domcontentloaded as fallback
                logger.debug("networkidle timeout for %s, trying domcontentloaded", url)
                try:
                    page.goto(url, timeout=timeout_ms, wait_until="domcontentloaded")
                    page.wait_for_timeout(wait_ms * 2)
                except PWTimeout:
                    logger.warning("Browser timeout loading %s", url)
                    browser.close()
                    return None

            html = page.content()
            browser.close()

        text = _extract_text(html)
        # Prepend clean actor—character pairs from structured data (IMDB) so the
        # model sees authoritative pairs first, ahead of the flattened page text.
        prefix = structured_cast_prefix(url, html)
        if prefix:
            return f"{prefix}\n\n{text}"
        return text

    except Exception as exc:  # noqa: BLE001
        logger.warning("Browser fetch failed for %s: %s", url, exc)
        return None


def _extract_text(html: str) -> str:
    """Strip noise tags and return plain text from raw HTML."""
    try:
        soup = BeautifulSoup(html, "lxml")
        for tag in soup.find_all(NOISE_TAGS):
            tag.decompose()
        return normalize_whitespace(soup.get_text(separator=" "))
    except Exception as exc:  # noqa: BLE001
        logger.debug("Browser text extraction failed: %s", exc)
        return ""
