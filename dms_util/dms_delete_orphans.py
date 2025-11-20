#!/usr/bin/env python3
"""
dms_delete_orphans.py - Delete orphaned entries from DMS_STATE

Removes files from DMS_STATE that are in the state but not displayed in the HTML.
These are "orphans" - they have no user-visible entry in the left panel.

Usage:
  python3 dms_delete_orphans.py --index Doc/index.html
"""
import argparse
import json
import re
import shutil
from pathlib import Path
from datetime import datetime

def delete_orphans(index_path: Path):
    """Remove orphaned files from DMS_STATE (files in state but not in HTML display)."""
    content = index_path.read_text(encoding='utf-8')
    
    # Extract DMS_STATE
    state_match = re.search(r'<!-- DMS_STATE\n(.*?)\n-->', content, re.DOTALL)
    if not state_match:
        print("ERROR: DMS_STATE not found")
        return 1
    
    state_text = state_match.group(1).strip()
    state = json.loads(state_text)
    state_files = set(state.get('processed_files', {}).keys())
    
    # Get files displayed in HTML
    html_files = set(re.findall(r'data-path="([^"]+)"', content))
    
    # Find orphans: in STATE but not in HTML
    orphans = state_files - html_files
    
    if not orphans:
        print("✓ No orphans found.")
        return 0
    
    print(f"Deleting {len(orphans)} orphan(s) from DMS_STATE:")
    
    # Remove each orphan from state
    removed = 0
    for path in sorted(orphans):
        if path in state['processed_files']:
            del state['processed_files'][path]
            removed += 1
            print(f"  - {path}")
    
    # Update the DMS_STATE comment in HTML
    updated = content
    new_state_json = json.dumps(state, indent=2)
    old_state_block = state_match.group(0)
    new_state_block = f"<!-- DMS_STATE\n{new_state_json}\n-->"
    updated = updated.replace(old_state_block, new_state_block)
    
    # Backup and save
    if removed > 0:
        backup = index_path.parent / f"{index_path.name}.bak.delete.{datetime.now().strftime('%Y%m%d%H%M%S')}"
        shutil.copy2(index_path, backup)
        index_path.write_text(updated, encoding='utf-8')
        print(f"\n✓ Deleted {removed} orphan(s) from DMS_STATE. Backup: {backup}")
    
    return 0

def main():
    parser = argparse.ArgumentParser(description="Delete orphaned entries from index.html")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    args = parser.parse_args()
    
    index_path = Path(args.index)
    if not index_path.exists():
        print(f"ERROR: {index_path} not found")
        return 1
    
    return delete_orphans(index_path)

if __name__ == "__main__":
    exit(main())
