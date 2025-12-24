#!/usr/bin/env python3
"""
dms_apply.py - Apply approved changes to .dms_state.json and regenerate index.html

Reads approved summaries and updates the state file.
Then calls dms_render.py to regenerate index.html from the new state.

No direct HTML manipulation - just JSON updates + rendering.
"""
import argparse
import sys
import json
import subprocess
from pathlib import Path
from datetime import datetime

def get_file_mtime_iso(path: Path) -> str:
    """Get file modification time in ISO 8601 format"""
    mtime = path.stat().st_mtime
    return datetime.fromtimestamp(mtime).isoformat()

def load_state(state_path: Path) -> dict:
    """Load .dms_state.json"""
    if not state_path.exists():
        return {
            "metadata": {"last_scan": None, "last_apply": None},
            "categories": [],
            "documents": {}
        }
    
    return json.loads(state_path.read_text(encoding='utf-8'))

def load_approved(pending_path: Path) -> dict:
    """Load approved summaries from .dms_pending_approved.json"""
    if not pending_path.exists():
        return {"summaries": []}
    
    return json.loads(pending_path.read_text(encoding='utf-8'))

def apply_changes(state_path: Path, pending_path: Path, scripts_dir: Path) -> int:
    """Apply approved summaries to state and render"""
    
    print("==> Applying approved changes to .dms_state.json...\n")
    
    # Get doc_dir from state_path
    doc_dir = state_path.parent
    
    # Load current state
    state = load_state(state_path)
    
    # Load approved summaries
    approved_data = load_approved(pending_path)
    approved = approved_data.get("summaries", [])
    
    if not approved:
        print("No approved summaries found.")
        return 0
    
    print(f"Applying {len(approved)} approved summary/summaries...\n")
    
    # Group by category for reporting
    by_category = {}
    
    # Apply each approval
    for summary_info in approved:
        file_path = summary_info['file']['path']
        category = summary_info.get('category', 'Junk')
        
        # Track category
        by_category[category] = by_category.get(category, 0) + 1
        
        # Update state
        doc_entry = {
            'hash': summary_info['file'].get('hash', ''),
            'category': category,
            'summary': summary_info.get('summary', ''),
            'summary_approved': True,
            'title': summary_info.get('title', Path(file_path).stem),
            'last_processed': datetime.now().isoformat()
        }
        
        # Include file modification time if available
        if summary_info['file'].get('file_mtime'):
            doc_entry['file_mtime'] = summary_info['file']['file_mtime']
        else:
            # Try to get mtime from actual file if not in summary
            full_path = doc_dir / file_path.lstrip('./')
            if full_path.exists():
                doc_entry['file_mtime'] = get_file_mtime_iso(full_path)
        
        # Include readable version link if provided
        if summary_info['file'].get('readable_version'):
            doc_entry['readable_version'] = summary_info['file']['readable_version']
        
        state['documents'][file_path] = doc_entry
        
        # Update category list if new
        if category not in state['categories']:
            state['categories'].append(category)
    
    # Report
    print("Applied to categories:")
    for category, count in sorted(by_category.items()):
        print(f"  + {count} file(s) → {category}")
    
    # Update metadata
    state['metadata']['last_apply'] = datetime.now().isoformat()
    
    # Save updated state
    state_path.write_text(json.dumps(state, indent=2), encoding='utf-8')
    print(f"\n✓ Updated {state_path}")
    
    # Now render index.html from the new state
    print(f"\n==> Regenerating index.html from state...\n")
    
    render_script = scripts_dir / "dms_util" / "dms_render.py"
    result = subprocess.run(
        [sys.executable, str(render_script), 
         "--doc", str(state_path.parent)],
        capture_output=False
    )
    
    # Now render index_iphone.html from the new state
    print(f"\n==> Regenerating index_iphone.html from state...\n")
    
    render_script = scripts_dir / "dms_util" / "dms_render_iphone.py"
    result = subprocess.run(
        [sys.executable, str(render_script), 
         "--doc", str(state_path.parent)],
        capture_output=False
    )
    
    if result.returncode != 0:
        print("ERROR: Failed to render index.html", file=sys.stderr)
        return 1
    
    # Clean up pending files after successful apply
    scan_path = doc_dir / ".dms_scan.json"
    
    if pending_path.exists():
        pending_path.unlink()
        print(f"\n✓ Cleaned up {pending_path}")
    
    if scan_path.exists():
        scan_path.unlink()
        print(f"✓ Cleaned up {scan_path}")
    
    print(f"\n✓ Apply complete!")
    print(f"\nUpdated files:")
    print(f"  - .dms_state.json")
    print(f"  - index.html")
    
    # Prompt to continue with scan
    choice = input(f"\nStart 'dms scan' again to check for more changes? [y/N]: ").strip().lower()
    if choice == 'y':
        result = subprocess.run(['dms', 'scan'])
        return result.returncode
    
    return 0

def find_scripts_dir() -> Path:
    """Return the scripts directory (2 levels up from this utility file)"""
    return Path(__file__).parent.parent

def main():
    parser = argparse.ArgumentParser(description="Apply approved changes to index")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--index", default="Doc/index.html", help="Index file (for compatibility, not used)")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    state_path = doc_dir / ".dms_state.json"
    pending_path = doc_dir / ".dms_pending_approved.json"
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    scripts_dir = find_scripts_dir()
    
    return apply_changes(state_path, pending_path, scripts_dir)

if __name__ == "__main__":
    exit(main())
