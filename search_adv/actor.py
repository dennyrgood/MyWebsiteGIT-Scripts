# actor.py — Two-stage actor identification, filmography search, and cast listing
# 2025-07-15 16:00 UTC
# 2025-07-15 17:00 UTC — better source targeting; context length guard; retry logic; added stage_cast()
# 2025-07-15 17:30 UTC — Playwright browser fallback; S4E10 normalisation; reduced _MAX_CONTEXT_WORDS
# 2025-07-15 18:00 UTC — _MAX_CONTEXT_WORDS→600; stage1 targets TMDB/Wikipedia/RT; num_ctx=4096
# 2025-07-15 18:30 UTC — fixed browser timeout (30s); context quality guard before Ollama
# 2025-07-15 19:00 UTC — episode chunk pre-filter; episode title extraction for rank query enrichment;
#                        full file rewrite to clear accumulated edit corruption
# 2025-07-15 19:30 UTC — deduplicate mobile/desktop Wikipedia+IMDB URLs; cap sources at 6
# 2025-07-15 19:45 UTC — suppress citations when all rows come from the same source
# 2025-07-15 20:00 UTC — removed TMDB priority queries (DDG resolves to developer docs)
# 2025-07-15 20:15 UTC — reverted source cap and bad priority queries; cast queries now
#                        use natural language search to find episode+cast pages reliably
# 2025-07-15 20:30 UTC — added episode title third-pass search in _fetch_sources
# 2025-07-15 21:00 UTC — added parse_cast_ref; stage_cast builds queries inline from title+episode;
#                        deleted _CAST_PRIORITY_QUERIES/_CAST_GENERAL_QUERIES; added _JUNK_DOMAINS filter
# 2026-07-15 16:36 UTC — normalize compact sSSEE notation (s0101→season 1 episode 1);
#                        expanded _JUNK_DOMAINS (grokipedia, youtube, vkontakte, social/video)
# 2026-07-15 16:55 UTC — _extract_episode_title: strip parentheticals + skip
#                        series/season/list pages (was returning "Medium (TV series)");
#                        stage_cast: drop episode title from rank query (biased TF-IDF
#                        toward plot pages over cast pages), rank on cast vocabulary,
#                        keep episode-title URL pinning
# 2026-07-15 17:10 UTC — _cast_prompt: explicit pairing rules to stop off-by-one
#                        misalignment on undelimited IMDB cast runs; keep names intact;
#                        omit ambiguous rows and uncredited extras
# 2026-07-15 17:30 UTC — cast-source pin: _is_cast_source + _rank_with_pins guarantee
#                        imdb/tvmaze/rt/tmdb cast pages lead the context regardless of
#                        DDG order/TF-IDF; _MAX_CONTEXT_WORDS 600→1500 (was truncating
#                        mid-chunk); num_ctx 4096→OLLAMA_NUM_CTX (8192)
# 2026-07-15 18:00 UTC — Part A input cleaner: parse via castref.CastRef; stage_cast
#                        builds queries from structured fields (clean title + qualifier);
#                        _filter_chunks_for_episode reads cref.season/episode; removed the
#                        duplicate shorthand/split regexes (moved to castref)
# 2026-07-15 18:40 UTC — Part B: _cast_prompt treats a STRUCTURED CAST block (from
#                        structured_cast/browser IMDB extraction) as authoritative;
#                        slimmed the undelimited-run pairing rules to a fallback

from __future__ import annotations

import logging
import re
from urllib.parse import urlparse

import ollama as ollama_mod
from browser import fetch_with_browser, needs_browser
from chunker import chunk_text
from confidence import compute_confidence
from downloader import download
from extractor import extract
from output import AnswerRecord
from castref import CastRef, expand_shorthand, parse_reference
from ranker import rank_chunks
from search import SearchResult, search
from utils import OLLAMA_NUM_CTX

logger = logging.getLogger(__name__)

# Keywords that indicate input is a show/episode/movie reference, not a person name
_EPISODE_KEYWORDS = re.compile(
    r"\b(season|episode|s\d+|e\d+|ep\d+|series|show|tv|film|movie)\b",
    re.IGNORECASE,
)

# A person name: 2-3 capitalised words, no digits
_NAME_RE = re.compile(r"^[A-Z][a-zA-Z'-]+(?:\s+[A-Z][a-zA-Z'-]+){1,2}$")

