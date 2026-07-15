#!/Users/dennishmathes/repos/scripts/search_adv/.venv/bin/python
# search_adv.py — CLI entry point for the search_adv RAG tool
# 2025-07-15 14:00 UTC
# 2025-07-15 15:00 UTC — snippet fallback: use DDG snippet as chunk when download fails (403/404)
# 2025-07-15 16:00 UTC — added --actor flag for two-stage actor identification + filmography lookup
# 2025-07-15 17:00 UTC — added --cast flag for character/actor table lookup

from __future__ import annotations

import argparse
import csv
from concurrent.futures import ThreadPoolExecutor
import io
import logging
import sys
import time
from pathlib import Path

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from tqdm import tqdm

import cache
import ollama
from actor import is_actor_name, stage1_identify_actor, stage2_filmography, stage_cast
from castref import is_bare_qualifier, parse_reference
from show_resolver import resolve_show
from chunker import chunk_text
from confidence import compute_confidence
from downloader import ContentType, DownloadResult, download
from extractor import extract
from output import AnswerRecord, print_rich, to_html, to_json, to_markdown
from prompts import build_prompt
from ranker import rank_chunks
from search import SearchResult, search
from utils import DEFAULT_MAX_RESULTS, DEFAULT_OLLAMA_ENDPOINT, DEFAULT_MODEL, DEFAULT_TOP_CHUNKS

console = Console()
err_console = Console(stderr=True)  # failure messages; never silenced by --quiet
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="search_adv",
        description="Local RAG search: DuckDuckGo + web retrieval + Ollama",
    )
    p.add_argument(
        "query_or_input",
        nargs="?",
        help="Query string, or path to a text file containing one query per line",
    )
    p.add_argument(
        "output_csv",
        nargs="?",
        help="Output CSV path (batch mode — requires query_or_input to be a file)",
    )
    p.add_argument("--model", default=DEFAULT_MODEL, help="Ollama model tag")
    p.add_argument("--endpoint", default=DEFAULT_OLLAMA_ENDPOINT, help="Ollama endpoint URL")
    p.add_argument("--results", type=int, default=DEFAULT_MAX_RESULTS, help="Max search results")
    p.add_argument("--chunks", type=int, default=DEFAULT_TOP_CHUNKS, help="Top chunks to send to LLM")
    p.add_argument("--site", default=None, help="Restrict search to domain")
    p.add_argument("--exclude", nargs="*", default=None, help="Domains to exclude")
    p.add_argument("--timeout", type=int, default=15, help="HTTP timeout in seconds")
    p.add_argument("--no-cache", action="store_true", help="Disable page cache")
    p.add_argument("--actor", default=None, metavar="REF",
                   help="Actor lookup: 'Show S1E1 Character' or 'Actor Name'")
    p.add_argument("--cast", default=None, metavar="REF",
                   help="Cast list: 'Show S1E1' or 'Movie Title Year'")
    p.add_argument("--validate", action="store_true",
                   help="With --cast: resolve/parse the reference, print it, and exit (no search)")
    p.add_argument("--no-resolve", action="store_true", dest="no_resolve",
                   help="With --cast: skip TVmaze/DDG show-name resolution (search the title as typed)")
    p.add_argument("--quiet", "-q", action="store_true",
                   help="Print only the answer text — no status, sources, or confidence "
                        "(overrides --json/--markdown)")
    p.add_argument("--verbose", "-v", action="store_true", help="Verbose logging")
    p.add_argument("--debug", action="store_true", help="Debug logging (very chatty)")
    p.add_argument("--json", action="store_true", dest="output_json", help="Output JSON")
    p.add_argument("--markdown", action="store_true", help="Output Markdown")
    p.add_argument("--html", default=None, metavar="FILE", help="Write standalone HTML report to FILE")
    return p


# ---------------------------------------------------------------------------
# Core pipeline
# ---------------------------------------------------------------------------


