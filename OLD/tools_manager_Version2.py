#!/usr/bin/env python3
"""
tools_manager.py

Single CLI entrypoint providing subcommands to manage Doc/ and Doc/index.html:

Subcommands:
  - convert          Convert PDFs -> Markdown (prefers existing tools_pdf_to_md_textonly.py)
  - connect          Connect md_outputs/*.md to existing PDF entries in index.html
  - sync             Run interactive sync (prefers existing tools_sync_index_with_fs_orig.py)
  - merge            Merge duplicate categories in index.html
  - reassign         Interactive reassign of entries between categories (prefers existing reassign script if present)
  - list-unreferenced  List files on disk not referenced in index.html

Design:
 - Prefers to run your existing per-file scripts (if found) using runpy.run_path in-process
   to avoid macOS fork/exec Resource temporarily unavailable issues.
 - Where the external script is missing, provides built-in fallback for connect, merge, list-unreferenced.
 - All write operations create a timestamped backup of Doc/index.html before writing.
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import runpy
import subprocess
import shutil
import re
import html
from datetime import datetime
import traceback

# ---------- Utilities ----------
def expand_path(p: str) -> Path:
    return Path(p).expanduser()

def run_script_in_process(script_path: Path, argv: list[str]) -> int:
    script_path = script_path.resolve()
    this_path = Path(__file__).resolve()
    if script_path == this_path:
        print(f"Refusing to execute the manager itself: {script_path}")
        return 2
    if not script_path.exists():
        print(f"Script not found: {script_path}")
        return 2
    old_argv = sys.argv[:]
    try:
        sys.argv = [str(script_path)] + list(argv)
        runpy.run_path(str(script_path), run_name="__main__")
        return 0
    except SystemExit as se:
        code = se.code
        try:
            return int(code) if code is not None else 0
        except Exception:
            return 1
    except Exception:
        print(f"Error while running {script_path} in-process:")
        traceback.print_exc()
        return 1
    finally:
        sys.argv = old_argv

def backup(path: Path) -> Path:
    bak = path.parent / f"{path.name}.bak.{datetime.utcnow().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(path, bak)
    return bak

# ---------- Built-in fallback implementations (used if external scripts are missing) ----------
def list_unreferenced_impl(doc_dir: Path, md_dir: Path, index_path: Path):
    txt = index_path.read_text(encoding='utf-8', errors='replace')
    referenced = set(re.findall(r'data-path="([^"]+)"', txt))
    referenced.update(re.findall(r'data-pdf="([^"]*)"', txt))
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
    unref = []
    for rel, p in files.items():
        if p.name.startswith('.') or p.name.startswith('~$'):
            continue
        if rel not in referenced:
            unref.append((rel, str(p)))
    if not unref:
        print("All files are referenced in index.html")
        return 0
    print("Unreferenced files:")
    for rel, p in unref:
        print(f" - {rel}  ({p})")
    return 0

# connect implementation (from earlier helper) - will insert MD entries next to PDF entries
def connect_impl(doc_dir: Path, md_dir: Path, index_path: Path, dry_run: bool):
    # reuse the previous logic but simplified
    index_text = index_path.read_text(encoding='utf-8', errors='replace')
    # find categories
    section_pat = re.compile(r'(<section\s+class="category"[^>]*?>\s*<h2>(?P<cat>.*?)</h2>.*?<ul\s+class="files"[^>]*?>)', re.S | re.I)
    ul_close_re = re.compile(r'</ul\s*>', re.I)
    li_re = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
    tags_re = re.compile(r'<div\s+class="tags[^>]*>(.*?)</div>', re.S | re.I)
    title_re = re.compile(r'<div\s+class="title">.*?<a[^>]*>(.*?)</a>', re.S | re.I)

    categories = []
    for m in section_pat.finditer(index_text):
        cat = html.unescape(m.group('cat').strip())
        ul_open_end = m.end(1)
        ul_close_m = ul_close_re.search(index_text[ul_open_end:])
        if not ul_close_m:
            continue
        ul_close_idx = ul_open_end + ul_close_m.start()
        categories.append({'name': cat, 'ul_open': ul_open_end, 'ul_close': ul_close_idx})

    if not categories:
        print("No categories found; aborting connect.")
        return 1

    md_files = sorted([p for p in md_dir.iterdir() if p.is_file() and p.suffix.lower()=='.md']) if md_dir.exists() else []
    if not md_files:
        print("No md files found; nothing to connect.")
        return 0

    modified = index_text
    planned = []
    for mdf in md_files:
        if mdf.name.startswith('~$') or mdf.name.startswith('.'):
            continue
        md_rel = f'./md_outputs/{mdf.name}'
        if md_rel in index_text:
            continue
        stem = mdf.stem
        pdf_candidate = doc_dir / (stem + '.pdf')
        pdf_rel = None
        if pdf_candidate.exists():
            pdf_rel = f'./{pdf_candidate.name}'
        else:
            # search index for pdf with same stem
            for m in re.finditer(r'data-pdf="([^"]*\.pdf)"', index_text, re.I):
                val = m.group(1)
                if Path(val).stem == stem:
                    pdf_rel = val
                    break
            for m in re.finditer(r'data-path="([^"]*\.pdf)"', index_text, re.I):
                val = m.group(1)
                if Path(val).stem == stem:
                    pdf_rel = val
                    break
        if not pdf_rel:
            continue
        # find li that references pdf_rel
        found_cat = None
        found_li = None
        for cat in categories:
            span = modified[cat['ul_open']:cat['ul_close']]
            for li in li_re.findall(span):
                if (f'data-pdf="{pdf_rel}"' in li) or (f'data-path="{pdf_rel}"' in li):
                    found_cat = cat
                    found_li = li
                    break
            if found_li:
                break
        if not found_cat:
            continue
        # build li
        existing_tags = ""
        existing_title = mdf.stem
        if found_li:
            mt = title_re.search(found_li)
            if mt:
                existing_title = re.sub(r'\s+', ' ', mt.group(1).strip()) or existing_title
            mt2 = tags_re.search(found_li)
            if mt2:
                existing_tags = ' '.join(mt2.group(1).strip().split())
        li_html = f"""
            <li class="file" data-path="{html.escape(md_rel)}" data-pdf="{html.escape(pdf_rel)}">
              <div class="meta">
                <div class="title"><a href="#" class="file-link">{html.escape(existing_title)}</a></div>
                <div class="desc"></div>
                <div class="tags small-muted">{html.escape(existing_tags)}</div>
              </div>
            </li>
