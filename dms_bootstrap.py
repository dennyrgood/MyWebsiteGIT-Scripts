#!/usr/bin/env python3
"""
DMS_bootstrap.py - Bootstrap DMS_STATE from existing index.html

Parses an existing index.html that was created manually or by old tools,
computes file hashes for all referenced files, and injects a DMS_STATE
comment block so the system knows which files are already processed.

Usage:
  python DMS_bootstrap.py --index Doc/index.html --doc Doc
"""
from __future__ import annotations
import argparse
import sys
import json
import hashlib
import re
import shutil
from pathlib import Path
from datetime import datetime

def compute_file_hash(path: Path) -> str:
    """Compute SHA-256 hash of file contents"""
    if not path.exists():
        return "sha256:missing"
    try:
        sha = hashlib.sha256()
        with path.open('rb') as f:
            while chunk := f.read(8192):
                sha.update(chunk)
        return f"sha256:{sha.hexdigest()}"
    except Exception as e:
        return f"sha256:error-{e}"

def extract_existing_entries(index_path: Path) -> list[dict]:
    """Parse all <li class="file"> entries from index.html"""
    content = index_path.read_text(encoding='utf-8', errors='replace')
    
    # Match: <li class="file" data-path="..." data-pdf="...">
    li_pattern = re.compile(
        r'<li\s+class="file"\s+data-path="([^"]+)"\s+data-pdf="([^"]*)"[^>]*>(.*?)</li>',
        re.DOTALL | re.IGNORECASE
    )
    
    entries = []
    for match in li_pattern.finditer(content):
        data_path = match.group(1)
        data_pdf = match.group(2)
        li_content = match.group(3)
        
        # Extract title
        title_match = re.search(r'<div\s+class="title">.*?<a[^>]*>([^<]+)</a>', li_content, re.DOTALL)
        title = title_match.group(1).strip() if title_match else Path(data_path).name
        
        # Extract description
        desc_match = re.search(r'<div\s+class="desc">([^<]*)</div>', li_content, re.DOTALL)
        desc = desc_match.group(1).strip() if desc_match else ""
        
        entries.append({
            'data_path': data_path,
            'data_pdf': data_pdf,
            'title': title,
            'desc': desc
        })
    
    return entries

def build_dms_state(entries: list[dict], doc_dir: Path) -> dict:
    """Build DMS_STATE dict from existing entries"""
    processed_files = {}
    
    for entry in entries:
        rel_path = entry['data_path']
        
        # Resolve absolute path
        if rel_path.startswith('./'):
            abs_path = doc_dir / rel_path[2:]
        else:
            abs_path = doc_dir / rel_path
        
        # Compute hash
        file_hash = compute_file_hash(abs_path)
        
        processed_files[rel_path] = {
            "hash": file_hash,
            "last_processed": datetime.now().isoformat(),
            "summary_approved": True,  # Assume existing summaries are approved
            "title": entry['title'],
            "description": entry['desc']
        }
        
        # Also track data-pdf if different
        if entry['data_pdf'] and entry['data_pdf'] != rel_path:
            pdf_path = entry['data_pdf']
            if pdf_path.startswith('./'):
                pdf_abs = doc_dir / pdf_path[2:]
            else:
                pdf_abs = doc_dir / pdf_path
            
            if pdf_abs.exists() and pdf_path not in processed_files:
                processed_files[pdf_path] = {
                    "hash": compute_file_hash(pdf_abs),
                    "last_processed": datetime.now().isoformat(),
                    "summary_approved": True,
                    "title": entry['title'],
                    "description": ""
                }
    
    # Extract categories from index
    content = doc_dir.parent / "Doc" / "index.html"
    if (doc_dir / "index.html").exists():
        content = (doc_dir / "index.html").read_text(encoding='utf-8', errors='replace')
        cat_pattern = re.compile(r'data-category="([^"]+)"', re.IGNORECASE)
        categories = list(set(cat_pattern.findall(content)))
    else:
        categories = []
    
    return {
        "processed_files": processed_files,
        "categories": categories,
        "last_scan": datetime.now().isoformat(),
        "bootstrap_version": "1.0"
    }

def inject_dms_state(index_path: Path, state: dict) -> None:
    """Inject DMS_STATE comment into index.html"""
    content = index_path.read_text(encoding='utf-8', errors='replace')
    
    # Check if DMS_STATE already exists
    if '<!-- DMS_STATE' in content:
        print("WARNING: DMS_STATE already exists in index.html", file=sys.stderr)
        choice = input("Overwrite existing state? [y/N]: ").strip().lower()
        if choice != 'y':
            print("Aborted.")
            return
        
        # Remove old state
        pattern = re.compile(r'<!-- DMS_STATE\n.*?\n-->', re.DOTALL)
        content = pattern.sub('', content)
    
    # Create state comment block
    state_json = json.dumps(state, indent=2)
    state_block = f"<!-- DMS_STATE\n{state_json}\n-->\n"
    
    # Insert right after <body> tag
    body_pos = content.find('<body>')
    if body_pos == -1:
        print("ERROR: Cannot find <body> tag in index.html", file=sys.stderr)
        return
    
    insert_pos = content.find('>', body_pos) + 1
    new_content = content[:insert_pos] + '\n' + state_block + content[insert_pos:]
    
    # Backup original
    backup_path = index_path.parent / f"{index_path.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, backup_path)
    print(f"Backed up original to: {backup_path}")
    
    # Write new content
    index_path.write_text(new_content, encoding='utf-8')
    print(f"✓ Injected DMS_STATE into {index_path}")

def main():
    parser = argparse.ArgumentParser(description="Bootstrap DMS_STATE from existing index.html")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--dry-run", action="store_true", help="Show state without writing")
    args = parser.parse_args()
    
    index_path = Path(args.index)
    doc_dir = Path(args.doc)
    
    if not index_path.exists():
        print(f"ERROR: index.html not found: {index_path}", file=sys.stderr)
        return 1
    
    if not doc_dir.exists():
        print(f"ERROR: Doc directory not found: {doc_dir}", file=sys.stderr)
        return 1
    
    print("Bootstrapping DMS_STATE from existing index.html...\n")
    
    # Parse existing entries
    entries = extract_existing_entries(index_path)
    print(f"Found {len(entries)} file entries in index.html")
    
    # Build state
    state = build_dms_state(entries, doc_dir)
    print(f"Processed {len(state['processed_files'])} unique files")
    print(f"Found {len(state['categories'])} categories")
    
    if args.dry_run:
        print("\nDry-run: DMS_STATE preview:")
        print(json.dumps(state, indent=2)[:1000] + "\n... (truncated)")
        return 0
    
    print("\nThis will inject DMS_STATE into your index.html.")
    print("A backup will be created before modification.")
    confirm = input("\nProceed? [y/N]: ").strip().lower()
    
    if confirm != 'y':
        print("Aborted.")
        return 0
    
    inject_dms_state(index_path, state)
    
    print("\n" + "="*60)
    print("Bootstrap complete!")
    print("="*60)
    print("\nYou can now run:")
    print("  dms scan       # Should show 0 new files")
    print("  dms status     # Check current state")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
