#!/usr/bin/env python3
"""
List files in Doc/ and Doc/md_outputs/ that are not referenced in Doc/index.html.

Usage:
  python3 tools/list_unreferenced_files.py --doc Doc --md Doc/md_outputs --index Doc/index.html
"""
from pathlib import Path
import argparse
import os
import re
import sys

def parse_index(index_path: Path):
    txt = index_path.read_text(encoding='utf-8', errors='replace')
    paths = set(re.findall(r'data-path="([^"]+)"', txt))
    # also gather data-pdf references
    pdfs = set(re.findall(r'data-pdf="([^"]*)"', txt))
    return paths.union(pdfs)

def gather_files(doc_dir: Path, md_dir: Path):
    files = {}
    for p in sorted(doc_dir.iterdir()):
        if p.name in ('index.html', 'INDEX.md', '_autogen_index.md'):
            continue
        if p.is_file():
            files["./" + p.name] = p
    if md_dir.exists():
        for p in sorted(md_dir.iterdir()):
            if p.is_file():
                files["./md_outputs/" + p.name] = p
    return files

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--doc', default='Doc')
    ap.add_argument('--md', default='Doc/md_outputs')
    ap.add_argument('--index', default='Doc/index.html')
    args = ap.parse_args()

    doc_dir = Path(args.doc)
    md_dir = Path(args.md)
    index_path = Path(args.index)
    if not index_path.exists():
        print("Index file not found:", index_path, file=sys.stderr)
        sys.exit(1)

    referenced = parse_index(index_path)
    files = gather_files(doc_dir, md_dir)

    unreferenced = []
    for rel, path in files.items():
        # skip dotfiles and temporary editor files
        if path.name.startswith('.') or path.name.startswith('~$'):
            continue
        if rel not in referenced:
            unreferenced.append((rel, str(path)))

    if not unreferenced:
        print("All files are referenced in index.html")
        return

    print("Unreferenced files:")
    for rel, p in unreferenced:
        print(f" - {rel}  ({p})")

if __name__ == '__main__':
    main()