"""
        # ensure not already present in found_cat span
        cat_span = modified[found_cat['ul_open']:found_cat['ul_close']]
        if md_rel in cat_span:
            continue
        insert_pos = found_cat['ul_close']
        modified = modified[:insert_pos] + li_html + modified[insert_pos:]
        # update category indices
        delta = len(li_html)
        for c in categories:
            if c['ul_close'] >= insert_pos:
                c['ul_close'] += delta
                c['ul_open'] += delta
        planned.append((md_rel, pdf_rel, found_cat['name']))

    if not planned:
        print("No MDs needed connection to existing PDFs.")
        return 0

    print("Planned inserts:")
    for md_rel, pdf_rel, cat in planned:
        print(f" - {md_rel} -> {pdf_rel} (category: {cat})")

    if dry_run:
        print("Dry-run: nothing written.")
        return 0

    bak = backup(index_path)
    index_path.write_text(modified, encoding='utf-8')
    print(f"Wrote updated index (backup at {bak})")
    return 0

# merge implementation: merge duplicate categories by normalized title, append li blocks
def merge_impl(index_path: Path, dry_run: bool):
    txt = index_path.read_text(encoding='utf-8', errors='replace')
    section_re = re.compile(r'(<section\s+class="category"[^>]*>.*?</section>)', re.S | re.I)
    h2_re = re.compile(r'<h2>(.*?)</h2>', re.S | re.I)
    ul_re = re.compile(r'(<ul\s+class="files"[^>]*>)(.*?)(</ul>)', re.S | re.I)
    li_re = re.compile(r'(<li\s+class="file"[\s\S]*?</li>)', re.I)
    data_path_re = re.compile(r'data-path="([^"]+)"', re.I)

    sections = []
    for m in section_re.finditer(txt):
        block = m.group(1)
        start = m.start(1)
        end = m.end(1)
        title_m = h2_re.search(block)
        title = title_m.group(1).strip() if title_m else ""
        ul_m = ul_re.search(block)
        inner = ul_m.group(2) if ul_m else ""
        lis = li_re.findall(inner) if ul_m else []
        sections.append({'title': title, 'full': block, 'start': start, 'end': end, 'lis': lis})

    groups = {}
    for s in sections:
        key = ' '.join(s['title'].strip().lower().split())
        groups.setdefault(key, []).append(s)

    dup_keys = [k for k, v in groups.items() if len(v) > 1]
    if not dup_keys:
        print("No duplicate categories found.")
        return 0

    new_txt = txt
    edits = []
    for key in dup_keys:
        group = groups[key]
        primary = group[0]
        others = group[1:]
        existing_paths = set()
        for li in primary['lis']:
            m = data_path_re.search(li)
            if m:
                existing_paths.add(m.group(1))
        to_append = []
        for sec in others:
            for li in sec['lis']:
                m = data_path_re.search(li)
                path = m.group(1) if m else None
                if path and path in existing_paths:
                    continue
                to_append.append(li)
                if path:
                    existing_paths.add(path)
        if to_append:
            new_primary = re.sub(ul_re, lambda m: m.group(1) + m.group(2) + ''.join(to_append) + m.group(3), primary['full'], count=1)
            edits.append(('replace', primary['start'], primary['end'], primary['full'], new_primary))
        for sec in others:
            edits.append(('remove', sec['start'], sec['end'], sec['full'], None))

    # apply edits from end->start
    edits_sorted = sorted(edits, key=lambda e: e[1], reverse=True)
    for typ, sidx, eidx, old, new in edits_sorted:
        snippet = new_txt[sidx:eidx]
        if snippet != old:
            found_at = new_txt.find(old)
            if found_at == -1:
                print(f"Warning: expected snippet not found for edit at {sidx}:{eidx}; skipping.")
                continue
            sidx = found_at
            eidx = found_at + len(old)
        if typ == 'replace':
            new_txt = new_txt[:sidx] + new + new_txt[eidx:]
        else:
            new_txt = new_txt[:sidx] + new_txt[eidx:]

    print(f"Merged keys: {', '.join(dup_keys)}")
    if dry_run:
        print("Dry-run: no file written.")
        return 0

    bak = backup(index_path)
    index_path.write_text(new_txt, encoding='utf-8')
    print(f"Wrote merged index to {index_path} (backup at {bak})")
    return 0

# reassign implementation: if external reassign script exists, use it. Otherwise run built-in interactive routine.
def reassign_impl(index_path: Path):
    # Prefer external script
    external = index_path.parent.parent / "Scripts" / "tools_reassign_index_entries_Version2.py"
    # Also check same folder as this script
    alt = Path(__file__).parent / "tools_reassign_index_entries_Version2.py"
    for candidate in (external, alt):
        if candidate.exists():
            print(f"Running external reassign script in-process: {candidate}")
            return run_script_in_process(candidate, ["--index", str(index_path)])
    # Fallback: instruct user to run their reassign script
    print("No external reassign script found. Please run your reassign tool:")
    print("  python3 ../Scripts/tools_reassign_index_entries_Version2.py --index Doc/index.html")
    return 2

# convert implementation: call external converter if present; otherwise attempt a minimal fitz-based convert for PDFs
def convert_impl(doc_dir: Path, md_dir: Path, overwrite: bool):
    external = Path(__file__).parent / "tools_pdf_to_md_textonly.py"
    ext2 = Path(__file__).parent.parent / "Scripts" / "tools_pdf_to_md_textonly.py"
    for candidate in (external, ext2):
        if candidate.exists():
            print(f"Running external converter in-process: {candidate}")
            argv = [str(doc_dir), "--out-dir", str(md_dir)]
            if overwrite:
                argv.append("--overwrite")
            return run_script_in_process(candidate, argv)
    # fallback to PyMuPDF if available
    try:
        import fitz
    except Exception:
        print("No external converter found and PyMuPDF not available. Install pymupdf or provide tools_pdf_to_md_textonly.py")
        return 2
    md_dir.mkdir(parents=True, exist_ok=True)
    pdfs = sorted(doc_dir.glob("*.pdf"))
    if not pdfs:
        print("No PDFs to convert in", doc_dir)
        return 0
    for pdf in pdfs:
        target = md_dir / (pdf.stem + ".md")
        if target.exists() and not overwrite:
            print("Skipping existing:", target)
            continue
        doc = fitz.open(str(pdf))
        pages = []
        for page in doc:
            pages.append(page.get_text("text"))
        content = "\n\n---\n\n".join(pages).strip()
        header = f"# {pdf.stem}\n\nSource PDF: [{pdf.name}]({pdf.name})\n\n---\n\n"
        target.write_text(header + content + "\n", encoding='utf-8')
        print("Wrote:", target)
    return 0

# ---------- CLI wiring ----------
def main():
    p = argparse.ArgumentParser(prog="tools_manager.py", description="Combined CLI for Doc/index.html helpers")
    sub = p.add_subparsers(dest="cmd")

    # convert
    sp = sub.add_parser("convert", help="Convert PDFs to Markdown (uses existing converter if present)")
    sp.add_argument("--doc", default="Doc")
    sp.add_argument("--md", default="Doc/md_outputs")
    sp.add_argument("--overwrite", action="store_true")

    # connect
    sp = sub.add_parser("connect", help="Connect md_outputs/*.md to existing PDF entries in index.html")
    sp.add_argument("--doc", default="Doc")
    sp.add_argument("--md", default="Doc/md_outputs")
    sp.add_argument("--index", default="Doc/index.html")
    sp.add_argument("--dry-run", action="store_true")

    # sync
    sp = sub.add_parser("sync", help="Run interactive sync (prefers existing sync script)")
    sp.add_argument("--doc", default="Doc")
    sp.add_argument("--md", default="Doc/md_outputs")
    sp.add_argument("--index", default="Doc/index.html")
    sp.add_argument("--convert-pdfs", action="store_true", help="Run converter before sync")
    sp.add_argument("--overwrite-md", action="store_true")
    sp.add_argument("--yes-to-all", action="store_true")

    # merge
    sp = sub.add_parser("merge", help="Merge duplicate categories in index.html")
    sp.add_argument("--index", default="Doc/index.html")
    sp.add_argument("--dry-run", action="store_true")

    # reassign
    sp = sub.add_parser("reassign", help="Interactive reassign of entries between categories")
    sp.add_argument("--index", default="Doc/index.html")

    # list-unreferenced
    sp = sub.add_parser("list-unreferenced", help="List files on disk not referenced in index.html")
    sp.add_argument("--doc", default="Doc")
    sp.add_argument("--md", default="Doc/md_outputs")
    sp.add_argument("--index", default="Doc/index.html")

    args = p.parse_args()

    if args.cmd is None:
        p.print_help()
        sys.exit(0)

    # dispatch
    if args.cmd == "convert":
        doc_dir = expand_path(args.doc)
        md_dir = expand_path(args.md)
        sys.exit(convert_impl(doc_dir, md_dir, args.overwrite))

    if args.cmd == "connect":
        doc_dir = expand_path(args.doc)
        md_dir = expand_path(args.md)
        index_path = expand_path(args.index)
        if not index_path.exists():
            print("Index not found:", index_path); sys.exit(1)
        sys.exit(connect_impl(doc_dir, md_dir, index_path, args.dry_run))

    if args.cmd == "sync":
        # prefer existing sync script locations
        sync_candidates = [
            Path(__file__).parent / "tools_sync_index_with_fs_orig.py",
            Path(__file__).parent.parent / "Scripts" / "tools_sync_index_with_fs_orig.py",
            Path(__file__).parent / "tools_sync_index_with_fs.py",
            Path(__file__).parent.parent / "Scripts" / "tools_sync_index_with_fs.py",
        ]
        if args.convert_pdfs:
            # run converter first
            ret = convert_impl(expand_path(args.doc), expand_path(args.md), args.overwrite_md)
            if ret != 0:
                print("Converter returned non-zero; continuing to sync with existing files.")
        for cand in sync_candidates:
            if cand.exists():
                rc = run_script_in_process(cand, ["--doc", args.doc, "--md", args.md, "--index", args.index] + (["--yes-to-all"] if args.yes_to_all else []))
                sys.exit(rc)
        print("No sync implementation found in expected locations. Please run your sync script manually.")
        sys.exit(2)

    if args.cmd == "merge":
        index_path = expand_path(args.index)
        if not index_path.exists():
            print("Index not found:", index_path); sys.exit(1)
        sys.exit(merge_impl(index_path, args.dry_run))

    if args.cmd == "reassign":
        index_path = expand_path(args.index)
        if not index_path.exists():
            print("Index not found:", index_path); sys.exit(1)
        sys.exit(reassign_impl(index_path))

    if args.cmd == "list-unreferenced":
        doc_dir = expand_path(args.doc)
        md_dir = expand_path(args.md)
        index_path = expand_path(args.index)
        if not index_path.exists():
            print("Index not found:", index_path); sys.exit(1)
        sys.exit(list_unreferenced_impl(doc_dir, md_dir, index_path))

if __name__ == "__main__":
    main()