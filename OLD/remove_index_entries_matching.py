#!/usr/bin/env python3
"""
remove_index_entries_matching.py

Remove <li class="file"> entries from an index.html whose data-path or data-pdf
match any of the provided patterns.

Usage (dry-run first):
  python3 ../Scripts/remove_index_entries_matching.py --index Doc/index.html --pattern ".*/\\.DS_Store" --pattern ".*index.html.bak.*" --dry-run

To actually apply:
  python3 ../Scripts/remove_index_entries_matching.py --index Doc/index.html --pattern ".*/\\.DS_Store" --pattern ".*index.html.bak.*"

Notes:
 - Patterns are regular expressions matched against the data-path and data-pdf attribute values.
 - The script makes a backup of index.html as Doc/index.html.bak.YYYYMMDDHHMMSS before writing.
"""
from __future__ import annotations
import argparse
import re
import shutil
from pathlib import Path
from datetime import datetime
import sys

LI_RE = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
DATA_PATH_RE = re.compile(r'data-path="([^"]+)"', re.I)
DATA_PDF_RE = re.compile(r'data-pdf="([^"]*)"', re.I)

def find_li_blocks(text: str):
    return LI_RE.findall(text)

def li_matches(li_html: str, patterns):
    m1 = DATA_PATH_RE.search(li_html)
    m2 = DATA_PDF_RE.search(li_html)
    pth = m1.group(1) if m1 else ""
    pdf = m2.group(1) if m2 else ""
    for pat in patterns:
        if re.search(pat, pth) or re.search(pat, pdf):
            return True
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--index', default='Doc/index.html', help='Path to index.html')
    ap.add_argument('--pattern', action='append', help='Regex pattern to match against data-path or data-pdf (repeatable)', required=True)
    ap.add_argument('--dry-run', action='store_true', help='Show what would be removed; do not write')
    args = ap.parse_args()

    index_path = Path(args.index)
    if not index_path.exists():
        print("Index not found:", index_path, file=sys.stderr)
        sys.exit(1)

    txt = index_path.read_text(encoding='utf-8', errors='replace')
    li_blocks = find_li_blocks(txt)
    to_remove = []
    for li in li_blocks:
        if li_matches(li, args.pattern):
            # find the exact span in the full text (first occurrence)
            idx = txt.find(li)
            if idx != -1:
                to_remove.append({'html': li, 'start': idx, 'end': idx + len(li)})
    if not to_remove:
        print("No matching entries found.")
        return

    print("Found", len(to_remove), "matching entries to remove.")
    for i, r in enumerate(to_remove, start=1):
        # show a short preview
        snippet = r['html'][:200].replace('\n', ' ')
        print(f"{i}. {snippet}...")

    if args.dry_run:
        print("Dry-run: nothing will be written.")
        return

    # Remove entries from end->start to preserve indices
    new_txt = txt
    for r in sorted(to_remove, key=lambda x: x['start'], reverse=True):
        new_txt = new_txt[:r['start']] + new_txt[r['end']:]

    # backup and write
    bak = index_path.parent / f"{index_path.name}.bak.{datetime.utcnow().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, bak)
    index_path.write_text(new_txt, encoding='utf-8')
    print(f"Wrote cleaned index to {index_path} (backup at {bak})")

if __name__ == '__main__':
    main()
