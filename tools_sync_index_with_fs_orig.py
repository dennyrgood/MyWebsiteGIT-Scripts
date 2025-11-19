#!/usr/bin/env python3
"""
sync_index_with_fs.py

Interactive helper to compare Doc/ directory contents with Doc/index.html and add any
unreferenced files into the HTML index under a user-selected high-level category.

Usage:
  python3 tools/sync_index_with_fs_orig.py --doc Doc --md Doc/md_outputs --index Doc/index.html

This script:
 - scans Doc/ and Doc/md_outputs/
 - parses Doc/index.html to find categories and data-path references
 - interactively asks you where to place unreferenced files (category, title, one-line desc)
 - inserts <li class="file"> entries into the chosen category's <ul class="files">
 - makes a timestamped backup of Doc/index.html before writing
"""
from __future__ import annotations
import argparse
import os
import re
import sys
import shutil
import html
from pathlib import Path
from datetime import datetime

LI_TEMPLATE = """
            <li class="file" data-path="{data_path}" data-pdf="{data_pdf}">
              <div class="meta">
                <div class="title"><a href=\"#\" class=\"file-link\">{title}</a></div>
                <div class="desc">{desc}</div>
                <div class="tags small-muted">{tags}</div>
              </div>
            </li>
"""

def find_existing_references(index_html_text: str):
    paths = set(re.findall(r'data-path="([^"]+)"', index_html_text))
    pdfs = set(re.findall(r'data-pdf="([^"]*)"', index_html_text))
    return paths, pdfs

def find_categories(index_html_text: str):
    pattern = re.compile(
        r'(<section\s+class="category"[^>]*?>\s*<h2>(?P<cat>.*?)</h2>.*?<ul\s+class="files"[^>]*?>)',
        re.S | re.I
    )
    categories = []
    for m in pattern.finditer(index_html_text):
        cat = html.unescape(m.group('cat').strip())
        section_start = m.start(1)
        ul_open_start = m.end(1)
        ul_close_match = re.search(r'</ul\s*>', index_html_text[ul_open_start:], re.I)
        if not ul_close_match:
            continue
        ul_close_index = ul_open_start + ul_close_match.start()
        categories.append({
            'name': cat,
            'ul_open_index': ul_open_start,
            'ul_close_index': ul_close_index,
            'section_start': section_start
        })
    return categories

def pretty_path(p: Path, doc_dir: Path):
    rel = p.relative_to(doc_dir)
    return "./" + str(rel).replace(os.path.sep, "/")

def file_first_lines(path: Path, n=6):
    try:
        with path.open('r', encoding='utf-8', errors='replace') as f:
            lines = []
            for _ in range(n):
                line = f.readline()
                if not line:
                    break
                lines.append(line.rstrip('\n'))
            return "\n".join(lines)
    except Exception as e:
        return f"[cannot preview file: {e}]"

def html_escape(s: str):
    return html.escape(s)

