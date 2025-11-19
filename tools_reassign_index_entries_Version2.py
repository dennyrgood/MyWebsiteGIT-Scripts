#!/usr/bin/env python3
"""
reassign_index_entries.py

Interactive helper to move entries in Doc/index.html between categories and update tags.

Usage:
  python3 tools/reassign_index_entries.py --index Doc/index.html

What it does:
 - Parses categories ( <section class="category"> <h2>NAME</h2> <ul class="files"> ... )
 - Lists entries per category
 - Let you select one or more entries and move them to another category (or create a new category)
 - Updates the <div class="tags small-muted">... to include the new category
 - Backs up index file to Doc/index.html.bak.TIMESTAMP before writing changes

Notes:
 - This updates only the HTML index; it will not touch files on disk.
 - If your index.html structure differs significantly from the expected pattern, open the file and inspect the sections and <ul class="files"> structure.
"""
from __future__ import annotations
import argparse
import re
import sys
import shutil
from pathlib import Path
from datetime import datetime
import html

def find_categories(index_text: str):
    pattern = re.compile(
        r'(<section\s+class="category"[^>]*?>\s*<h2>(?P<cat>.*?)</h2>.*?<ul\s+class="files"[^>]*?>)',
        re.S | re.I
    )
    categories = []
    for m in pattern.finditer(index_text):
        cat = html.unescape(m.group('cat').strip())
        section_start = m.start(1)
        ul_open_start = m.end(1)
        ul_close_match = re.search(r'</ul\s*>', index_text[ul_open_start:], re.I)
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

def extract_li_blocks(ul_html: str):
    # find all <li class="file"...>...</li>
    li_pattern = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
    return li_pattern.findall(ul_html)

def parse_li_data(li_html: str):
    # get data-path
    m_path = re.search(r'data-path="([^"]+)"', li_html)
    m_pdf = re.search(r'data-pdf="([^"]*)"', li_html)
    path = m_path.group(1) if m_path else ""
    pdf = m_pdf.group(1) if m_pdf else ""
    # title inside <div class="title">...<a ...>Title</a>...
    m_title = re.search(r'<div\s+class="title">.*?<a[^>]*>(.*?)</a>', li_html, re.S)
    title = re.sub(r'\s+', ' ', m_title.group(1).strip()) if m_title else ""
    # tags div
    m_tags = re.search(r'<div\s+class="tags[^>]*>(.*?)</div>', li_html, re.S)
    tags = re.sub(r'\s+', ' ', m_tags.group(1).strip()) if m_tags else ""
    return {'html': li_html, 'data_path': path, 'data_pdf': pdf, 'title': title, 'tags': tags}

def list_entries_by_cat(index_text: str, categories: list):
    entries = []
    for idx, c in enumerate(categories):
        ul_html = index_text[c['ul_open_index']:c['ul_close_index']]
        li_blocks = extract_li_blocks(ul_html)
        parsed = [parse_li_data(li) for li in li_blocks]
        entries.append(parsed)
    return entries

def prompt_select(indices_range_desc: str):
    s = input(f"Select entries (e.g. 1,3-5 or 'all'): ").strip()
    if not s:
        return []
    if s.lower() == 'all':
        return indices_range_desc  # signal to caller to treat as all
    sel = set()
    parts = s.split(',')
    for p in parts:
        p = p.strip()
        if '-' in p:
            a,b = p.split('-',1)
            try:
                a_i = int(a)-1; b_i = int(b)-1
            except:
                continue
            sel.update(range(a_i, b_i+1))
        else:
            try:
                sel.add(int(p)-1)
            except:
                continue
    return sorted(sel)