def run_query(
    query: str,
    *,
    model: str,
    endpoint: str,
    max_results: int,
    top_chunks: int,
    site: str | None,
    exclude: list[str] | None,
    timeout: int,
    verbose: bool,
) -> AnswerRecord:
    """
    Execute the full RAG pipeline for a single *query*.

    Returns an :class:`~output.AnswerRecord` with the answer, confidence,
    sources, and elapsed time.
    """
    t0 = time.monotonic()

    # 1. DuckDuckGo search
    _log_stage(verbose, "Searching DuckDuckGo…")
    results: list[SearchResult] = search(
        query, max_results=max_results, site=site, exclude=exclude
    )
    if not results:
        logger.warning("No search results returned for: %s", query)

    # 2. Download pages (in parallel; diskcache is thread-safe)
    _log_stage(verbose, f"Downloading {len(results)} pages…")
    all_chunks = []
    successful_sources: list[SearchResult] = []

    def _fetch(result: SearchResult) -> DownloadResult | None:
        cached = cache.get(result.url)
        if cached is not None:
            raw_content, ct_name = cached
            # Legacy entries predate cached content types; assume HTML.
            content_type = ContentType[ct_name] if ct_name else ContentType.HTML
            return DownloadResult(
                url=result.url,
                content=raw_content,
                content_type=content_type,
                final_url=result.url,
                status_code=200,
            )
        dl = download(result.url, timeout=timeout)
        if dl is not None:
            cache.put(result.url, dl.content, dl.content_type.name)
        return dl

    fetched: list[DownloadResult | None] = []
    if results:
        with ThreadPoolExecutor(max_workers=min(8, len(results))) as pool:
            fetched = list(pool.map(_fetch, results))

    # Extract/chunk sequentially, in search-result order (keeps citations stable)
    for result, dl_for_extract in zip(results, fetched):
        if dl_for_extract is None:
            # Fall back to DDG snippet if we have one
            if result.snippet:
                logger.debug("Download failed, using snippet fallback: %s", result.url)
                chunks = chunk_text(result.snippet, source_url=result.url)
                if chunks:
                    all_chunks.extend(chunks)
                    successful_sources.append(result)
            continue

        # 3. Extract text
        _log_stage(verbose, f"  Extracting: {result.url}")
        text = extract(dl_for_extract)
        if not text:
            logger.debug("Empty extraction for %s", result.url)
            continue

        # 4. Chunk
        chunks = chunk_text(text, source_url=result.url)
        if chunks:
            all_chunks.extend(chunks)
            successful_sources.append(result)

    if not all_chunks:
        # Nothing to rank — still call Ollama but with empty context
        logger.warning("No text chunks extracted; answering with zero context.")

    # 5. Rank
    _log_stage(verbose, f"Ranking {len(all_chunks)} chunks…")
    ranked = rank_chunks(query, all_chunks, top_n=top_chunks)

    # 6. Build prompt
    _log_stage(verbose, "Building prompt…")
    prompt = build_prompt(query, ranked, results)
    if verbose:
        logger.debug("Prompt length: %d chars", len(prompt))

    # 7. Call Ollama
    _log_stage(verbose, f"Sending to Ollama ({model})…")
    try:
        ollama_resp = ollama.generate(
            prompt, model=model, endpoint=endpoint, timeout=timeout
        )
        answer = ollama_resp.answer
    except RuntimeError as exc:
        answer = f"[ERROR: {exc}]"
        logger.error("Ollama call failed: %s", exc)

    # 8. Confidence
    confidence = compute_confidence(ranked)

    elapsed = time.monotonic() - t0
    _log_stage(verbose, f"Done in {elapsed:.1f}s")

    return AnswerRecord(
        query=query,
        answer=answer,
        confidence=confidence,
        sources=successful_sources,
        elapsed=elapsed,
    )


# ---------------------------------------------------------------------------
# Batch mode
# ---------------------------------------------------------------------------


