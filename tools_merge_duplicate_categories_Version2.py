#!/usr/bin/env python3
"""
merge_duplicate_categories.py

Merge duplicate <section class="category"> blocks in Doc/index.html that have the same display name.

Usage:
  python3 tools/merge_duplicate_categories.py --index Doc/index.html
  python3 tools/merge_duplicate_categories.py --index Doc/index.html --dry-run

What it does:
 - Finds all <section class="category">...</section> blocks
 - Normalizes the <h2> category name (strip, lower)
 - For any normalized name appearing >1, merges all <li class="file"> entries into the first block
 - Removes the other duplicate blocks
 - De-duplicates entries by the data-path attribute
 - Backs up Doc/index.html to Doc/index.html.bak.YYYYMMDDHHMMSS before writing
"""
from __future__ import annotations
import argparse
import re
import sys
import shutil
from pathlib import Path
from datetime import datetime
import html

SECTION_RE = re.compile(r'(<section\s+class="category"[^>]*>.*?</section>)', re.S | re.I)
H2_RE = re.compile(r'<h2>(.*?)</h2>', re.S | re.I)
UL_RE = re.compile(r'(<ul\s+class="files"[^>]*>)(.*?)(</ul>)', re.S | re.I)
LI_RE = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
DATA_PATH_RE = re.compile(r'data-path="([^"]+)"', re.I)

def extract_sections(text: str):
    sections = []
    for m in SECTION_RE.finditer(text):
        full = m.group(1)
        start = m.start(1)
        end = m.end(1)
        # h2
        h2m = H2_RE.search(full)
        title = h2m.group(1).strip() if h2m else ""
        # ul content
        ulm = UL_RE.search(full)
        ul_open = ulm.group(1) if ulm else ""
        ul_inner = ulm.group(2) if ulm else ""
        ul_close = ulm.group(3) if ulm else ""
        lis = LI_RE.findall(ul_inner) if ulm else []
        sections.append({
            'title': title,
            'full_html': full,
            'start': start,
            'end': end,
            'ul_open': ul_open,
            'ul_close': ul_close,
            'li_list': lis,
        })
    return sections

def normalize_name(name: str) -> str:
    return ' '.join(name.strip().lower().split())

def merge_sections(text: str):
    sections = extract_sections(text)
    groups: dict[str, list] = {}
    for s in sections:
        key = normalize_name(s['title'])
        groups.setdefault(key, []).append(s)

    # find duplicates
    dup_keys = [k for k,v in groups.items() if len(v) > 1]
    if not dup_keys:
        return False, "No duplicate categories found", text

    new_text = text
    # We'll apply replacements from end->start so indices don't shift unexpectedly
    # Build a list of (remove_start, remove_end) for sections to remove, and replacements for the first section
    edits = []
    for key in dup_keys:
        group = groups[key]
        primary = group[0]
        others = group[1:]
        # collect existing data-paths in primary to avoid duplicates
        existing_paths = set()
        for li in primary['li_list']:
            m = DATA_PATH_RE.search(li)
            if m:
                existing_paths.add(m.group(1))
        # collect li blocks to append from others (in original order)
        to_append = []
        for sec in others:
            for li in sec['li_list']:
                m = DATA_PATH_RE.search(li)
                path = m.group(1) if m else None
                if path and path in existing_paths:
                    continue
                # avoid adding empty or duplicate li text
                to_append.append(li)
                if path:
                    existing_paths.add(path)
        if not to_append:
            # nothing to merge; just mark others for removal
            for sec in others:
                edits.append(('remove', sec['start'], sec['end'], sec['full_html'], None))
            continue

        # create new primary HTML: insert to_append before the closing </ul> of primary
        primary_block = primary['full_html']
        # find the </ul> for the files list inside the primary block
        new_primary = re.sub(UL_RE, lambda m: m.group(1) + m.group(2) + ''.join(to_append) + m.group(3), primary_block, count=1)
        edits.append(('replace', primary['start'], primary['end'], primary['full_html'], new_primary))
        # remove the other sections
        for sec in others:
            edits.append(('remove', sec['start'], sec['end'], sec['full_html'], None))

    # Apply edits sorted by start descending so indices remain valid
    edits_sorted = sorted(edits, key=lambda e: e[1], reverse=True)
    for typ, sidx, eidx, old, new in edits_sorted:
        # sanity check old snippet exists at that span
        snippet = new_text[sidx:eidx]
        if snippet != old:
            # try to locate the old snippet elsewhere (robustify)
            found_at = new_text.find(old)
            if found_at == -1:
                # fallback: try to locate by title
                # skip this edit if we cannot find exact old snippet
                print(f"Warning: could not find exact section snippet to edit for start={sidx} end={eidx}. Skipping this edit.")
                continue
            else:
                sidx = found_at
                eidx = found_at + len(old)
        if typ == 'replace':
            new_text = new_text[:sidx] + new + new_text[eidx:]
        elif typ == 'remove':
            new_text = new_text[:sidx] + new_text[eidx:]
    return True, f"Merged keys: {', '.join(dup_keys)}", new_text

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--index', default='Doc/index.html', help='Path to index.html')
    p.add_argument('--dry-run', action='store_true', help='Show actions but do not write')
    args = p.parse_args()

    index_path = Path(args.index)
    if not index_path.exists():
        print("Index file not found:", index_path)
        sys.exit(1)

    txt = index_path.read_text(encoding='utf-8', errors='replace')
    ok, msg, new_txt = merge_sections(txt)
    print(msg)
    if not ok:
        print("No changes required.")
        return

    if args.dry_run:
        print("Dry-run enabled — no file written. Review the changes manually.")
        return

    # backup
    bak = index_path.parent / f"{index_path.name}.bak.{datetime.utcnow().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, bak)
    index_path.write_text(new_txt, encoding='utf-8')
    print(f"Wrote merged index to {index_path} (backup at {bak})")

if __name__ == '__main__':
    main()