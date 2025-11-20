#!/usr/bin/env python3
"""
sync_index_with_fs.py (fixed: prevents self-invocation recursion)

Avoids running itself by checking resolved paths; runs converter and runs
the original/fallback sync script in-process using runpy.run_path (no fork/exec).
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import runpy
import traceback

def expand_path(p: str) -> Path:
    return Path(p).expanduser()

def run_script_in_process(script_path: Path, argv: list[str]) -> int:
    """
    Execute the given python script in-process using runpy.run_path.
    Prevent running THIS script (self) to avoid recursion.
    Returns exit code int.
    """
    script_path = script_path.resolve()
    this_path = Path(__file__).resolve()
    if script_path == this_path:
        print(f"Refusing to execute script in-process: it's the same as the caller ({script_path}).")
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

def run_converter(doc_dir: str, md_dir: str, overwrite: bool, converter_path: str):
    conv = expand_path(converter_path)
    if not conv.exists():
        print(f"Converter script not found: {conv} - cannot convert PDFs.")
        return False

    argv = ["--doc", doc_dir, "--out-dir", md_dir]
    if overwrite:
        argv.append("--overwrite")

    print("Running PDF -> MD converter (in-process):", conv, "args:", argv)
    rc = run_script_in_process(conv, argv)
    if rc != 0:
        print(f"Converter returned non-zero exit code: {rc}")
        return False
    return True

def main():
    ap = argparse.ArgumentParser(description="Sync Doc/index.html with filesystem, optionally converting PDFs to MD first")
    ap.add_argument('--doc', default='Doc', help='Doc folder path (default: Doc)')
    ap.add_argument('--md', default='Doc/md_outputs', help='Converted markdown folder (default: Doc/md_outputs)')
    ap.add_argument('--index', default='Doc/index.html', help='Path to interactive index HTML (default: Doc/index.html)')
    ap.add_argument('--convert-pdfs', action='store_true', help='Run PDF->MD converter before scanning')
    ap.add_argument('--overwrite-md', action='store_true', help='When converting, overwrite existing md files')
    ap.add_argument('--yes-to-all', action='store_true', help='Accept defaults non-interactively')
    ap.add_argument('--converter', default="~/Documents/MywebsiteGIT/Scripts/tools_pdf_to_md_textonly.py", help='Path to converter script (optional)')
    ap.add_argument('--orig-script', default="~/Documents/MyWebsiteGIT/Scripts/tools_sync_index_with_fs_orig.py", help='Path to original sync implementation (optional)')
    ap.add_argument('--fallback-script', default="~/Documents/MyWebsiteGIT/Scripts/tools_sync_index_with_fs_fallback.py", help='Path to fallback sync implementation (optional)')
    args = ap.parse_args()

    doc = args.doc
    md = args.md
    index = args.index

    if args.convert_pdfs:
        conv_path = args.converter
        conv_path_expanded = expand_path(conv_path)
        if not conv_path_expanded.exists():
            print(f"Converter not found at {conv_path_expanded} (expanded). Please pass --converter with the correct path.")
            ok = False
        else:
            ok = run_converter(doc, md, overwrite=args.overwrite_md, converter_path=conv_path)
        if not ok:
            print("PDF conversion failed or was skipped. Continuing to sync with existing files.")

    # run orig script if provided and not self
    orig = expand_path(args.orig_script)
    if orig.exists():
        print("Executing orig sync script in-process:", orig)
        rc = run_script_in_process(orig, ["--doc", doc, "--md", md, "--index", index] + (["--yes-to-all"] if args.yes_to_all else []))
        sys.exit(rc)

    # run fallback script (note: default fallback was changed to a different filename to avoid self-call)
    fallback = expand_path(args.fallback_script)
    if fallback.exists():
        print("Executing fallback sync script in-process:", fallback)
        rc = run_script_in_process(fallback, ["--doc", doc, "--md", md, "--index", index] + (["--yes-to-all"] if args.yes_to_all else []))
        sys.exit(rc)

    print("No embedded sync implementation found at either:")
    print("  ", orig)
    print("  ", fallback)
    print("Please place the original sync script in one of those paths or pass --orig-script/--fallback-script.")
    sys.exit(1)

if __name__ == '__main__':
    main()