def update_tags_in_li(li_html: str, new_cat: str):
    # replace existing tags block content (preserve type if present)
    # look for pattern like: <div class="tags small-muted">TXT · Guides</div>
    # We'll keep the left part up to the first '·' if present (type). If none, leave type blank.
    m = re.search(r'(<div\s+class="tags[^>]*>)(.*?)(</div>)', li_html, re.S)
    if not m:
        # append a tags div
        tag_html = f'<div class="tags small-muted">{html.escape(new_cat)}</div>'
        # insert before closing </div> of meta (safe hack: insert before last </div> in li)
        li_html = li_html.replace('</div>\n            </li>', f'{tag_html}\n            </li>')
        return li_html
    pre, content, post = m.group(1), m.group(2), m.group(3)
    # split on '·' if present
    if '·' in content:
        left = content.split('·',1)[0].strip()
        new_content = f"{left} · {new_cat}"
    else:
        # try to preserve a known type (e.g., 'PDF', 'MD', 'TXT') at start (word characters)
        left_match = re.match(r'\s*([A-Za-z0-9_()+\- ]+)\s*', content)
        if left_match and len(content.strip())>0:
            left = left_match.group(1).strip()
            new_content = f"{left} · {new_cat}"
        else:
            new_content = new_cat
    new_block = pre + html.escape(new_content) + post
    # replace the first occurrence
    li_html = li_html[:m.start(1)] + new_block + li_html[m.end(3):]
    return li_html

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--index', default='Doc/index.html')
    args = p.parse_args()
    index_path = Path(args.index)
    if not index_path.exists():
        print("Index file not found:", index_path)
        sys.exit(1)

    text = index_path.read_text(encoding='utf-8', errors='replace')
    categories = find_categories(text)
    if not categories:
        print("No categories detected in index.html. Aborting.")
        sys.exit(1)

    entries_by_cat = list_entries_by_cat(text, categories)

    # show categories and counts
    print("\nCategories found:")
    for i,c in enumerate(categories, start=1):
        count = len(entries_by_cat[i-1])
        print(f"  {i}. {c['name']} ({count} entries)")

    # ask which source category to correct (allow multiple rounds)
    while True:
        src_choice = input("\nEnter the number of the category you want to edit (or 'q' to quit): ").strip()
        if src_choice.lower() == 'q':
            print("No changes made. Exiting.")
            return
        try:
            src_idx = int(src_choice)-1
            if not (0 <= src_idx < len(categories)):
                print("Invalid category number.")
                continue
        except:
            print("Enter a number.")
            continue

        src_cat = categories[src_idx]['name']
        src_entries = entries_by_cat[src_idx]
        if not src_entries:
            print(f"No entries in '{src_cat}'.")
            continue

        print(f"\nEntries in '{src_cat}':")
        for j, e in enumerate(src_entries, start=1):
            print(f" {j}. {e['title']}  [{e['data_path']}]  tags: {e['tags']}")

        sel = prompt_select(list(range(len(src_entries))))
        if sel == []:
            print("No selection made. Returning to category select.")
            continue
        if sel == list(range(len(src_entries))):  # 'all' flagged as full range
            indices = list(range(len(src_entries)))
        elif sel == list(range(len(src_entries))):
            indices = list(range(len(src_entries)))
        elif sel == 'all':
            indices = list(range(len(src_entries)))
        else:
            indices = sel

        # show target categories
        print("\nTarget categories:")
        for i,c in enumerate(categories, start=1):
            print(f"  {i}. {c['name']}")
        print("  n. Create a new category")

        tgt_choice = input("Choose target category number or 'n' to create new: ").strip()
        if tgt_choice.lower() == 'n':
            new_name = input("Enter new category display name: ").strip()
            if not new_name:
                print("Empty name; aborted.")
                continue
            # create new category HTML and append before </div></aside>
            new_section = f'''
        <section class="category" data-category="{html.escape(new_name)}">
          <h2>{html.escape(new_name)}</h2>
          <ul class="files">
          </ul>
        </section>
'''
            # insert before the closing of #lists area
            lists_close = re.search(r'</div>\s*</aside>', text, re.I)
            if lists_close:
                insert_pos = lists_close.start()
                text = text[:insert_pos] + new_section + text[insert_pos:]
                # re-parse categories and entries
                categories = find_categories(text)
                entries_by_cat = list_entries_by_cat(text, categories)
                # find index of the newly created category
                tgt_idx = next(i for i,c in enumerate(categories) if c['name'].strip().lower()==new_name.strip().lower())
                print(f"Created new category '{new_name}'.")
            else:
                print("Could not find insertion point for new category. Aborting.")
                continue
        else:
            try:
                tgt_idx = int(tgt_choice)-1
                if not (0 <= tgt_idx < len(categories)):
                    print("Invalid target.")
                    continue
            except:
                print("Invalid input.")
                continue

        tgt_cat = categories[tgt_idx]['name']
        print(f"Moving {len(indices)} entr{'y' if len(indices)==1 else 'ies'} from '{src_cat}' -> '{tgt_cat}'")

        # perform moves: remove from src ul and insert into target ul; update tags inside li
        # Rebuild text by working with indices (note: categories list contains indices into current 'text')
        # Extract li blocks for current categories (fresh)
        categories = find_categories(text)
        entries_by_cat = list_entries_by_cat(text, categories)

        # get current li blocks' positions for source category
        s = categories[src_idx]
        ul_content = text[s['ul_open_index']:s['ul_close_index']]
        li_blocks = extract_li_blocks(ul_content)
        # build map index->li_html (as present in text)
        selected_li_htmls = []
        # remove from ul content by replacing exact li block occurrences (first occurrence)
        for local_idx in sorted(indices, reverse=True):
            try:
                li_html = li_blocks[local_idx]
            except IndexError:
                print(f"Index {local_idx+1} out of range; skipping")
                continue
            selected_li_htmls.append(li_html)
            # remove one occurrence of this li_html
            ul_content = ul_content.replace(li_html, '', 1)
        # write back updated source ul content
        text = text[:s['ul_open_index']] + ul_content + text[s['ul_close_index']:]

        # update target positions after modification
        categories = find_categories(text)
        tgt = categories[tgt_idx]
        insert_pos = tgt['ul_close_index']
        # reverse selected_li_htmls to preserve original order when inserting at insert_pos
        for li_html in reversed(selected_li_htmls):
            # update tags inside li to reflect new category
            new_li = update_tags_in_li(li_html, tgt_cat)
            text = text[:insert_pos] + new_li + text[insert_pos:]
            # adjust insert_pos earlier for next insert (we're inserting before the same close tag)
            # no need to adjust since we keep inserting before the closing tag

        # After operation, re-parse categories and entries so loop can continue
        categories = find_categories(text)
        entries_by_cat = list_entries_by_cat(text, categories)

        # confirm and optionally save
        print("\nOperation staged. Preview of target category entries (recent additions at end):")
        tgt_idx = next(i for i,c in enumerate(categories) if c['name']==tgt_cat)
        for j,e in enumerate(entries_by_cat[tgt_idx], start=1):
            print(f" {j}. {e['title']}  [{e['data_path']}]  tags: {e['tags']}")

        save = input("\nSave changes to index.html? [y/N]: ").strip().lower()
        if save == 'y':
            bak = index_path.parent / f"{index_path.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
            shutil.copy2(index_path, bak)
            index_path.write_text(text, encoding='utf-8')
            print(f"Wrote updated index to {index_path} (backup at {bak})")
        else:
            print("Changes not saved. Exiting without writing.")
        return

if __name__ == '__main__':
    main()