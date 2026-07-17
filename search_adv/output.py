# output.py — Terminal, JSON, Markdown, and HTML output renderers
# 2025-07-15 14:00 UTC
# 2026-07-15 21:40 UTC — Sources list: when context_sources is set (cast/actor), show
#                        only the pages actually cited in the answer, keeping their
#                        citation numbers (no renumbering); drops fetched-but-unused pages

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass

from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.table import Table
from rich import box

from confidence import ConfidenceResult
from search import SearchResult
from utils import elapsed_str

console = Console()


@dataclass
class AnswerRecord:
    """Complete result for a single query — passed to all renderers."""

    query: str
    answer: str
    confidence: ConfidenceResult
    sources: list[SearchResult]
    elapsed: float          # seconds
    # Sources in citation order — element i-1 is what "[i]" in the answer refers to.
    # When set (cast/actor modes), only the cited entries are shown, keeping their
    # numbers. None for plain search → the full `sources` list is shown as before.
    context_sources: list[SearchResult] | None = None


_CITE_RE = re.compile(r"\[(\d+(?:\s*,\s*\d+)*)\]")


def _cited_numbers(answer: str) -> set[int]:
    """Citation numbers referenced in *answer*, e.g. '[1]' / '[1, 2]' → {1, 2}."""
    nums: set[int] = set()
    for m in _CITE_RE.finditer(answer):
        for part in m.group(1).split(","):
            nums.add(int(part.strip()))
    return nums


def _display_sources(record: AnswerRecord) -> list[tuple[int, SearchResult]]:
    """
    (number, source) pairs to render.

    - Plain search (no context_sources): the full source list, numbered 1..N.
    - Cast/actor: only the sources actually cited in the answer, keeping their
      citation numbers (no renumbering). If the answer carries no citations
      (single-source case), show the context sources that were used.
    """
    if record.context_sources is None:
        return list(enumerate(record.sources, 1))
    numbered = list(enumerate(record.context_sources, 1))
    cited = _cited_numbers(record.answer)
    if cited:
        return [(i, s) for i, s in numbered if i in cited]
    return numbered


# ---------------------------------------------------------------------------
# Terminal (Rich)
# ---------------------------------------------------------------------------


def print_rich(record: AnswerRecord) -> None:
    """Render *record* to the terminal using Rich formatting."""
    _print_question(record.query)
    _print_answer(record.answer)
    _print_confidence(record.confidence)
    _print_sources(_display_sources(record))
    _print_timing(record.elapsed)


def _print_question(query: str) -> None:
    console.print()
    console.print(Panel(f"[bold cyan]{query}[/bold cyan]", title="Question", border_style="cyan"))


def _print_answer(answer: str) -> None:
    console.print()
    console.print(Panel(Markdown(answer), title="Answer", border_style="green"))


def _print_confidence(conf: ConfidenceResult) -> None:
    colour = {"High": "green", "Medium": "yellow", "Low": "red"}.get(conf.label, "white")
    console.print()
    console.print(
        f"  Confidence: [{colour}]{conf.label}[/{colour}] "
        f"([bold]{conf.score}/100[/bold])"
    )


def _print_sources(sources: list[tuple[int, SearchResult]]) -> None:
    if not sources:
        return
    console.print()
    table = Table(title="Sources", box=box.SIMPLE, show_lines=False)
    table.add_column("#", style="dim", width=3)
    table.add_column("Title", style="bold")
    table.add_column("URL", style="blue underline")
    for i, src in sources:
        table.add_row(str(i), src.title or "(no title)", src.url)
    console.print(table)


def _print_timing(elapsed: float) -> None:
    console.print(f"\n  [dim]Elapsed: {elapsed_str(elapsed)}[/dim]\n")


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------


