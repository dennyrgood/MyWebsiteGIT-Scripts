#!/usr/bin/env python3
"""
convert_and_sync.py

Wrapper helper that:
  1) converts PDFs in Doc/ -> Doc/md_outputs/ using your tools/pdf_to_md_textonly.py
  2) runs the interactive index sync (tools/sync_index_with_fs.py) to add any unreferenced files to Doc/index.html

Usage (from repo root):
  python tools/convert_and_sync.py
  python tools/convert_and_sync.py --doc Doc --md Doc/md_outputs --index Doc/index.html --overwrite-md
  python tools/convert_and_sync.py --yes-to-all   # runs non-interactively where supported

Flags:
  --doc           Doc directory (default: Doc)
  --md            md_outputs directory (default: Doc/md_outputs)
  --index         path to index.html (default: Doc/index.html)
  --converter     path to your pdf_to_md_textonly script (default: tools/pdf_to_md_textonly.py)
  --sync-script   path to the sync script (default: tools/sync_index_with_fs.py)
  --overwrite-md  pass overwrite to converter (replace existing md)
  --yes-to-all    pass --yes-to-all to the sync script when supported
"""
from __future__ import annotations
import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run_converter(converter_path: str, doc_dir: str, md_dir: str, overwrite: bool):
    from pathlib import Path
    import subprocess
    import sys

    # expand ~ and resolve
    converter = Path(converter_path).expanduser()
    try:
        converter = converter.resolve()
    except Exception:
        # resolve() can fail on broken symlinks; keep expanded path
        pass

    if not converter.exists():
        print(f"Converter not found: {converter} (expanded from '{converter_path}')")
        return False

    # build command (adjust flags if your converter uses different names)
    cmd = [sys.executable, str(converter), str(doc_dir), "--out-dir", str(md_dir)]
    if overwrite:
        cmd.append("--overwrite")
    print("Running converter:", " ".join(cmd))
    proc = subprocess.run(cmd)
    return proc.returncode == 0

def run_sync(sync_script: Path, doc_dir: Path, md_dir: Path, index_path: Path, yes_to_all: bool):
    if not sync_script.exists():
        print(f"Sync script not found: {sync_script}")
        return False
    cmd = [sys.executable, str(sync_script), "--doc", str(doc_dir), "--md", str(md_dir), "--index", str(index_path)]
    if yes_to_all:
        cmd.append("--yes-to-all")
    print("Running sync:", " ".join(cmd))
    proc = subprocess.run(cmd)
    return proc.returncode == 0

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--doc", default="Doc")
    p.add_argument("--md", default="Doc/md_outputs")
    p.add_argument("--index", default="Doc/index.html")
    p.add_argument("--converter", default="/Users/dennishmathes/Documents/MyWebsiteGIT/Scripts/tools_pdf_to_md_textonly.py")
    p.add_argument("--sync-script", default="/Users/dennishmathes/Documents/MyWebsiteGIT/Scripts/tools_sync_index_with_fs.py")
    p.add_argument("--overwrite-md", action="store_true")
    p.add_argument("--yes-to-all", action="store_true")
    args = p.parse_args()

    doc_dir = Path(args.doc)
    md_dir = Path(args.md)
    index_path = Path(args.index)
    converter = Path(args.converter)
    sync_script = Path(args.sync_script)

    if not doc_dir.exists():
        print("Doc directory not found:", doc_dir)
        sys.exit(2)
    md_dir.mkdir(parents=True, exist_ok=True)

    ok = run_converter(converter, doc_dir, md_dir, overwrite=args.overwrite_md)
    if not ok:
        print("PDF -> MD conversion failed or converter returned non-zero. Aborting sync.")
        sys.exit(3)

    ok = run_sync(sync_script, doc_dir, md_dir, index_path, yes_to_all=args.yes_to_all)
    if not ok:
        print("Sync script returned non-zero. Check output.")
        sys.exit(4)

    print("Done: PDFs converted and index sync completed.")

if __name__ == "__main__":
    main()
