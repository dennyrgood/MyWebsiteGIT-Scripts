#!/usr/bin/env python3
"""
tools_connect_md_to_pdf_index.py

Connect converted markdown files in Doc/md_outputs/ to existing PDF entries in Doc/index.html.

Behavior:
 - For each Markdown file in --md (default: Doc/md_outputs), if there exists a PDF in --doc with the same stem,
   and the index.html already contains an entry for that PDF (data-pdf or data-path referencing ./<pdf>),
   then:
     - If the index does NOT already reference the MD (data-path="./md_outputs/<name>"), insert a new
       <li class="file"> entry for the MD into the same category <ul class="files"> where the PDF entry was found.
     - The new <li> will include data-path="./md_outputs/<name>" and data-pdf="./<pdfname>" and will
       copy the tag/category portion from the existing PDF entry when possible.
 - Makes a timestamped backup of index.html before writing.
 - Use --dry-run to show intended changes without writing.

Usage:
  python3 ../Scripts/tools_connect_md_to_pdf_index.py --doc Doc --md Doc/md_outputs --index Doc/index.html --dry-run
  python3 ../Scripts/tools_connect_md_to_pdf_index.py --doc Doc --md Doc/md_outputs --index Doc/index.html

Notes:
 - This does not modify files on disk (PDF/MD) — only updates index.html.
 - If your index.html structure differs from the expected <section class="category"> / <ul class="files"> pattern,
   inspect the file and adjust or ask me to tweak the script.
"""
from __future__ import annotations
import argparse
import re
import shutil
from pathlib import Path
from datetime import datetime
import html
import sys

LI_TEMPLATE = """
            <li class="file" data-path="{data_path}" data-pdf="{data_pdf}">
              <div class="meta">
                <div class="title"><a href="#" class="file-link">{title}</a></div>
                <div class="desc">{desc}</div>
                <div class="tags small-muted">{tags}</div>
              </div>
            </li>
"""

# Regex helpers
SECTION_PATTERN = re.compile(r'(<section\s+class="category"[^>]*?>\s*<h2>(?P<cat>.*?)</h2>.*?<ul\s+class="files"[^>]*?>)', re.S | re.I)
UL_CLOSE_RE = re.compile(r'</ul\s*>', re.I)
LI_RE = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
DATA_PATH_RE = re.compile(r'data-path="([^"]+)"', re.I)
DATA_PDF_RE = re.compile(r'data-pdf="([^"]*)"', re.I)
TAGS_RE = re.compile(r'<div\s+class="tags[^>]*>(.*?)</div>', re.S | re.I)
TITLE_RE = re.compile(r'<div\s+class="title">.*?<a[^>]*>(.*?)</a>', re.S | re.I)

def read_index(path: Path) -> str:
    return path.read_text(encoding='utf-8', errors='replace')

def find_categories(index_text: str):
    categories = []
    for m in SECTION_PATTERN.finditer(index_text):
        cat = html.unescape(m.group('cat').strip())
        section_start = m.start(1)
        ul_open_end = m.end(1)  # position right after the <ul ...> opening tag
        # find the ul closing tag starting from ul_open_end
        ul_close_m = UL_CLOSE_RE.search(index_text[ul_open_end:], re.I)
        if not ul_close_m:
            continue
        ul_close_index = ul_open_end + ul_close_m.start()
        categories.append({
            'name': cat,
            'ul_open_index': ul_open_end,
            'ul_close_index': ul_close_index,
            'section_start': section_start
        })
    return categories

def find_li_blocks_between(text: str, start: int, end: int):
    fragment = text[start:end]
    return LI_RE.findall(fragment)

def li_contains_pdf(li_html: str, pdf_rel: str) -> bool:
    # match either data-pdf="./foo.pdf" or data-path="./foo.pdf"
    if f'data-pdf="{pdf_rel}"' in li_html:
        return True
    if f'data-path="{pdf_rel}"' in li_html:
        return True
    return False

def li_contains_data_path(li_html: str, data_path: str) -> bool:
    return f'data-path="{data_path}"' in li_html

def extract_tags(li_html: str) -> str:
    m = TAGS_RE.search(li_html)
    if not m:
        return ""
    return ' '.join(m.group(1).strip().split())

def extract_title(li_html: str, default: str) -> str:
    m = TITLE_RE.search(li_html)
    if m:
        t = re.sub(r'\s+', ' ', m.group(1).strip())
        return t or default
    return default

