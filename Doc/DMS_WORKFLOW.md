# DMS (Document Management System) - Complete Refactored Workflow

## Architecture

### Master State: `.dms_state.json`
Single source of truth for all documents and their metadata.
```json
{
  "metadata": {...},
  "categories": ["Guides", "Workflows", "Models", "Scripts", "QuickRefs"],
  "documents": {
    "./path/to/file.pdf": {
      "hash": "sha256:...",
      "category": "Guides",
      "summary": "...",
      "summary_approved": true,
      "title": "...",
      "last_processed": "..."
    }
  }
}
```

### Intermediate Files (Pending Approval)
- `.dms_scan.json` - Changes detected by scan
- `.dms_pending_summaries.json` - AI-generated summaries awaiting review
- `.dms_pending_approved.json` - User-approved changes awaiting apply

## Complete Workflow

### 1. INIT (Fresh Start)
```bash
dms init
```
Creates:
- `Doc/` directory
- `.dms_state.json` (empty state)
- `index.html` (empty HTML)

### 2. USER ADDS/DELETES FILES
Manually add or remove files in `Doc/` directory.

### 3. SCAN
```bash
dms scan
```
- Compares filesystem against `.dms_state.json`
- Detects: new files, changed files, deleted files
- Outputs: `.dms_scan.json` (what changed)
- Reports: what will be processed in next steps

### 4. IMAGE-TO-TEXT (Optional)
```bash
dms image-to-text
```
- Reads `.dms_scan.json` for new files
- Finds images (PNG, JPG, GIF, etc.)
- Converts images → text via OCR (tesseract)
- Outputs: `md_outputs/*.txt` (OCR results)
- Next: These text files get summarized along with other docs

### 5. SUMMARIZE
```bash
dms summarize [--model MODEL] [--dry-run]
```
- Reads `.dms_scan.json` for files to process
- Reads file contents
- Calls Ollama API to generate summaries
- Auto-categorizes based on content keywords
- Outputs: `.dms_pending_summaries.json`
- Pending: Awaiting user review

Options:
- `--model MODEL` - Override Ollama model
- `--dry-run` - Show what would happen, don't write

### 6. REVIEW (Interactive Approval)
```bash
dms review [--all]
```
For each summary, user can:
- `[a]pprove` - Accept summary and category
- `[e]dit` - Edit the summary text
- `[c]ategory` - Change assigned category
- `[s]kip` - Skip this file
- `[q]uit` - Stop review

Outputs: `.dms_pending_approved.json` (ready for apply)

Options:
- `--all` - Auto-approve all without review

### 7. APPLY
```bash
dms apply
```
- Reads `.dms_pending_approved.json`
- Updates `.dms_state.json` with approved entries
- Calls `dms render` to regenerate HTML
- Outputs: Updated `index.html`
- Cleans up `.dms_pending_approved.json`

### 8. CLEANUP (Optional, when files deleted)
```bash
dms cleanup
```
- Finds files in `.dms_state.json` but not on disk
- Removes them from state
- Regenerates `index.html`

### 9. RENDER (Manual Re-render)
```bash
dms render
```
- Regenerates `index.html` from `.dms_state.json`
- No data changes, pure presentation update
- Use if you manually edited `.dms_state.json`

### 10. STATUS
```bash
dms status
```
Shows:
- Number of documents in state
- Categories
- Last scan/apply times

## AUTO Mode (Full Workflow)
```bash
dms auto
```
Runs: scan → image-to-text → summarize → review → apply

## Key Points

✅ **No more HTML manipulation bugs**
- All state stored in JSON
- HTML is pure presentation (regenerated each time)

✅ **Clean separation of concerns**
- State: `.dms_state.json`
- Pending changes: `.dms_*_*.json` files
- Presentation: `index.html`

✅ **Atomic updates**
- State only updated at `apply` step
- Safe to interrupt at any stage

✅ **Easy to debug**
- JSON files are human-readable
- Can manually edit state if needed

✅ **No orphaned entries**
- All files are either in state or deleted
- Proper categorization or marked for review

## Config

`dms_config.json` in Scripts directory:
```json
{
  "ollama_model": "phi3:mini",
  "ollama_host": "https://ollama.ldmathes.cc",
  "summary_max_words": 50,
  "temperature": 0.3
}
```

## Troubleshooting

**No changes detected**: Run `dms scan` to see what changed

**Ollama connection error**: Check `dms_config.json` host/port

**Want to re-scan everything**: Delete `.dms_scan.json` and re-run scan

**Want to re-summarize**: Delete `.dms_pending_*.json` files and re-run workflow

**Manually edit state**: Edit `.dms_state.json` directly, then run `dms render`

## Old Programs (Deprecated)

Removed:
- `dms_delete_orphans.py` - Orphan issue fixed, no longer needed

Backed up:
- `dms_scan.py.old`
- `dms_apply.py.old`
- `dms_init.py.old`
- `dms_summarize.py.old`
- `dms_review.py.old`
- `dms_image_to_text.py.old`
- `dms_cleanup.py.old`

All new versions work with `.dms_state.json`.
