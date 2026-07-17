# prompts.py — Prompt construction for the Ollama RAG call
# 2025-07-15 14:00 UTC

from __future__ import annotations

from ranker import RankedChunk
from search import SearchResult


_SYSTEM_PROMPT = """\
You are a precise research assistant.
Answer ONLY using the context passages provided below.
Never invent facts that are not in the context.
If the context passages conflict with each other, acknowledge the conflict and explain the disagreement.
If the context does not contain enough information to answer the question, clearly state that the available evidence is insufficient.
Always cite your sources using inline citation numbers like [1], [2], etc., matching the passage numbers given below.
Be concise and factual. Do not pad your answer with unnecessary words.\
"""


def build_prompt(
    query: str,
    ranked_chunks: list[RankedChunk],
    search_results: list[SearchResult],
) -> str:
    """
    Construct the full prompt that will be sent to Ollama.

    The prompt contains:
    1. A system preamble with grounding instructions.
    2. Numbered context passages (with source URL).
    3. The user question.

    Parameters
    ----------
    query:
        The user's original question.
    ranked_chunks:
        Top-ranked text chunks from the retrieval pipeline.
    search_results:
        Original search results (used for title lookup in citations).

    Returns
    -------
    str
        The complete prompt string ready to send to the model.
    """
    url_to_title = {r.url: r.title for r in search_results}

    context_parts: list[str] = []
    for i, rc in enumerate(ranked_chunks, start=1):
        title = url_to_title.get(rc.chunk.source_url, rc.chunk.source_url)
        context_parts.append(
            f"[{i}] Source: {title}\n"
            f"URL: {rc.chunk.source_url}\n"
            f"---\n"
            f"{rc.chunk.text.strip()}"
        )

    context_block = "\n\n".join(context_parts)

    prompt = (
        f"{_SYSTEM_PROMPT}\n\n"
        f"=== CONTEXT PASSAGES ===\n\n"
        f"{context_block}\n\n"
        f"=== QUESTION ===\n\n"
        f"{query}\n\n"
        f"=== ANSWER ===\n"
    )
    return prompt