def to_json(record: AnswerRecord) -> str:
    """Serialise *record* to a JSON string."""
    payload = {
        "query": record.query,
        "answer": record.answer,
        "confidence": record.confidence.score,
        "confidence_label": record.confidence.label,
        "sources": [
            {"n": i, "title": s.title, "url": s.url}
            for i, s in _display_sources(record)
        ],
        "elapsed": round(record.elapsed, 3),
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------


def to_markdown(record: AnswerRecord) -> str:
    """Produce a Markdown-formatted string for *record*."""
    lines: list[str] = []
    lines.append(f"# Question\n\n{record.query}\n")
    lines.append(f"# Answer\n\n{record.answer}\n")
    lines.append(
        f"# Confidence\n\n"
        f"**{record.confidence.label}** ({record.confidence.score}/100)\n"
    )
    lines.append("# Sources\n")
    for i, src in _display_sources(record):
        lines.append(f"{i}. [{src.title or src.url}]({src.url})")
    lines.append(f"\n---\n*Elapsed: {elapsed_str(record.elapsed)}*\n")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------


def to_html(record: AnswerRecord) -> str:
    """Generate a standalone HTML report for *record*."""
    conf_colour = {"High": "#2d9e2d", "Medium": "#b8860b", "Low": "#c0392b"}.get(
        record.confidence.label, "#555"
    )
    sources_html = "\n".join(
        f'    <li value="{i}"><a href="{s.url}" target="_blank" rel="noopener">'
        f'{s.title or s.url}</a></li>'
        for i, s in _display_sources(record)
    )
    # Convert answer newlines to <p> tags
    answer_paragraphs = "".join(
        f"<p>{html.escape(para.strip())}</p>"
        for para in record.answer.split("\n\n")
        if para.strip()
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>search_adv — {html.escape(record.query)}</title>
  <style>
    :root {{
      --bg: #0f1117;
      --surface: #1a1d27;
      --border: #2e3150;
      --text: #e2e4f0;
      --muted: #7a7f9a;
      --accent: #5c8ef0;
      --answer: #c8ffc8;
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      background: var(--bg); color: var(--text);
      font-family: system-ui, -apple-system, sans-serif;
      font-size: 16px; line-height: 1.7;
      padding: 2rem 1rem;
    }}
    .container {{ max-width: 820px; margin: 0 auto; }}
    h1 {{ font-size: 1.05rem; font-weight: 600; color: var(--muted);
          text-transform: uppercase; letter-spacing: .08em; margin-bottom: .5rem; }}
    .card {{
      background: var(--surface); border: 1px solid var(--border);
      border-radius: 10px; padding: 1.5rem; margin-bottom: 1.5rem;
    }}
    .question {{ font-size: 1.25rem; font-weight: 700; color: var(--accent); }}
    .answer p {{ margin-top: .75rem; color: var(--answer); }}
    .badge {{
      display: inline-block; padding: .2rem .75rem;
      border-radius: 99px; font-weight: 700; font-size: .9rem;
      background: {conf_colour}22; color: {conf_colour};
      border: 1px solid {conf_colour}66;
    }}
    .score {{ font-size: .85rem; color: var(--muted); margin-top: .4rem; }}
    ul {{ padding-left: 1.25rem; }}
    li {{ margin-top: .4rem; }}
    a {{ color: var(--accent); text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    .elapsed {{ font-size: .85rem; color: var(--muted); text-align: right; }}
    .logo {{ font-size: .8rem; color: var(--muted); margin-bottom: 1.5rem;
             letter-spacing: .05em; }}
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">search_adv &mdash; local RAG search</div>

    <div class="card">
      <h1>Question</h1>
      <div class="question">{html.escape(record.query)}</div>
    </div>

    <div class="card">
      <h1>Answer</h1>
      <div class="answer">{answer_paragraphs}</div>
    </div>

    <div class="card">
      <h1>Confidence</h1>
      <span class="badge">{record.confidence.label}</span>
      <div class="score">{record.confidence.score} / 100</div>
    </div>

    <div class="card">
      <h1>Sources</h1>
      <ol>
{sources_html}
      </ol>
    </div>

    <div class="elapsed">Elapsed: {elapsed_str(record.elapsed)}</div>
  </div>
</body>
</html>"""