def run_batch(
    input_path: Path,
    output_path: Path,
    args: argparse.Namespace,
) -> None:
    """Process queries from *input_path*, write CSV to *output_path*."""
    queries = [
        line.strip()
        for line in input_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if not queries:
        err_console.print("[red]Input file is empty or contains only comments.[/red]")
        sys.exit(1)

    console.print(f"Batch mode: {len(queries)} queries → {output_path}")

    fieldnames = ["query", "answer", "confidence", "confidence_label",
                  "score", "sources", "elapsed_seconds"]
    out_file = output_path.open("w", newline="", encoding="utf-8")
    writer = csv.DictWriter(out_file, fieldnames=fieldnames)
    writer.writeheader()
    out_file.flush()

    for i, query in enumerate(tqdm(queries, desc="Queries"), 1):
        try:
            record = run_query(
                query,
                model=args.model,
                endpoint=args.endpoint,
                max_results=args.results,
                top_chunks=args.chunks,
                site=args.site,
                exclude=args.exclude,
                timeout=args.timeout,
                verbose=args.verbose,
            )
        except Exception as exc:  # noqa: BLE001
            logger.error("Query %d failed: %s", i, exc)
            record = AnswerRecord(
                query=query,
                answer=f"ERROR: {exc}",
                confidence=None,  # type: ignore[arg-type]
                sources=[],
                elapsed=0.0,
            )

        source_urls = "|".join(s.url for s in record.sources)
        conf_score = record.confidence.score if record.confidence else 0
        conf_label = record.confidence.label if record.confidence else "Low"

        writer.writerow({
            "query": query,
            "answer": record.answer,
            "confidence": conf_label,
            "confidence_label": conf_label,
            "score": conf_score,
            "sources": source_urls,
            "elapsed_seconds": round(record.elapsed, 2),
        })
        out_file.flush()   # never lose progress

    out_file.close()
    console.print(f"[green]Batch complete. Results saved to {output_path}[/green]")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _emit(record: AnswerRecord, args: argparse.Namespace) -> None:
    """Print *record* in the selected format and optionally write the HTML report."""
    if args.quiet:
        print(record.answer)
        if args.html:
            Path(args.html).write_text(to_html(record), encoding="utf-8")
        return
    if args.output_json:
        print(to_json(record))
    elif args.markdown:
        print(to_markdown(record))
    else:
        print_rich(record)

    if args.html:
        html_path = Path(args.html)
        html_path.write_text(to_html(record), encoding="utf-8")
        console.print(f"[dim]HTML report written to {html_path}[/dim]")


def _log_stage(verbose: bool, message: str) -> None:
    if verbose:
        console.print(f"[dim]{message}[/dim]")
    logger.debug(message)


def _configure_logging(verbose: bool, debug: bool, quiet: bool = False) -> None:
    level = logging.WARNING
    if debug:
        level = logging.DEBUG
    elif verbose:
        level = logging.INFO
    elif quiet:
        level = logging.ERROR
    logging.basicConfig(
        level=level,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    _configure_logging(verbose=args.verbose, debug=args.debug, quiet=args.quiet)

    if args.quiet:
        console.quiet = True  # silences status lines and Progress spinners

    # Initialise cache
    cache.configure(enabled=not args.no_cache)

    # ---------------------------------------------------------------------------
    # Actor lookup mode
    # ---------------------------------------------------------------------------
    if args.actor:
        ref = args.actor.strip()
        t0 = time.monotonic()
        identified_from: str | None = None

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            transient=True,
            console=console,
        ) as progress:
            if is_actor_name(ref):
                actor_name = ref
                progress.add_task(f"Looking up filmography for {actor_name}…", total=None)
            else:
                task = progress.add_task("Identifying actor…", total=None)
                actor_name = stage1_identify_actor(
                    ref,
                    model=args.model,
                    endpoint=args.endpoint,
                    timeout=args.timeout,
                )
                progress.remove_task(task)
                if not actor_name:
                    err_console.print(f"[red]Could not identify actor from: {ref}[/red]")
                    cache.close()
                    sys.exit(1)
                identified_from = ref
                console.print(
                    f"  [dim]Actor identified:[/dim] [bold cyan]{actor_name}[/bold cyan]"
                    f"  [dim](from \"{ref}\")[/dim]"
                )
                progress.add_task(f"Fetching filmography for {actor_name}…", total=None)

            record = stage2_filmography(
                actor_name,
                model=args.model,
                endpoint=args.endpoint,
                timeout=args.timeout,
                max_results=args.results,
                top_chunks=args.chunks,
            )

        record.elapsed = time.monotonic() - t0

        _emit(record, args)
        cache.close()
        return

    # ---------------------------------------------------------------------------
    # Cast list mode
    # ---------------------------------------------------------------------------
    if args.cast:
        ref = args.cast.strip()
        # Recover a stray episode qualifier the shell split off from --cast, e.g.
        # `--cast "hope street" s01e01` (s01e01 lands on the positional arg).
        stray = (args.query_or_input or "").strip()
        if stray and is_bare_qualifier(stray):
            ref = f"{ref} {stray}"
            logger.debug("Merged stray qualifier %r into cast ref → %r", stray, ref)
        # Standardise the input at the boundary and echo the interpretation, so a
        # misparse is visible before the ~minute-long search rather than after.
        cref = parse_reference(ref)

        # Resolve the show title against TVmaze/DDG (TV only). Adopt the canonical name
        # on a confident match; if reachable but unresolved, stop; if offline, proceed.
        if cref.kind in ("episode", "series") and not args.no_resolve:
            match = resolve_show(cref.title)
            if match and match.adopted:
                yr = f" ({match.year})" if match.year else ""
                # Adopt the canonical name (also fixes casing, e.g. "hope street" →
                # "Hope Street"); announce it whenever it differs from what was typed.
                if match.name != cref.title:
                    console.print(f'[dim]Resolved show → "{match.name}"{yr} ({match.source})[/dim]')
                cref.title = match.name
            elif match and not match.adopted:
                # Reachable but no confident match — stop rather than burn a ~minute
                # searching a title we couldn't validate. (None = offline → proceed.)
                if match.name:
                    yr = f" ({match.year})" if match.year else ""
                    suggest = (
                        f"{match.name} {cref.episode_phrase}".strip()
                        if cref.episode_phrase else match.name
                    )
                    err_console.print(
                        f'[yellow]No confident show match for "{cref.title}".[/yellow] '
                        f'Closest: "{match.name}"{yr}.'
                    )
                    err_console.print(
                        f'[dim]Re-run with the exact title (e.g. --cast "{suggest}") '
                        f'or --no-resolve to search as-is.[/dim]'
                    )
                else:
                    err_console.print(
                        f'[yellow]Could not resolve show "{cref.title}".[/yellow] '
                        f'Check the title, or use --no-resolve to search as-is.'
                    )
                cache.close()
                return

        console.print(f"[dim]Interpreting → {cref.canonical()}[/dim]")

        if args.validate:
            # Resolution/parse check only — skip the search + Ollama pass.
            console.print(f"[green]Would search for cast of:[/green] {cref.canonical()}")
            cache.close()
            return

        t0 = time.monotonic()

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            transient=True,
            console=console,
        ) as progress:
            progress.add_task(f"Fetching cast for {cref.title}…", total=None)
            record = stage_cast(
                ref,
                model=args.model,
                endpoint=args.endpoint,
                timeout=args.timeout,
                max_results=args.results,
                top_chunks=args.chunks,
                cref=cref,
            )

        record.elapsed = time.monotonic() - t0

        _emit(record, args)
        cache.close()
        return

    # ---------------------------------------------------------------------------
    # Normal query mode
    # ---------------------------------------------------------------------------

    # Determine mode
    if args.query_or_input is None:
        parser.print_help()
        sys.exit(0)

    input_path = Path(args.query_or_input)

    # Batch mode: first positional arg is an existing file
    if input_path.is_file() and args.output_csv:
        run_batch(input_path, Path(args.output_csv), args)
        cache.close()
        return

    # Single-query mode: positional arg is the query string
    query = args.query_or_input

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
        console=console,
    ) as progress:
        task = progress.add_task("Searching…", total=None)
        record = run_query(
            query,
            model=args.model,
            endpoint=args.endpoint,
            max_results=args.results,
            top_chunks=args.chunks,
            site=args.site,
            exclude=args.exclude,
            timeout=args.timeout,
            verbose=args.verbose,
        )
        progress.remove_task(task)

    _emit(record, args)
    cache.close()


if __name__ == "__main__":
    main()