# Episode/shorthand/year parsing now lives in castref.parse_reference — the single
# input-standardisation boundary. See normalize_episode_ref / stage_cast below.

# Word budget for context passed to Ollama. Chunks are 1000 words each, so this
# must exceed one chunk to fit a full cast page plus a corroborating chunk. The
# old value of 600 truncated mid-chunk (a leftover mitigation for what turned out
# to be the thinking-model empty-response bug, not a context-length problem).
_MAX_CONTEXT_WORDS = 1500

# Streaming/piracy sites that never contain cast data
_JUNK_DOMAINS: frozenset[str] = frozenset([
    "movies4kto.watch", "fmovies", "soap2day", "yesmovies",
    "putlocker", "cineb.net", "watchseries", "myflixer",
    "gogoanime", "123movies", "streamingcommunity",
    # AI-generated Wikipedia clone and social/video noise observed in results
    "grokipedia.com", "youtube.com", "youtu.be", "vk.com",
    "dailymotion.com", "facebook.com", "tiktok.com",
    "instagram.com", "pinterest.com", "twitter.com", "x.com",
])

# Preferred high-quality sources for filmography queries.
_FILMOGRAPHY_PRIORITY_QUERIES = [
    "{name} filmography site:en.wikipedia.org",
    "{name} performances site:en.wikipedia.org",
]
_FILMOGRAPHY_GENERAL_QUERIES = [
    "{name} complete filmography television movies career",
    "{name} TV shows movies list all roles",
]


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------


def is_actor_name(text: str) -> bool:
    """Return True if *text* looks like a person's name rather than a show/episode reference."""
    text = text.strip()
    if _EPISODE_KEYWORDS.search(text):
        return False
    if re.search(r"\d", text):
        return False
    return bool(_NAME_RE.match(text))


def normalize_episode_ref(text: str) -> str:
    """
    Expand shorthand episode notation to natural language, preserving surrounding text.

    "Medium S4E10 Cynthia" → "Medium season 4 episode 10 Cynthia"

    Thin wrapper over castref.expand_shorthand — kept for the actor-identification
    path (stage1_identify_actor), whose input carries an extra character name that
    the structured CastRef split would drop.
    """
    return expand_shorthand(text)


def parse_cast_ref(text: str) -> tuple[str, str | None]:
    """
    Split a cast/show reference into (title, episode_ref).

    "Medium season 4 episode 10"                   → ("Medium", "season 4 episode 10")
    "The Godfather 1972"                           → ("The Godfather", None)

    Backward-compatible shim over castref.parse_reference.
    """
    ref = parse_reference(text)
    return ref.title, ref.episode_phrase


# ---------------------------------------------------------------------------
# Stage 1 — identify actor from character/show reference
# ---------------------------------------------------------------------------


