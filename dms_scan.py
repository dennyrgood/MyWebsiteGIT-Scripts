#!/usr/bin/env python3
"""
DMS_scan.py - Scan Doc/ directory for new or changed files

Compares current filesystem state against DMS_STATE embedded in index.html
Identifies:
  - New files (not in state)
  - Changed files (hash mismatch)
  - Missing files (in state but not on disk)

Outputs a scan report and updates a pending changes JSON for review.
"""
from __future__ import annotations
import argparse
import sys
import json
import hashlib
import re
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple

DMS_STATE_PATTERN = re.compile(r'<!-- DMS_STATE\n(.*?)\n-->', re.DOTALL)

def compute_file_hash(path: Path) -> str:
    """Compute SHA-256 hash of file contents"""
    sha = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(8192):
            sha.update(chunk)
    return f"sha256:{sha.hexdigest()}"

def extract_dms_state(index_path: Path) -> dict:
    """Extract DMS_STATE from index.html"""
    if not index_path.exists():
        return {
            "processed_files": {},
            "categories": [],
            "last_scan": None
        }
    
    content = index_path.read_text(encoding='utf-8', errors='replace')
    match = DMS_STATE_PATTERN.search(content)
    
    if not match:
        # No state yet, initialize
        return {
            "processed_files": {},
            "categories": [],
            "last_scan": None
        }
    
    try:
        state = json.loads(match.group(1))
        return state
    except json.JSONDecodeError as e:
        print(f"WARNING: Corrupted DMS_STATE in index.html: {e}", file=sys.stderr)
        return {
            "processed_files": {},
            "categories": [],
            "last_scan": None
        }

def extract_existing_categories(index_path: Path) -> List[str]:
    """Parse existing category names from index.html"""
    if not index_path.exists():
        return []
    
    content = index_path.read_text(encoding='utf-8', errors='replace')
    # Match: <section class="category" data-category="NAME">
    cat_pattern = re.compile(r'<section\s+class="category"\s+data-category="([^"]+)"', re.I)
    categories = cat_pattern.findall(content)
    
    # Also try <h2> tags inside category sections
    h2_pattern = re.compile(r'<section\s+class="category"[^>]*>.*?<h2>([^<]+)</h2>', re.DOTALL | re.I)
    h2_cats = h2_pattern.findall(content)
    
    all_cats = list(set(categories + h2_cats))
    return [c.strip() for c in all_cats if c.strip()]

def scan_doc_directory(doc_dir: Path, md_dir: Path) -> Dict[str, Path]:
    """Scan Doc/ and Doc/md_outputs/ for files"""
    files = {}
    
    # Scan Doc/ (skip index.html, backups, etc.)
    skip_names = {'index.html', 'INDEX.md', '_autogen_index.md'}
    skip_patterns = ['.bak.', '.DS_Store']
    
    for p in doc_dir.iterdir():
        if not p.is_file():
            continue
        if p.name in skip_names:
            continue
        if any(pat in p.name for pat in skip_patterns):
            continue
        rel = f"./{p.name}"
        files[rel] = p
    
    # Scan Doc/md_outputs/
    if md_dir.exists():
        for p in md_dir.iterdir():
            if not p.is_file():
                continue
            if any(pat in p.name for pat in skip_patterns):
                continue
            rel = f"./md_outputs/{p.name}"
            files[rel] = p
    
    return files

def categorize_changes(
    current_files: Dict[str, Path],
    state: dict
) -> Tuple[List[dict], List[dict], List[str]]:
    """
    Compare current files against state.
    Returns: (new_files, changed_files, missing_files)
    """
    processed = state.get("processed_files", {})
    
    new_files = []
    changed_files = []
    
    for rel_path, abs_path in current_files.items():
        file_hash = compute_file_hash(abs_path)
        
        if rel_path not in processed:
            # New file
            new_files.append({
                "path": rel_path,
                "abs_path": str(abs_path),
                "hash": file_hash,
                "size": abs_path.stat().st_size,
                "ext": abs_path.suffix.lower()
            })
        else:
            # Check if changed
            old_hash = processed[rel_path].get("hash", "")
            if old_hash != file_hash:
                changed_files.append({
                    "path": rel_path,
                    "abs_path": str(abs_path),
                    "hash": file_hash,
                    "old_hash": old_hash,
                    "size": abs_path.stat().st_size,
                    "ext": abs_path.suffix.lower()
                })
    
    # Missing files (in state but not on disk)
    missing = [rel for rel in processed.keys() if rel not in current_files]
    
    return new_files, changed_files, missing

def save_scan_report(doc_dir: Path, new_files: list, changed_files: list, missing_files: list):
    """Save scan results to Doc/.dms_pending.json for next steps"""
    report = {
        "timestamp": datetime.now().isoformat(),
        "new_files": new_files,
        "changed_files": changed_files,
        "missing_files": missing_files,
        "needs_processing": len(new_files) + len(changed_files) > 0
    }
    
    pending_path = doc_dir / ".dms_pending.json"
    pending_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(f"Scan report saved to {pending_path}")

def main():
    parser = argparse.ArgumentParser(description="Scan Doc/ for new or changed files")
    parser.add_argument("--doc", default="Doc", help="Doc directory path")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    parser.add_argument("--status-only", action="store_true", help="Just show status, don't save report")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    md_dir = doc_dir / "md_outputs"
    index_path = Path(args.index)
    
    if not doc_dir.exists():
        print(f"ERROR: Doc directory not found: {doc_dir}", file=sys.stderr)
        return 1
    
    # Extract state
    state = extract_dms_state(index_path)
    categories = extract_existing_categories(index_path)
    
    print(f"DMS State:")
    print(f"  - Processed files: {len(state.get('processed_files', {}))}")
    print(f"  - Last scan: {state.get('last_scan', 'Never')}")
    print(f"  - Categories: {len(categories)} ({', '.join(categories[:5])}{'...' if len(categories) > 5 else ''})")
    print()
    
    # Scan current files
    current_files = scan_doc_directory(doc_dir, md_dir)
    print(f"Current filesystem: {len(current_files)} files in Doc/")
    print()
    
    # Compare
    new_files, changed_files, missing_files = categorize_changes(current_files, state)
    
    # Report
    print("Scan Results:")
    print(f"  - New files: {len(new_files)}")
    print(f"  - Changed files: {len(changed_files)}")
    print(f"  - Missing files: {len(missing_files)}")
    print()
    
    if new_files:
        print("New files:")
        for f in new_files:
            size_kb = f['size'] / 1024
            print(f"  + {f['path']} ({size_kb:.1f} KB, {f['ext']})")
    
    if changed_files:
        print("\nChanged files:")
        for f in changed_files:
            print(f"  ~ {f['path']} (hash changed)")
    
    if missing_files:
        print("\nMissing files (in index but not on disk):")
        for f in missing_files:
            print(f"  - {f}")
    
    if not new_files and not changed_files and not missing_files:
        print("✓ No changes detected. Index is up to date.")
        return 0
    
    if args.status_only:
        return 0
    
    # Save report
    save_scan_report(doc_dir, new_files, changed_files, missing_files)
    
    print()
    print("Next steps:")
    if any(f['ext'] in ['.png', '.jpg', '.jpeg', '.gif'] for f in new_files):
        print("  1. Run 'dms process-images' to convert images to text")
    print("  2. Run 'dms summarize' to generate AI summaries")
    print("  3. Run 'dms review' to approve/edit summaries")
    print("  4. Run 'dms apply' to update index.html")
    print("\nOr use 'dms auto' to run all steps at once.")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
