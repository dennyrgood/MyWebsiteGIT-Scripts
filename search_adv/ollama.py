# ollama.py — Ollama /api/generate client for search_adv
# 2025-07-15 14:00 UTC
# 2026-07-15 16:36 UTC — added think=False; gemma4:26b-a4b-it-qat is a reasoning model
#                        that otherwise burns the whole num_ctx budget on hidden thinking
#                        and returns an empty `response` (done_reason=length)

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import requests

from utils import (
    DEFAULT_MODEL,
    DEFAULT_OLLAMA_ENDPOINT,
    DEFAULT_OLLAMA_TIMEOUT,
    OLLAMA_NUM_CTX,
    OLLAMA_REPEAT_PENALTY,
    OLLAMA_TEMPERATURE,
    OLLAMA_TOP_P,
)

logger = logging.getLogger(__name__)


@dataclass
class OllamaResponse:
    """Parsed response from Ollama /api/generate."""

    answer: str
    model: str
    prompt_tokens: int
    completion_tokens: int
    total_duration_ms: float


def generate(
    prompt: str,
    model: str = DEFAULT_MODEL,
    endpoint: str = DEFAULT_OLLAMA_ENDPOINT,
    timeout: int = DEFAULT_OLLAMA_TIMEOUT,
    temperature: float = OLLAMA_TEMPERATURE,
    top_p: float = OLLAMA_TOP_P,
    repeat_penalty: float = OLLAMA_REPEAT_PENALTY,
    num_ctx: int = OLLAMA_NUM_CTX,
    think: bool = False,
) -> OllamaResponse:
    """
    Send *prompt* to Ollama and return the generated answer.

    Parameters
    ----------
    prompt:
        Full prompt string (system instructions + context + question).
    model:
        Ollama model tag to use.
    endpoint:
        Base URL of the Ollama server (e.g. ``"http://imagebeast:11434"``).
    timeout:
        Total request timeout in seconds (generation included — no hidden
        buffer is added).
    temperature / top_p / repeat_penalty / num_ctx:
        Ollama generation options.

    Returns
    -------
    OllamaResponse
        Parsed response including the answer text and token counts.

    Raises
    ------
    RuntimeError
        If the Ollama call fails or returns an error response.
    """
    url = f"{endpoint.rstrip('/')}/api/generate"
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        # Reasoning models (e.g. gemma4:26b-a4b-it-qat) otherwise spend the whole
        # num_ctx budget on hidden thinking and return an empty response.
        "think": think,
        "options": {
            "temperature": temperature,
            "top_p": top_p,
            "repeat_penalty": repeat_penalty,
            "num_ctx": num_ctx,
        },
    }

    logger.debug("POST %s (model=%s, timeout=%ds)", url, model, timeout)

    try:
        response = requests.post(
            url,
            json=payload,
            timeout=timeout,
            headers={"Content-Type": "application/json"},
        )
        response.raise_for_status()
    except requests.exceptions.ConnectionError as exc:
        raise RuntimeError(
            f"Cannot connect to Ollama at {endpoint}. "
            "Is the server running and reachable?"
        ) from exc
    except requests.exceptions.Timeout as exc:
        raise RuntimeError(
            f"Ollama request timed out after {timeout}s."
        ) from exc
    except requests.exceptions.HTTPError as exc:
        raise RuntimeError(f"Ollama HTTP error: {exc}") from exc

    data: dict = response.json()

    if "error" in data:
        raise RuntimeError(f"Ollama returned error: {data['error']}")

    answer = data.get("response", "").strip()
    if not answer:
        raise RuntimeError("Ollama returned an empty response.")

    prompt_tokens = data.get("prompt_eval_count", 0)
    completion_tokens = data.get("eval_count", 0)
    total_duration_ms = data.get("total_duration", 0) / 1_000_000  # ns → ms

    logger.debug(
        "Ollama: %d prompt tokens, %d completion tokens, %.0f ms total",
        prompt_tokens,
        completion_tokens,
        total_duration_ms,
    )
    return OllamaResponse(
        answer=answer,
        model=model,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_duration_ms=total_duration_ms,
    )
