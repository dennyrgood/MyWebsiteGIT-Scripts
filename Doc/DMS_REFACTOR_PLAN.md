# DMS Refactor Plan: Data Separation

## Current Architecture (Broken)
- Data embedded in index.html as DMS_STATE comment
- HTML manipulation via regex/string replacement
- Fragile, error-prone, hard to debug

## New Architecture
- Master state in `.dms_state.json` (all document metadata)
- index.html regenerated from JSON (no manual manipulation)
- Clean separation of concerns

## Data Structure: .dms_state.json

```json
{
  "metadata": {
    "last_scan": "2025-11-20T10:29:38Z",
    "last_apply": "2025-11-20T10:29:38Z"
  },
  "categories": ["Guides", "Workflows", "Models", "QuickRefs", "Scripts", "Junk"],
  "documents": {
    "./path/to/file.pdf": {
      "hash": "sha256:...",
      "category": "Guides",
      "summary": "...",
      "summary_approved": true,
      "last_processed": "2025-11-20T10:29:38Z"
    }
  }
}
```

## Workflow Changes

### dms_scan.py
- Scans Doc/ directory
- Compares against `.dms_state.json`
- Updates `.dms_pending_scan.json` with changes
- NO HTML manipulation

### dms_summarize.py
- Reads from `.dms_pending_scan.json`
- Generates summaries
- Updates `.dms_pending_summaries.json`
- NO HTML manipulation

### dms_review.py
- Reads from `.dms_pending_summaries.json`
- User approves/edits
- Updates `.dms_pending_approved.json`
- NO HTML manipulation

### dms_apply.py
- Reads from `.dms_pending_approved.json`
- Updates `.dms_state.json` with new data
- Calls `dms_render.py` to regenerate HTML
- NO direct HTML manipulation

### dms_render.py (NEW)
- Reads `.dms_state.json`
- Generates index.html from template
- Pure function: state → HTML
- Easy to test, easy to customize

## Migration Steps

1. Create new `.dms_state.json` from current index.html DMS_STATE
2. Update each script to use JSON instead of HTML
3. Create `dms_render.py` to generate HTML
4. Test with small subset
5. Full test
6. Cleanup old code

## Advantages

✓ No more regex bugs
✓ Easy to debug (JSON is readable)
✓ Easy to version control
✓ Easy to generate different HTML templates
✓ Atomic updates to state (JSON is single file)
✓ Can easily add new features (exports, reports, etc.)
