# downloader.py — HTTP page downloader with retries and MIME detection
# 2025-07-15 14:00 UTC

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from utils import (
    DEFAULT_TIMEOUT,
    DEFAULT_RETRIES,
    DEFAULT_USER_AGENT,
    retry_sleep,
)

logger = logging.getLogger(__name__)


class ContentType(Enum):
    HTML = auto()
    PDF = auto()
    TEXT = auto()
    UNKNOWN = auto()


@dataclass
class DownloadResult:
    """Raw content returned by the downloader."""

    url: str
    content: bytes
    content_type: ContentType
    final_url: str          # URL after following redirects
    status_code: int


def _build_session(retries: int) -> requests.Session:
    """Create a requests Session with retry logic pre-configured."""
    session = requests.Session()
    retry_cfg = Retry(
        total=retries,
        backoff_factor=1.0,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "HEAD"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry_cfg)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    session.headers.update(
        {
            "User-Agent": DEFAULT_USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
        }
    )
    return session


def _detect_content_type(response: requests.Response) -> ContentType:
    """Determine content type from the Content-Type header."""
    ct = response.headers.get("Content-Type", "").lower()
    if "pdf" in ct:
        return ContentType.PDF
    if "html" in ct or "xhtml" in ct:
        return ContentType.HTML
    if "text/plain" in ct:
        return ContentType.TEXT
    # Sniff first bytes for PDF magic number
    if response.content[:4] == b"%PDF":
        return ContentType.PDF
    return ContentType.UNKNOWN


def download(
    url: str,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> Optional[DownloadResult]:
    """
    Download *url* and return a :class:`DownloadResult`, or ``None`` on failure.

    Handles:
    * HTTP/HTTPS redirects (followed automatically)
    * Gzip / deflate / br decompression (via requests)
    * 404, 403, SSL errors, timeouts — all caught and logged
    * PDF detection by MIME type or magic bytes

    Parameters
    ----------
    url:
        The URL to fetch.
    timeout:
        Per-request timeout in seconds.
    retries:
        Number of retry attempts on transient failures.
    """
    session = _build_session(retries)
    last_exc: Optional[Exception] = None

    for attempt in range(1, retries + 1):
        try:
            logger.debug("Downloading (attempt %d): %s", attempt, url)
            response = session.get(url, timeout=timeout, allow_redirects=True)

            if response.status_code == 404:
                logger.warning("404 Not Found: %s", url)
                return None
            if response.status_code == 403:
                logger.warning("403 Forbidden: %s", url)
                return None
            if not response.ok:
                logger.warning("HTTP %d for %s", response.status_code, url)
                if attempt < retries:
                    retry_sleep(attempt)
                    continue
                return None

            ct = _detect_content_type(response)
            logger.debug(
                "Downloaded %d bytes (%s) from %s",
                len(response.content),
                ct.name,
                url,
            )
            return DownloadResult(
                url=url,
                content=response.content,
                content_type=ct,
                final_url=response.url,
                status_code=response.status_code,
            )

        except requests.exceptions.SSLError as exc:
            logger.warning("SSL error for %s: %s", url, exc)
            return None
        except requests.exceptions.TooManyRedirects as exc:
            logger.warning("Redirect loop for %s: %s", url, exc)
            return None
        except requests.exceptions.Timeout as exc:
            logger.warning("Timeout (attempt %d) for %s: %s", attempt, url, exc)
            last_exc = exc
        except requests.exceptions.ConnectionError as exc:
            logger.warning("Connection error (attempt %d) for %s: %s", attempt, url, exc)
            last_exc = exc
        except Exception as exc:  # noqa: BLE001
            logger.warning("Unexpected error downloading %s: %s", url, exc)
            last_exc = exc

        if attempt < retries:
            retry_sleep(attempt)

    logger.error("All %d download attempts failed for %s: %s", retries, url, last_exc)
    return None
