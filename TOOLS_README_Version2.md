```markdown
# Tools README — Doc/ index maintenance toolkit

This folder contains helpers for converting PDFs, keeping Doc/index.html in sync with the filesystem, and tidying the HTML index.

Files you may have:
- tools_pdf_to_md_textonly.py
- tools_generate_doc_index.py
- tools_convert_and_sync_Version7.py
- tools_sync_index_with_fs_orig.py
- tools_sync_index_with_fs.py
- tools_merge_duplicate_categories_Version2.py
- tools_reassign_index_entries_Version2.py
- tools_unreferences_files.py
- tools_connect_md_to_pdf_index.py
- tools_manager.py  (single combined CLI — recommended)

Quick high-level workflow (recommended)
1. Convert PDFs → Markdown (if you want MD previews / search)
   - Use your converter or the combined tool.
   - Example: `python3 ../Scripts/tools_pdf_to_md_textonly.py Doc --out-dir Doc/md_outputs`
   - OR: `python3 ../Scripts/tools_manager.py convert --doc Doc --md Doc/md_outputs`

2. Attach converted MDs to already-indexed PDFs
   - Dry-run first:
     `python3 ../Scripts/tools_connect_md_to_pdf_index.py --doc Doc --md Doc/md_outputs --index Doc/index.html --dry-run`
   - Or with combined tool:
     `python3 ../Scripts/tools_manager.py connect --doc Doc --md Doc/md_outputs --index Doc/index.html --dry-run`
   - If output looks correct, run without `--dry-run`.

3. Sync new files into index (interactive)
   - Interactive sync to add completely new files (asks category/title/desc):
     `python3 ../Scripts/tools_sync_index_with_fs_orig.py --doc Doc --md Doc/md_outputs --index Doc/index.html`
   - Or via combined tool (it will prefer your existing sync script if present):
     `python3 ../Scripts/tools_manager.py sync --doc Doc --md Doc/md_outputs --index Doc/index.html`

4. Merge duplicate categories (dry-run first)
   - `python3 ../Scripts/tools_merge_duplicate_categories_Version2.py --index Doc/index.html --dry-run`
   - Combined:
     `python3 ../Scripts/tools_manager.py merge --index Doc/index.html --dry-run`

5. Reassign entries (interactive)
   - `python3 ../Scripts/tools_reassign_index_entries_Version2.py --index Doc/index.html`
   - Combined:
     `python3 ../Scripts/tools_manager.py reassign --index Doc/index.html`

6. Find unreferenced files (report)
   - `python3 ../Scripts/tools_unreferences_files.py --doc Doc --md Doc/md_outputs --index Doc/index.html`
   - Combined:
     `python3 ../Scripts/tools_manager.py list-unreferenced --doc Doc --md Doc/md_outputs --index Doc/index.html`

Safety tips
- Always run `--dry-run` when supported before write operations.
- Every mutating helper creates a timestamped backup of `Doc/index.html` (e.g., `Doc/index.html.bak.YYYYMMDDHHMMSS`).
- Restore example:
  `cp Doc/index.html.bak.20251119005911 Doc/index.html`
- Add backups and temp files to `.gitignore`:
  ```
  .DS_Store
  Doc/index.html.bak*
  ```
- Remove Finder junk:
  `find . -name '.DS_Store' -print -delete`

Combined tool quick test (after you save the script)
- Make executable:
  `chmod +x ../Scripts/tools_manager.py`
- Show help:
  `python3 ../Scripts/tools_manager.py --help`
- Show subcommands:
  `python3 ../Scripts/tools_manager.py convert --help`

When to use which:
- Use `convert` when you add new PDFs and want Markdown previews/searchable text.
- Use `connect` when you have converted MDs and want them linked to already-indexed PDFs.
- Use `sync` to add truly new files to the index interactively.
- Use `merge` after automated processes that created duplicate categories.
- Use `reassign` to move entries between categories interactively.
- Use `list-unreferenced` as a final verification step.

```markdown
tools_remove_index_entries_matching.py
- Purpose: Remove unwanted <li class="file"> entries from Doc/index.html by matching data-path or data-pdf with one or more regex patterns.
- When to run: Use when you want to clean many similar, unwanted index entries (eg. .DS_Store, index.html backups, Office temp files) in bulk.
- Why: Safe bulk removal with dry-run preview and an automatic timestamped backup before any write.
- Example dry-run:
  python3 ../Scripts/remove_index_entries_matching.py --index Doc/index.html --pattern '^\./~\$ep for 3060.*' --dry-run
- Apply the removal (creates backup):
  python3 ../Scripts/remove_index_entries_matching.py --index Doc/index.html --pattern '^\./~\$ep for 3060.*'
- Tips:
  - Quote the pattern with single quotes to prevent shell expansion of $ or ~.
  - Escape literal "./" as `\./` and literal `.` in `.html` as `\.html`.
  - Use anchors (^, $) for precise matches; use `.*` to match arbitrary trailing text.
  - Always run the dry-run first; restore from Doc/index.html.bak.YYYYMMDDHHMMSS if needed.
```