def build_li(md_rel: str, pdf_rel: str, title: str, tags: str, desc: str = "") -> str:
    # keep tags short; if tags already contain '· category' use it, else place category as tags (caller supplies)
    return LI_TEMPLATE.format(
        data_path=html.escape(md_rel),
        data_pdf=html.escape(pdf_rel),
        title=html.escape(title),
        desc=html.escape(desc),
        tags=html.escape(tags or "")
    )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--doc', default='Doc', help='Doc folder')
    ap.add_argument('--md', default='Doc/md_outputs', help='md_outputs folder')
    ap.add_argument('--index', default='Doc/index.html', help='index html path')
    ap.add_argument('--dry-run', action='store_true', help="Don't write, only show planned changes")
    ap.add_argument('--yes', action='store_true', help="Assume yes to prompts (non-interactive)")
    args = ap.parse_args()

    doc_dir = Path(args.doc)
    md_dir = Path(args.md)
    index_path = Path(args.index)

    if not doc_dir.exists() or not index_path.exists():
        print("Doc directory or index.html not found.", file=sys.stderr)
        sys.exit(1)

    index_text = read_index(index_path)
    categories = find_categories(index_text)

    if not categories:
        print("No categories found in index.html; aborting.", file=sys.stderr)
        sys.exit(1)

    # build map: for each category record ul range
    cat_map = categories  # list of dicts with ul_open_index and ul_close_index and name

    # gather md files
    md_files = sorted([p for p in md_dir.iterdir() if p.is_file() and p.suffix.lower()=='.md']) if md_dir.exists() else []
    if not md_files:
        print("No md files found in", md_dir)
        return

    planned_inserts = []
    modified_text = index_text
    total_added = 0

    for mdf in md_files:
        stem = mdf.stem
        md_rel = f'./md_outputs/{mdf.name}'
        # skip obvious editor temp files
        if mdf.name.startswith('~$') or mdf.name.startswith('.'):
            continue

        # if md already referenced, skip
        if md_rel in index_text:
            # already referenced
            continue

        # find corresponding pdf in doc_dir
        pdf_candidate = doc_dir / (stem + '.pdf')
        if not pdf_candidate.exists():
            # maybe the index references a different pdf name; try to find any pdf in index with the same stem
            # we'll search index_text for data-pdf or data-path containing the stem + .pdf
            pdf_match = None
            for m in re.finditer(r'data-pdf="([^"]*\.pdf)"', index_text, re.I):
                val = m.group(1)
                if Path(val).stem == stem:
                    pdf_match = val
                    break
            for m in re.finditer(r'data-path="([^"]*\.pdf)"', index_text, re.I):
                val = m.group(1)
                if Path(val).stem == stem:
                    pdf_match = val
                    break
            if pdf_match is None:
                # no pdf to attach to; skip
                continue
            pdf_rel = pdf_match
        else:
            pdf_rel = f'./{pdf_candidate.name}'

        # check whether an entry referencing md_rel already exists (redundant check)
        if md_rel in index_text:
            continue

        # find the li that references this pdf (search whole index)
        li_for_pdf = None
        li_start_index = None
        # iterate over categories and their li blocks to find the li and where to insert
        found_category = None
        found_cat_obj = None
        for cat in cat_map:
            lis = find_li_blocks_between(index_text, cat['ul_open_index'], cat['ul_close_index'])
            for li in lis:
                if li_contains_pdf(li, pdf_rel):
                    li_for_pdf = li
                    # compute the absolute li start index by finding first occurrence of this li inside that span
                    span_text = index_text[cat['ul_open_index']:cat['ul_close_index']]
                    off = span_text.find(li)
                    if off >= 0:
                        li_start_index = cat['ul_open_index'] + off
                    found_category = cat['name']
                    found_cat_obj = cat
                    break
            if li_for_pdf:
                break

        if not li_for_pdf or not found_cat_obj:
            # no pdf entry found in index; skip (could add new entry but we only "connect" to existing PDF entries)
            continue

        # determine tags/title to reuse
        existing_tags = extract_tags(li_for_pdf)
        existing_title = extract_title(li_for_pdf, default=mdf.stem)
        # if tags include a '·' with category, keep them; otherwise append category name
        tags_to_use = existing_tags if existing_tags else found_category or ""
        # build new li for md
        new_li = build_li(md_rel=md_rel, pdf_rel=pdf_rel, title=existing_title, tags=tags_to_use, desc="")

        # ensure we do not already have an identical data-path entry in the category
        # check the category's span for md_rel
        cat_span = modified_text[found_cat_obj['ul_open_index']:found_cat_obj['ul_close_index']]
        if md_rel in cat_span:
            # already present after earlier insertions
            continue

        # plan to insert before the category's ul close
        insert_pos = found_cat_obj['ul_close_index']
        planned_inserts.append({
            'md': md_rel,
            'pdf': pdf_rel,
            'category': found_category,
            'insert_pos': insert_pos,
            'li_html': new_li
        })

        # update indices in found_cat_obj and subsequent categories to reflect planned insertion
        # perform insertion in the working modified_text so subsequent inserts see updated positions
        modified_text = modified_text[:insert_pos] + new_li + modified_text[insert_pos:]
        delta = len(new_li)
        for c in cat_map:
            if c['ul_close_index'] >= insert_pos:
                c['ul_close_index'] += delta
                c['ul_open_index'] += delta
                c['section_start'] += delta
        total_added += 1

    if not planned_inserts:
        print("No MD files needed connection to an existing PDF entry in the index.")
        return

    # show summary
    print(f"Planned to add {total_added} MD entries linking to existing PDFs:")
    for p in planned_inserts:
        print(f" - {p['md']}  -> category: {p['category']} (pdf: {p['pdf']})")

    if args.dry_run:
        print("Dry-run: no file changes written.")
        return

    # backup and write
    bak = index_path.parent / f"{index_path.name}.bak.{datetime.utcnow().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, bak)
    index_path.write_text(modified_text, encoding='utf-8')
    print(f"Wrote updated index to {index_path} (backup at {bak})")
    return

if __name__ == '__main__':
    main()