def main():
    ap = argparse.ArgumentParser(description="Sync Doc/index.html with filesystem: add unreferenced files interactively.")
    ap.add_argument('--doc', default='Doc', help='Doc folder path (default: Doc)')
    ap.add_argument('--md', default='Doc/md_outputs', help='Converted markdown folder (default: Doc/md_outputs)')
    ap.add_argument('--index', default='Doc/index.html', help='Path to interactive index HTML (default: Doc/index.html)')
    ap.add_argument('--yes-to-all', action='store_true', help='Non-interactive: accept defaults for all prompts (fast adds)')
    args = ap.parse_args()

    doc_dir = Path(args.doc)
    md_dir = Path(args.md)
    index_path = Path(args.index)

    if not doc_dir.exists():
        print(f"Error: doc dir not found: {doc_dir}", file=sys.stderr)
        sys.exit(1)
    if not index_path.exists():
        print(f"Error: index file not found: {index_path}", file=sys.stderr)
        sys.exit(1)

    index_text = index_path.read_text(encoding='utf-8', errors='replace')

    existing_paths, existing_pdfs = find_existing_references(index_text)
    categories = find_categories(index_text)
    cat_names = [c['name'] for c in categories]

    disk_files = []
    for p in sorted(doc_dir.iterdir()):
        if p.name in (index_path.name, 'INDEX.md', '_autogen_index.md', 'index.html.bak'):
            continue
        if p.is_dir():
            continue
        disk_files.append(p)

    md_files = []
    if md_dir.exists() and md_dir.is_dir():
        for p in sorted(md_dir.iterdir()):
            if p.is_file():
                md_files.append(p)

    doc_rel_paths = {pretty_path(p, doc_dir): p for p in disk_files}
    md_rel_paths = {('./' + 'md_outputs/' + p.name): p for p in md_files}

    combined_paths = {}
    combined_paths.update(doc_rel_paths)
    combined_paths.update(md_rel_paths)

    unreferenced = []
    for rel_path, p in combined_paths.items():
        if rel_path in existing_paths:
            continue
        stem = p.stem
        if any(stem in ep for ep in existing_paths):
            continue
        unreferenced.append((rel_path, p))

    if not unreferenced:
        print("No unreferenced files found. index.html appears up-to-date with the filesystem.")
        return

    print(f"Found {len(unreferenced)} unreferenced file(s).")
    bak = index_path.parent / f"{index_path.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, bak)
    print(f"Backed up {index_path} -> {bak}")

    modified_text = index_text
    inserts_made = []

    for rel_path, p in unreferenced:
        print("\n-------------------------------")
        print(f"File: {rel_path}")
        print("Preview:")
        print("-------------------------------")
        print(file_first_lines(p, n=8))
        print("-------------------------------")

        suggested = None
        lname = p.name.lower()
        for cat in cat_names:
            if cat.lower() in ('guides', 'guides (setup, long-form)') and (lname.endswith('.md') or 'guide' in lname):
                suggested = cat
                break
        if not suggested:
            suggested = cat_names[0] if cat_names else 'Uncategorized'

        print("Categories:")
        for i, cat in enumerate(cat_names, start=1):
            print(f"  {i}. {cat}")
        print(f"  n. Create a new category")
        print(f"Suggested: {suggested}")

        if args.yes_to_all:
            chosen_cat = suggested
            print(f"[auto] chosen category: {chosen_cat}")
        else:
            choice = input("Choose category number or 'n' (new) [enter to accept suggested]: ").strip()
            if choice == '':
                chosen_cat = suggested
            elif choice.lower() == 'n':
                new_cat = input("Enter new category display name (e.g. 'Guides'): ").strip()
                if not new_cat:
                    print("No category entered; using 'Uncategorized'.")
                    chosen_cat = 'Uncategorized'
                else:
                    chosen_cat = new_cat
                    cat_names.append(chosen_cat)
            else:
                try:
                    idx = int(choice) - 1
                    chosen_cat = cat_names[idx]
                except Exception:
                    print("Invalid choice; using suggested.")
                    chosen_cat = suggested

        default_title = p.stem
        if args.yes_to_all:
            title = default_title
            desc = ""
        else:
            title = input(f"Display title [{default_title}]: ").strip() or default_title
            desc = input("One-line description (leave blank to add later): ").strip()

        fext = p.suffix.lower().lstrip('.')
        ftype = fext.upper() if fext else 'file'
        tags = f"{ftype} · {chosen_cat}"

        data_pdf = ''
        if rel_path.startswith('./md_outputs/'):
            stem = p.stem
            for cand in doc_dir.iterdir():
                if cand.is_file() and cand.suffix.lower() == '.pdf' and cand.stem == stem:
                    data_pdf = "./" + cand.name
                    break
        else:
            if p.suffix.lower() == '.pdf':
                data_pdf = rel_path

        li_html = LI_TEMPLATE.format(
            data_path=html_escape(rel_path),
            data_pdf=html_escape(data_pdf),
            title=html_escape(title),
            desc=html_escape(desc) if desc else "",
            tags=html_escape(tags)
        )

        cat_obj = next((c for c in categories if c['name'].strip().lower() == chosen_cat.strip().lower()), None)
        if cat_obj:
            insert_pos = cat_obj['ul_close_index']
            modified_text = modified_text[:insert_pos] + li_html + modified_text[insert_pos:]
            delta = len(li_html)
            for c in categories:
                if c['ul_close_index'] >= insert_pos:
                    c['ul_close_index'] += delta
                    c['ul_open_index'] += delta
                    c['section_start'] += delta
            print(f"Inserted into existing category '{chosen_cat}'.")
        else:
            lists_close = re.search(r'</div>\s*</aside>', modified_text, re.I)
            new_section_html = f"""
        <section class="category" data-category="{html_escape(chosen_cat)}">
          <h2>{html_escape(chosen_cat)}</h2>
          <ul class="files">
{li_html}
          </ul>
        </section>
"""
            if lists_close:
                insert_pos = lists_close.start()
                modified_text = modified_text[:insert_pos] + new_section_html + modified_text[insert_pos:]
                print(f"Created new category '{chosen_cat}' and inserted entry.")
            else:
                modified_text = modified_text + new_section_html
                print(f"Appended new category '{chosen_cat}' at end of file and inserted entry.")

        inserts_made.append({'path': rel_path, 'title': title, 'category': chosen_cat})

    print("\nSummary of inserts:")
    for it in inserts_made:
        print(f" - {it['path']} -> {it['category']} (title: {it['title']})")

    confirm = 'y'
    if not args.yes_to_all:
        confirm = input(f"\nWrite changes to {index_path}? [y/N]: ").strip().lower()

    if confirm == 'y' or args.yes_to_all:
        index_path.write_text(modified_text, encoding='utf-8')
        print(f"Wrote updated index to {index_path} (backup at {bak})")
    else:
        print("Aborted; no changes written. Backup left at:", bak)

if __name__ == '__main__':
    main()
