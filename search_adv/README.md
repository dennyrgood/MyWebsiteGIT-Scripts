# search_adv

Created: 2025-07-15 14:00 UTC

**Local RAG search tool — DuckDuckGo + full web retrieval + Ollama**

search_adv is a command-line utility that answers questions by:

1. Searching DuckDuckGo for the top relevant pages
2. Downloading and extracting clean article text (HTML and PDF)
3. Splitting text into overlapping chunks
4. Ranking chunks by TF-IDF cosine similarity to your question
5. Sending the top chunks as context to a local Ollama model
6. Returning an answer with cited sources and a retrieval-based confidence score

This is **not** a chatbot. Every run is a fresh, single-shot retrieval pipeline.

---

## Architecture

```
User Query
    │
    ▼
DuckDuckGo Search (search.py)
    │
    ▼
Download Pages (downloader.py)  ←──── Disk Cache (cache.py)
    │
    ├── HTML → readability-lxml + BeautifulSoup (extractor.py)
    └── PDF  → pypdf (pdf_reader.py)
    │
    ▼
Split into Overlapping Chunks (chunker.py)
    │
    ▼
TF-IDF Ranking (ranker.py)
    │
    ▼
Build RAG Prompt (prompts.py)
    │
    ▼
Ollama /api/generate (ollama.py)
    │
    ▼
Confidence Scoring (confidence.py)
    │
    ▼
Output — Rich / JSON / Markdown / HTML (output.py)
```

---

## Requirements

- Python 3.13+
- A running [Ollama](https://ollama.com) instance (default: `http://imagebeast:11434`)
- The model you want to use pulled in Ollama (default: `gemma4:26b-a4b-it-qat`)
- Internet access for DuckDuckGo and page downloads

---

## Installation

```bash
git clone https://github.com/yourname/search_adv.git
cd search_adv
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## Usage

### Single query

```bash
python search_adv.py "What caused the 2023 banking crisis?"
```

### Restrict to a domain

```bash
python search_adv.py "Python 3.13 new features" --site docs.python.org
```

### Exclude domains

```bash
python search_adv.py "best SSD 2024" --exclude amazon.com ebay.com
```

### JSON output

```bash
python search_adv.py "Is GPT-4o multimodal?" --json
```

### Markdown output

```bash
python search_adv.py "How does TF-IDF work?" --markdown > answer.md
```

### HTML report

```bash
python search_adv.py "Rust vs C++ performance" --html report.html
```

### Change model or endpoint

```bash
python search_adv.py "quantum computing basics" \
  --model llama3.2:3b \
  --endpoint http://localhost:11434
```

### Batch mode

```bash
# queries.txt — one question per line, # for comments
python search_adv.py queries.txt results.csv
```

Output CSV columns: `query`, `answer`, `confidence`, `confidence_label`, `score`, `sources`, `elapsed_seconds`

### Disable cache

```bash
python search_adv.py "latest news" --no-cache
```

### Verbose / debug

```bash
python search_adv.py "my question" --verbose
python search_adv.py "my question" --debug
```

---

## CLI Reference

| Flag | Default | Description |
|---|---|---|
| `--model` | `gemma4:26b-a4b-it-qat` | Ollama model tag |
| `--endpoint` | `http://imagebeast:11434` | Ollama server URL |
| `--results` | `8` | Max DuckDuckGo results to fetch |
| `--chunks` | `5` | Top chunks sent to the LLM |
| `--site` | — | Restrict search to one domain |
| `--exclude` | — | Domains to exclude |
| `--timeout` | `15` | HTTP timeout (seconds) |
| `--no-cache` | off | Disable 24-hour page cache |
| `--verbose` | off | Show pipeline stage progress |
| `--debug` | off | Full debug logging to stderr |
| `--json` | off | Print JSON to stdout |
| `--markdown` | off | Print Markdown to stdout |
| `--html FILE` | — | Write HTML report to FILE |

---

## Confidence Score

Confidence is computed entirely from retrieval signals — not from the LLM:

| Signal | Weight | Description |
|---|---|---|
| Retrieval score | 45% | Average TF-IDF cosine similarity of top chunks |
| Source agreement | 25% | How many distinct sources are represented |
| Authority bonus | 20% | `.gov`, `.edu`, Wikipedia, etc. |
| Chunk coverage | 10% | Number of supporting chunks (saturates at 5) |

Labels: **High** (≥ 70), **Medium** (≥ 40), **Low** (< 40)

---

## Cache

Downloaded pages are cached in `.search_adv_cache/` for 24 hours.
Use `--no-cache` to force a fresh fetch.

---

## Troubleshooting

**"Cannot connect to Ollama"**
Verify the endpoint: `curl http://imagebeast:11434/api/tags`

**"No search results"**
DuckDuckGo rate-limits aggressive queries. Wait a moment and retry.

**Empty or very short answers**
Try `--results 12 --chunks 8` to widen the context window.

**Slow first run**
scikit-learn's TF-IDF vectoriser fits a vocabulary on first use — normal.

---

## Performance Notes

- Downloading 8 pages in series typically takes 5–15 seconds depending on server latency.
- TF-IDF ranking over ~100 chunks completes in under 1 second on any modern CPU.
- Ollama generation time depends entirely on your hardware and the chosen model.
- Use `--no-cache` only when you need fresh data; cached runs are significantly faster.
