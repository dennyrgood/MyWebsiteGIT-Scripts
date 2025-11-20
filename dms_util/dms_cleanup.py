#!/usr/bin/env python3
"""
dms_cleanup.py - Remove deleted files from index.html

Finds files that are in DMS_STATE but no longer exist in Doc/,
and removes them from both the HTML display and the state.

Usage:
  python3 dms_cleanup.py --doc Doc/ --index Doc/index.html
"""
import argparse
import json
import re
import shutil
from pathlib import Path
from datetime import datetime

def cleanup_deleted_files(doc_dir: Path, index_path: Path):
    """Remove index entries for files that no longer exist in Doc/."""
    
    # Get list of actual files in Doc/
    doc_files = set()
    for item in doc_dir.rglob('*'):
        if item.is_file():
            # Store relative path
            rel_path = './' + str(item.relative_to(doc_dir))
            doc_files.add(rel_path)
    
    # Extract DMS_STATE
    content = index_path.read_text(encoding='utf-8')
    state_match = re.search(r'<!-- DMS_STATE\n(.*?)\n-->', content, re.DOTALL)
    if not state_match:
        print("ERROR: DMS_STATE not found")
        return 1
    
    state_text = state_match.group(1).strip()
    state = json.loads(state_text)
    state_files = set(state.get('processed_files', {}).keys())
    
    # Find deleted files: in STATE but not in Doc/
    deleted_files = state_files - doc_files
    
    if not deleted_files:
        print("✓ No deleted files found. Index is in sync with Doc/.")
        return 0
    
    print(f"Found {len(deleted_files)} file(s) that no longer exist in Doc/:")
    
    # Remove from state
    removed = 0
    for file_path in sorted(deleted_files):
        if file_path in state['processed_files']:
            del state['processed_files'][file_path]
            removed += 1
            print(f"  - {file_path}")
    
    # Remove from HTML display (remove <li> entries with data-path)
    updated = content
    for file_path in deleted_files:
        escaped = re.escape(file_path)
        pattern = rf'<li\s+class="file"[^>]*data-path="{escaped}"[^>]*>.*?</li>'
        updated = re.sub(pattern, '', updated, flags=re.DOTALL)
    
    # Remove empty category sections
    pattern = r'<section\s+class="category"[^>]*>.*?<ul\s+class="files"[^>]*>\s*</ul>\s*</section>'
    while re.search(pattern, updated, re.DOTALL | re.IGNORECASE):
        updated = re.sub(pattern, '', updated, count=1, flags=re.DOTALL | re.IGNORECASE)
    
    # Update DMS_STATE
    new_state_json = json.dumps(state, indent=2)
    old_state_block = state_match.group(0)
    new_state_block = f"<!-- DMS_STATE\n{new_state_json}\n-->"
    updated = updated.replace(old_state_block, new_state_block)
    
    # Backup and save
    backup = index_path.parent / f"{index_path.name}.bak.cleanup.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, backup)
    index_path.write_text(updated, encoding='utf-8')
    
    print(f"\n✓ Removed {removed} deleted file(s) from index.html")
    print(f"Backup: {backup}")
    
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Remove deleted files from index.html"
    )
    parser.add_argument("--doc", default="Doc", help="Path to Doc directory (default: Doc)")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html (default: Doc/index.html)")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    index_path = Path(args.index)
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    if not index_path.exists():
        print(f"ERROR: {index_path} not found")
        return 1
    
    return cleanup_deleted_files(doc_dir, index_path)


if __name__ == "__main__":
    exit(main())