def stage1_identify_actor(
    character_ref: str,
    model: str,
    endpoint: str,
    timeout: int,
    max_results: int = 6,
    top_chunks: int = 4,
) -> str | None:
    """
    Given a show/episode/character reference, return the actor's real name.
    Normalises shorthand (S4E10) before searching.
    Targets TMDB/Wikipedia/RT to avoid social media noise.
    Returns None if identification fails.
    """
    expanded = normalize_episode_ref(character_ref)
    query = (
        f"{expanded} actress actor who plays character real name "
        f"site:themoviedb.org OR site:wikipedia.org OR site:rottentomatoes.com"
    )
    logger.debug("Stage 1 search: %s", query)

    results = search(query, max_results=max_results)
    if not results:
        logger.warning("Stage 1: no search results for: %s", query)
        return None

    all_chunks = _download_and_chunk(results, timeout)
    if not all_chunks:
        logger.warning("Stage 1: no chunks extracted")
        return None

    ranked = rank_chunks(query, all_chunks, top_n=top_chunks)
    context_block = _build_context_block(ranked)

    extraction_prompt = (
        "You are a precise fact extractor.\n"
        "Using ONLY the context passages below, identify the real full name of the "
        f"actor or actress who plays the character or role described in this reference:\n\n"
        f"REFERENCE: {expanded}\n\n"
        f"CONTEXT:\n{context_block}\n\n"
        "Respond with ONLY the actor's full name — no explanation, no punctuation, "
        "no extra words. If you cannot determine the name, respond with: UNKNOWN"
    )

    try:
        resp = ollama_mod.generate(
            extraction_prompt,
            model=model,
            endpoint=endpoint,
            timeout=timeout,
            temperature=0.0,
            num_ctx=OLLAMA_NUM_CTX,
        )
        name = resp.answer.strip().strip(".,;:")
        if name.upper() == "UNKNOWN" or not name:
            return None
        logger.debug("Stage 1 identified: %s", name)
        return name
    except RuntimeError as exc:
        logger.error("Stage 1 Ollama call failed: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Stage 2 — filmography
# ---------------------------------------------------------------------------


def stage2_filmography(
    actor_name: str,
    model: str,
    endpoint: str,
    timeout: int,
    max_results: int = 8,
    top_chunks: int = 5,
) -> AnswerRecord:
    """Search for and summarise *actor_name*'s complete filmography."""
    all_results, all_chunks, successful_sources = _fetch_sources(
        name=actor_name,
        priority_queries=_FILMOGRAPHY_PRIORITY_QUERIES,
        general_queries=_FILMOGRAPHY_GENERAL_QUERIES,
        max_results=max_results,
        timeout=timeout,
    )

    if not all_chunks:
        return AnswerRecord(
            query=f"{actor_name} filmography",
            answer="No filmography information could be retrieved.",
            confidence=compute_confidence([]),
            sources=[],
            elapsed=0.0,
        )

    rank_query = f"{actor_name} filmography movies television all roles"
    answer = _call_with_retry(
        prompt_builder=lambda ranked: _filmography_prompt(actor_name, ranked, all_results),
        all_chunks=all_chunks,
        rank_query=rank_query,
        top_chunks=top_chunks,
        model=model,
        endpoint=endpoint,
        timeout=timeout,
    )

    ranked_final = rank_chunks(rank_query, all_chunks, top_n=top_chunks)
    confidence = compute_confidence(ranked_final)

    return AnswerRecord(
        query=f"{actor_name} filmography",
        answer=answer,
        confidence=confidence,
        sources=successful_sources,
        elapsed=0.0,
    )


# ---------------------------------------------------------------------------
# Cast listing
# ---------------------------------------------------------------------------


def stage_cast(
    ref: str,
    model: str,
    endpoint: str,
    timeout: int,
    max_results: int = 8,
    top_chunks: int = 5,
    cref: CastRef | None = None,
) -> AnswerRecord:
    """Return a cast list (Character → Actor table) for a show/episode/movie reference.

    *cref* may be supplied by the caller (already parsed + echoed to the user);
    otherwise it is parsed here from *ref*.
    """
    cref = cref or parse_reference(ref)
    # Natural-language form used for ranking, prompting and display (keeps the year
    # for movies, e.g. "The Godfather 1972"); queries use the structured fields.
    expanded = expand_shorthand(ref)

    # Search subject: quoted clean title plus the disambiguating qualifier
    # (episode phrase for episodes, year for movies, nothing for a bare series).
    qualifier = ""
    if cref.kind == "episode" and cref.episode_phrase:
        qualifier = cref.episode_phrase
    elif cref.kind == "movie" and cref.year:
        qualifier = str(cref.year)
    subject = f'"{cref.title}" {qualifier}'.strip()

    priority_queries = [
        f"{subject} cast site:en.wikipedia.org",
        f"{subject} cast site:imdb.com",
    ]
    general_queries = [
        f"{subject} cast characters actors",
        f"{subject} cast rottentomatoes",
    ]

    all_results, all_chunks, successful_sources = _fetch_sources(
        name=expanded,
        priority_queries=priority_queries,
        general_queries=general_queries,
        max_results=max_results,
        timeout=timeout,
    )

    if not all_chunks:
        return AnswerRecord(
            query=f"{expanded} cast",
            answer="No cast information could be retrieved.",
            confidence=compute_confidence([]),
            sources=[],
            elapsed=0.0,
        )

    # The episode title is useful for *discovery* (finding the right page, done in
    # _fetch_sources) but harmful in the *rank* query: enriching with e.g. "Dark Page"
    # biases TF-IDF toward the prose/plot page that repeats the title, over the cast
    # page that names it once and then lists the actors. So rank on cast vocabulary
    # only, and rely on episode-URL pinning below to keep episode-specific chunks up top.
    ep_title = _extract_episode_title(all_results, expanded)
    rank_query = f"{expanded} cast characters actors played by role starring guest star"
    if ep_title:
        logger.debug("Episode title (used for URL pinning, not rank text): %s", ep_title)

    filtered_chunks = _filter_chunks_for_episode(all_chunks, cref)

    # Pin chunks from the episode-specific page to the top before TF-IDF ranking.
    if ep_title:
        ep_words = set(ep_title.lower().split())

        def _episode_url_score(chunk) -> int:
            url_lower = chunk.source_url.lower()
            url_words = set(re.split(r"[/_\-.]", url_lower))
            overlap = len(ep_words & url_words)
            return overlap

        filtered_chunks = sorted(
            filtered_chunks,
            key=_episode_url_score,
            reverse=True,
        )

    # Pin chunks from reliable cast-listing pages so they always reach the model,
    # regardless of DDG ordering / TF-IDF score (the main run-to-run flakiness).
    pinned_chunks = [c for c in filtered_chunks if _is_cast_source(c.source_url)]
    if pinned_chunks:
        pinned_urls = {c.source_url for c in pinned_chunks}
        logger.debug("Pinned %d cast-source chunks from %d page(s): %s",
                     len(pinned_chunks), len(pinned_urls), ", ".join(sorted(pinned_urls)))

    answer = _call_with_retry(
        prompt_builder=lambda ranked: _cast_prompt(expanded, ranked, all_results),
        all_chunks=filtered_chunks,
        rank_query=rank_query,
        top_chunks=top_chunks,
        model=model,
        endpoint=endpoint,
        timeout=timeout,
        pinned_chunks=pinned_chunks,
    )

    ranked_final = rank_chunks(rank_query, filtered_chunks, top_n=top_chunks)
    confidence = compute_confidence(ranked_final)

    return AnswerRecord(
        query=f"{expanded} cast",
        answer=answer,
        confidence=confidence,
        sources=successful_sources,
        elapsed=0.0,
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _is_junk_url(url: str) -> bool:
    """Return True if url is a streaming/piracy site with no cast data."""
    try:
        host = urlparse(url).hostname or ""
    except Exception:
        return False
    return any(junk in host for junk in _JUNK_DOMAINS)


def _is_cast_source(url: str) -> bool:
    """
    Return True if *url* is a page type that reliably lists the full cast.

    These are pinned into the model context (see _rank_with_pins) so cast data
    always reaches the LLM regardless of DDG result ordering or TF-IDF score —
    otherwise a plot/synopsis chunk can outrank the cast chunk and fall out of
    the top-N cut, yielding an empty or one-line cast list.
    """
    try:
        parsed = urlparse(url)
        host = (parsed.hostname or "").lower()
        path = (parsed.path or "").lower()
    except Exception:
        return False
    if "fullcredits" in path:
        return True
    if "imdb.com" in host and "/title/" in path:
        return True
    if "tvmaze.com" in host and "/episodes/" in path:
        return True
    if "rottentomatoes.com" in host and "cast" in path:
        return True
    if "themoviedb.org" in host and "cast" in path:
        return True
    return False


def _rank_with_pins(
    rank_query: str,
    all_chunks: list,
    pinned_chunks: list,
    top_n: int,
) -> list:
    """
    Rank chunks by TF-IDF but guarantee cast-source chunks lead the result.

    Reserves up to half the slots for the best (TF-IDF-ranked) pinned chunks and
    places them FIRST, so they survive both the top-N cut and the downstream
    _MAX_CONTEXT_WORDS budget. Remaining slots are filled with the best
    non-pinned chunks. Falls back to plain ranking when nothing is pinned.
    """
    if not pinned_chunks:
        return rank_chunks(rank_query, all_chunks, top_n=top_n)

    pin_slots = min(len(pinned_chunks), max(1, top_n // 2))
    pinned_ranked = rank_chunks(rank_query, pinned_chunks, top_n=pin_slots)

    pinned_ids = {id(c) for c in pinned_chunks}
    rest = [c for c in all_chunks if id(c) not in pinned_ids]
    remaining = top_n - len(pinned_ranked)
    rest_ranked = (
        rank_chunks(rank_query, rest, top_n=remaining) if remaining > 0 else []
    )
    # Pinned first (not re-sorted by score) so they lead the context block.
    return pinned_ranked + rest_ranked


def _download_and_chunk(results: list[SearchResult], timeout: int) -> list:
    """Download pages (with browser fallback) and return all chunks."""
    all_chunks = []
    for result in results:
        text = _fetch_text(result, timeout)
        if text:
            all_chunks.extend(chunk_text(text, source_url=result.url))
        elif result.snippet:
            all_chunks.extend(chunk_text(result.snippet, source_url=result.url))
    return all_chunks


def _fetch_text(result: SearchResult, timeout: int) -> str | None:
    """Fetch page text, using Playwright for known-blocked domains."""
    if needs_browser(result.url):
        text = fetch_with_browser(result.url, timeout_ms=30_000, wait_ms=3_000)
        if text and len(text) > 100:
            logger.debug("Browser fetch succeeded for %s (%d chars)", result.url, len(text))
            return text
        logger.debug("Browser fetch failed or too short for %s", result.url)
        return None

    dl = download(result.url, timeout=timeout)
    if dl is None:
        return None
    return extract(dl) or None


def _canonical_url(url: str) -> str:
    """
    Normalise mobile Wikipedia/IMDB URLs to their desktop equivalent.
    Prevents fetching the same page twice as both en.m.wikipedia.org and en.wikipedia.org.
    """
    url = re.sub(r"//en\.m\.wikipedia\.org/", "//en.wikipedia.org/", url)
    url = re.sub(r"//m\.imdb\.com/", "//www.imdb.com/", url)
    return url


def _fetch_sources(
    name: str,
    priority_queries: list[str],
    general_queries: list[str],
    max_results: int,
    timeout: int,
) -> tuple[list[SearchResult], list, list[SearchResult]]:
    """Run priority then general searches, download pages, chunk text.

    Deduplicates mobile/desktop variants of the same page.
    Skips known streaming/piracy domains.
    """
    all_results: list[SearchResult] = []
    seen_canonical: set[str] = set()

    def _run_queries(templates: list[str], per_query: int) -> None:
        for tmpl in templates:
            q = tmpl.format(name=name, ref=name)
            logger.debug("Searching: %s", q)
            for r in search(q, max_results=per_query):
                canonical = _canonical_url(r.url)
                if canonical not in seen_canonical:
                    seen_canonical.add(canonical)
                    all_results.append(
                        SearchResult(
                            title=r.title,
                            url=canonical,
                            snippet=r.snippet,
                        )
                    )

    _run_queries(priority_queries, per_query=3)
    _run_queries(general_queries, per_query=max_results // 2)

    # Third pass: targeted Wikipedia search for episode title if extractable.
    ep_title = _extract_episode_title(all_results, name)
    if ep_title:
        logger.debug("Episode title bonus search: %s", ep_title)
        for q in [f"{ep_title} wikipedia", f"{ep_title} cast characters actors"]:
            for r in search(q, max_results=2):
                canonical = _canonical_url(r.url)
                if canonical not in seen_canonical:
                    seen_canonical.add(canonical)
                    all_results.append(
                        SearchResult(title=r.title, url=canonical, snippet=r.snippet)
                    )

    all_chunks = []
    successful_sources: list[SearchResult] = []

    for result in all_results:
        if _is_junk_url(result.url):
            logger.debug("Skipping junk domain: %s", result.url)
            continue
        text = _fetch_text(result, timeout)
        if text:
            chunks = chunk_text(text, source_url=result.url)
            if chunks:
                all_chunks.extend(chunks)
                successful_sources.append(result)
        elif result.snippet:
            chunks = chunk_text(result.snippet, source_url=result.url)
            if chunks:
                all_chunks.extend(chunks)
                successful_sources.append(result)

    return all_results, all_chunks, successful_sources


def _extract_episode_title(
    results: list[SearchResult],
    ref: str,
) -> str | None:
    """
    Extract episode title from search result titles.

    Looks for source titles like "Loud as a Whisper - Wikipedia" and extracts
    "Loud as a Whisper" — used to enrich the rank query so TF-IDF steers
    toward episode-specific chunks.
    """
    ref_words = set(re.split(r"\W+", ref.lower()))
    generic = {
        "wikipedia", "imdb", "tmdb", "fandom", "season", "episode", "list",
        "cast", "crew", "series", "episodes", "the", "of", "and", "a", "an",
        "tv", "show", "next", "generation", "trek", "star", "medium",
    }
    # Titles that are the series/season/list page, not a single episode — never
    # a valid episode title. These previously leaked through as "Medium (TV series)".
    _NON_EPISODE_RE = re.compile(
        r"\b(tv series|film series|season\s*\d+|list of|full cast|episode list)\b",
        re.IGNORECASE,
    )

    for result in results:
        title = result.title or ""
        title_clean = re.split(
            r"\s*[-|]\s*(Wikipedia|IMDb|TMDB|Fandom|TV Guide|Rotten|The Movie)", title
        )[0].strip()
        # Drop parenthetical qualifiers: "(TV series)", "(TV Series 1987–1994)", "(film)", "(2005)".
        title_clean = re.sub(r"\s*\([^)]*\)", "", title_clean).strip()

        # Skip series/season/list pages outright — they are not episode titles.
        if _NON_EPISODE_RE.search(title_clean):
            continue

        words = title_clean.split()
        if len(words) < 2 or len(words) > 7:
            continue

        # Normalise punctuation before comparing, else "Trek:" dodges the generic
        # set and the series name leaks through as a fake episode title.
        meaningful = [
            w for w in words
            if (wn := w.lower().strip(":.,'\"!?")) not in ref_words
            and wn not in generic
            and len(wn) > 2
            and not wn.isdigit()
        ]
        # Require at least one word that is NOT part of the series name / generic
        # vocabulary, otherwise this is just the show title restated.
        if meaningful:
            logger.debug("Episode title extracted: %r from %r", title_clean, title)
            return title_clean

    return None


def _filter_chunks_for_episode(chunks: list, cref: CastRef) -> list:
    """
    Pre-filter chunks to those that mention the specific season AND episode number.

    Requires chunks to contain both the season number and episode number
    adjacent to season/episode keywords. Falls back to all chunks if < 3 pass.
    Uses the structured season/episode from *cref* (no re-parsing of strings).
    """
    if cref.season is None or cref.episode is None:
        return chunks

    season_num, ep_num = str(cref.season), str(cref.episode)

    season_patterns = [
        rf"season\s*{season_num}\b",
        rf"\bs{season_num}\b",
        rf"\bs0*{season_num}e",
    ]
    ep_patterns = [
        rf"episode\s*{ep_num}\b",
        rf"e0*{ep_num}\b",
        rf"s\d+e0*{ep_num}\b",
    ]
    combined_patterns = [
        rf"\b{season_num}x0*{ep_num}\b",
        rf"\bs0*{season_num}e0*{ep_num}\b",
    ]

    filtered = []
    for chunk in chunks:
        text_lower = chunk.text.lower()
        has_combined = any(re.search(p, text_lower) for p in combined_patterns)
        has_season = any(re.search(p, text_lower) for p in season_patterns)
        has_episode = any(re.search(p, text_lower) for p in ep_patterns)
        if has_combined or (has_season and has_episode):
            filtered.append(chunk)

    if len(filtered) < 3:
        logger.debug("Episode filter too aggressive (%d→%d), using all", len(chunks), len(filtered))
        return chunks

    logger.debug("Episode filter: %d→%d chunks", len(chunks), len(filtered))
    return filtered


def _build_context_block(ranked: list) -> str:
    """Join ranked chunk texts, truncating to stay within _MAX_CONTEXT_WORDS."""
    parts: list[str] = []
    total_words = 0
    for rc in ranked:
        words = rc.chunk.text.split()
        if total_words + len(words) > _MAX_CONTEXT_WORDS:
            remaining = _MAX_CONTEXT_WORDS - total_words
            if remaining > 50:
                parts.append(" ".join(words[:remaining]))
            break
        parts.append(rc.chunk.text.strip())
        total_words += len(words)
    return "\n\n---\n\n".join(parts)


def _numbered_context_block(ranked: list, all_results: list[SearchResult]) -> str:
    """Build a numbered context block with source citations."""
    url_to_title = {r.url: r.title for r in all_results}
    parts: list[str] = []
    total_words = 0
    for i, rc in enumerate(ranked, 1):
        words = rc.chunk.text.split()
        if total_words + len(words) > _MAX_CONTEXT_WORDS:
            remaining = _MAX_CONTEXT_WORDS - total_words
            if remaining > 50:
                title = url_to_title.get(rc.chunk.source_url, rc.chunk.source_url)
                parts.append(
                    f"[{i}] Source: {title}\nURL: {rc.chunk.source_url}\n---\n"
                    + " ".join(words[:remaining])
                )
            break
        title = url_to_title.get(rc.chunk.source_url, rc.chunk.source_url)
        parts.append(
            f"[{i}] Source: {title}\nURL: {rc.chunk.source_url}\n---\n"
            f"{rc.chunk.text.strip()}"
        )
        total_words += len(words)
    return "\n\n".join(parts)


def _filmography_prompt(actor_name: str, ranked: list, all_results: list[SearchResult]) -> str:
    context = _numbered_context_block(ranked, all_results)
    n_sources = len({rc.chunk.source_url for rc in ranked})
    citation_instruction = (
        "Cite sources using [1], [2], etc. where sources differ."
        if n_sources > 1
        else "All data comes from one source — do not add citation numbers."
    )
    return (
        "You are a precise research assistant.\n"
        "Answer ONLY using the context passages provided below.\n"
        f"Never invent credits not in the context. {citation_instruction}\n\n"
        f"List the complete filmography of {actor_name} found in the context.\n"
        "Present as two sections: TELEVISION and FILM.\n"
        "Bullet list: title (year) — role if known.\n"
        "End with a 2-3 sentence career summary.\n\n"
        f"=== CONTEXT ===\n\n{context}\n\n=== ANSWER ===\n"
    )


def _cast_prompt(ref: str, ranked: list, all_results: list[SearchResult]) -> str:
    context = _numbered_context_block(ranked, all_results)
    n_sources = len({rc.chunk.source_url for rc in ranked})
    citation_instruction = (
        "Cite sources using [1], [2], etc. on each row where the source differs."
        if n_sources > 1
        else "All data comes from one source — do not add citation numbers to the table."
    )
    return (
        "You are a precise research assistant.\n"
        "Answer ONLY using the context passages provided below.\n"
        f"Never invent cast members not in the context. {citation_instruction}\n\n"
        f"List the full cast for: {ref}\n"
        "Format as a two-column table with headers: Character | Actor\n\n"
        "If a 'STRUCTURED CAST' block is present, it is authoritative and already "
        "correctly paired — use its actor—character pairs verbatim; do not re-pair "
        "them from other passages.\n"
        "Otherwise, when a passage lists cast as an undelimited run of "
        "\"Actor Name Character Name Actor Name Character Name …\": keep each actor with "
        "their OWN character, keep full multi-word names intact (never split one "
        "person's name across columns), and OMIT any entry you cannot confidently pair "
        "rather than guessing.\n"
        "Skip uncredited background/extra roles; one row per credited cast member.\n\n"
        "After the table, note any recurring or guest cast if the context labels them so.\n\n"
        f"=== CONTEXT ===\n\n{context}\n\n=== ANSWER ===\n"
    )


def _call_with_retry(
    prompt_builder,
    all_chunks: list,
    rank_query: str,
    top_chunks: int,
    model: str,
    endpoint: str,
    timeout: int,
    pinned_chunks: list | None = None,
) -> str:
    """Rank chunks, build prompt, call Ollama. Retries with fewer chunks on failure.

    When *pinned_chunks* is given, those chunks (ranked among themselves) always
    lead the context so cast-source pages survive the top-N cut and the context
    word budget — see _rank_with_pins.
    """
    last_error: str = ""
    for attempt_chunks in [top_chunks, max(2, top_chunks // 2), 1]:
        ranked = _rank_with_pins(rank_query, all_chunks, pinned_chunks or [], attempt_chunks)
        prompt = prompt_builder(ranked)

        context_words = sum(len(rc.chunk.text.split()) for rc in ranked)
        if context_words < 50:
            logger.warning("Context too thin (%d words) — skipping Ollama call", context_words)
            return "[ERROR: Retrieved context contains insufficient information. Try --no-cache or rephrase the query.]"

        logger.debug("Ollama: ~%d prompt words, %d chunks, %d context words",
                     len(prompt.split()), attempt_chunks, context_words)
        try:
            resp = ollama_mod.generate(
                prompt,
                model=model,
                endpoint=endpoint,
                timeout=timeout,
                num_ctx=OLLAMA_NUM_CTX,
            )
            if resp.answer.strip():
                return resp.answer
            logger.warning("Empty Ollama response (%d chunks), retrying…", attempt_chunks)
            last_error = "empty response"
        except RuntimeError as exc:
            logger.warning("Ollama failed (chunks=%d): %s — retrying…", attempt_chunks, exc)
            last_error = str(exc)

    return f"[ERROR: Ollama returned {last_error} after all retries.]"
