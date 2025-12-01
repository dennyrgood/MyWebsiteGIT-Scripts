#!/usr/bin/env python3
"""
dms_scan.py - Scan Doc/ directory for new or changed files

Compares current filesystem state against .dms_state.json
Identifies:
  - New files (not in state)
  - Changed files (hash mismatch)
  - Missing files (in state but not on disk)

Outputs a scan report (no state changes - just detection).
"""
import argparse
import sys
import json
import hashlib
import subprocess
from pathlib import Path
from datetime import datetime
from fnmatch import fnmatch

def compute_file_hash(path: Path) -> str:
    """Compute SHA-256 hash of file contents"""
    sha = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(8192):
            sha.update(chunk)
    return f"sha256:{sha.hexdigest()}"

def get_file_mtime_iso(path: Path) -> str:
    """Get file modification time in ISO 8601 format"""
    mtime = path.stat().st_mtime
    return datetime.fromtimestamp(mtime).isoformat()

def load_state(state_path: Path) -> dict:
    """Load .dms_state.json"""
    if not state_path.exists():
        return {
            "metadata": {"last_scan": None},
            "categories": [],
            "documents": {}
        }
    
    try:
        return json.loads(state_path.read_text(encoding='utf-8'))
    except Exception as e:
        print(f"WARNING: Error loading state: {e}", file=sys.stderr)
        return {
            "metadata": {"last_scan": None},
            "categories": [],
            "documents": {}
        }

def load_ignore_list() -> set:
    """Load dms_ignore.json from scripts directory"""
    scripts_dir = Path(__file__).parent.parent
    ignore_path = scripts_dir / "dms_ignore.json"
    
    if not ignore_path.exists():
        return set()
    
    try:
        data = json.loads(ignore_path.read_text(encoding='utf-8'))
        ignored = data.get("ignored_files", [])
        return set(ignored)
    except Exception as e:
        print(f"WARNING: Error loading ignore list: {e}", file=sys.stderr)
        return set()

def is_ignored(filename: str, ignore_list: set) -> bool:
    """Check if filename matches any pattern in ignore list
    
    Supports both exact matches and wildcards (fnmatch patterns)
    Examples: "index.html", "*.log", "DMS_LOG_*"
    """
    for pattern in ignore_list:
        if fnmatch(filename, pattern):
            return True
    return False

def scan_directory(doc_dir: Path, state: dict, ignore_list: set = None) -> tuple:
    """Scan Doc/ directory and detect changes
    
    Handles file pairs:
    - Original file (image, PDF, etc) + readable version in md_outputs/
    - Only the readable version is tracked as a document
    - Original file is linked but ignored during scan
    
    Args:
        doc_dir: Path to Doc directory
        state: Loaded state dict
        ignore_list: Set of patterns to ignore (e.g., {"index.html", "DMS_LOG_*"})
    
    Returns:
        Tuple of (new_files, changed_files, missing_files, ignored_files)
    """
    
    if ignore_list is None:
        ignore_list = set()
    
    new_files = []
    changed_files = []
    missing_files = []
    ignored_files = []
    
    state_docs = state.get("documents", {})
    
    # Find files on disk
    disk_files = {}
    for file_path in doc_dir.rglob("*"):
        if file_path.is_file():
            # Skip hidden files and common non-doc files
            if file_path.name.startswith('.'):
                continue
            # Relative path from doc_dir
            rel_path = f"./{file_path.relative_to(doc_dir)}"
            disk_files[rel_path] = file_path
    
    # Find which files have readable versions in md_outputs
    # Maps original file -> readable file
    readable_versions = {}
    orphaned_readables = set()  # md_outputs files without a matching original
    
    for rel_path in disk_files.keys():
        if './md_outputs/' in rel_path:
            # This is a readable version
            # Find its corresponding original
            # For files like IMG_4666.jpeg.txt, we need IMG_4666.jpeg
            filename_with_ext = Path(rel_path).name
            if filename_with_ext.endswith('.txt'):
                # Remove .txt extension
                filename_no_txt = filename_with_ext[:-4]  # e.g., "IMG_4666.jpeg" or "IMG_4666 copy"
                
                # Look for matching original in root
                found_original = False
                for orig_path in disk_files.keys():
                    if './md_outputs/' not in orig_path:  # In root
                        orig_name = Path(orig_path).name
                        # Match: filename_no_txt could be either:
                        # 1. The full original name (IMG_4666.jpeg.txt -> IMG_4666.jpeg)
                        # 2. The original without extension (IMG_4666.jpeg.txt from image-to-text -> IMG_4666.jpeg)
                        if orig_name == filename_no_txt or orig_name.startswith(filename_no_txt):
                            readable_versions[orig_path] = rel_path
                            found_original = True
                            break
                
                if not found_original:
                    # md_outputs file with no matching original - skip it
                    orphaned_readables.add(rel_path)
    
    # Check for new and changed files
    for rel_path, file_path in disk_files.items():
        # Skip all md_outputs files (whether paired or orphaned)
        if './md_outputs/' in rel_path:
            continue
        
        # Skip ignored files
        filename = Path(rel_path).name
        if is_ignored(filename, ignore_list):
            ignored_files.append(rel_path)
            continue
        
        # For original files that have readable versions:
        # Just process the original file normally, don't track the readable version separately
        # The readable version is only used during summarization
        if rel_path in readable_versions:
            # Process the original file, not the readable version
            file_hash = compute_file_hash(file_path)
            
            if rel_path not in state_docs:
                # New file
                new_files.append({
                    "path": rel_path,
                    "hash": file_hash,
                    "size": file_path.stat().st_size,
                    "file_mtime": get_file_mtime_iso(file_path)
                })
            else:
                # Check if changed (but skip if old hash is empty - file just wasn't hashed yet)
                old_hash = state_docs[rel_path].get("hash", "")
                if old_hash and old_hash != file_hash:
                    changed_files.append({
                        "path": rel_path,
                        "old_hash": old_hash,
                        "new_hash": file_hash
                    })
            
            # Skip to next file
            continue
        
        # For files without readable versions, process normally
        file_hash = compute_file_hash(file_path)
        
        if rel_path not in state_docs:
            # New file
            new_files.append({
                "path": rel_path,
                "hash": file_hash,
                "size": file_path.stat().st_size,
                "file_mtime": get_file_mtime_iso(file_path)
            })
        else:
            # Check if changed (but skip if old hash is empty - file just wasn't hashed yet)
            old_hash = state_docs[rel_path].get("hash", "")
            if old_hash and old_hash != file_hash:
                changed_files.append({
                    "path": rel_path,
                    "old_hash": old_hash,
                    "new_hash": file_hash
                })
    
    # Check for missing files (in state but not on disk)
    for rel_path, doc_data in state_docs.items():
        if rel_path not in disk_files:
            missing_files.append({
                "path": rel_path,
                "was_category": doc_data.get("category", "Unknown")
            })
    
    return new_files, changed_files, missing_files, ignored_files

def print_report(new_files, changed_files, missing_files, ignored_files=None, status_only=False):
    """Print scan report"""
    
    if ignored_files is None:
        ignored_files = []
    
    print(f"\n=== DMS SCAN REPORT ===\n")
    print(f"New files: {len(new_files)}")
    if new_files and not status_only:
        for f in new_files[:10]:
            print(f"  + {f['path']}")
        if len(new_files) > 10:
            print(f"  ... and {len(new_files) - 10} more")
    
    print(f"\nChanged files: {len(changed_files)}")
    if changed_files and not status_only:
        for f in changed_files[:10]:
            print(f"  ~ {f['path']}")
        if len(changed_files) > 10:
            print(f"  ... and {len(changed_files) - 10} more")
    
    print(f"\nMissing files: {len(missing_files)}")
    if missing_files and not status_only:
        for f in missing_files[:10]:
            print(f"  - {f['path']} (was {f['was_category']})")
        if len(missing_files) > 10:
            print(f"  ... and {len(missing_files) - 10} more")
    
    print(f"\nIgnored files: {len(ignored_files)}")
    if ignored_files and not status_only:
        for f in ignored_files[:10]:
            print(f"  ⊘ {f}")
        if len(ignored_files) > 10:
            print(f"  ... and {len(ignored_files) - 10} more")
    
    total = len(new_files) + len(changed_files) + len(missing_files)
    print(f"\nTotal changes: {total}")
    
    if total == 0:
        print("✓ No changes detected. Index is up to date.")
    
    return total

def check_for_convertible_files(new_files):
    """Check if new files include images, PDFs, or DOCX files that need conversion"""
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff', '.webp'}
    pdf_exts = {'.pdf'}
    docx_exts = {'.docx', '.doc'}
    
    images = [f for f in new_files if Path(f['path']).suffix.lower() in image_exts]
    pdfs = [f for f in new_files if Path(f['path']).suffix.lower() in pdf_exts]
    docx_files = [f for f in new_files if Path(f['path']).suffix.lower() in docx_exts]
    
    return {
        'images': images,
        'pdfs': pdfs,
        'docx': docx_files
    }

def main():
    parser = argparse.ArgumentParser(description="Scan Doc/ directory for changes")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--status-only", action="store_true", help="Just show status, don't save")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    state_path = doc_dir / ".dms_state.json"
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    # Load state
    state = load_state(state_path)
    
    # Load ignore list
    ignore_list = load_ignore_list()
    
    # Scan directory
    new_files, changed_files, missing_files, ignored_files = scan_directory(doc_dir, state, ignore_list)
    
    # Print report
    total = print_report(new_files, changed_files, missing_files, ignored_files, args.status_only)
    
    if total == 0:
        return 0
    
    if args.status_only:
        return 0
    
    # Save scan results for next step
    # This is read by summarize/review
    scan_result = {
        "timestamp": datetime.now().isoformat(),
        "new_files": new_files,
        "changed_files": changed_files,
        "missing_files": missing_files
    }
    
    scan_file = doc_dir / ".dms_scan.json"
    scan_file.write_text(json.dumps(scan_result, indent=2))
    
    print(f"\n✓ Scan results saved to {scan_file}")
    
    # Save missing files for deletion workflow
    if missing_files:
        missing_for_deletion = {
            "timestamp": datetime.now().isoformat(),
            "files": missing_files
        }
        
        deletion_file = doc_dir / ".dms_missing_for_deletion.json"
        deletion_file.write_text(json.dumps(missing_for_deletion, indent=2))
        print(f"✓ Saved missing files to {deletion_file.name}")
    
    # Clean up old pending files from previous workflow runs
    pending_summaries = doc_dir / ".dms_pending_summaries.json"
    pending_approved = doc_dir / ".dms_pending_approved.json"
    deletion_pending = doc_dir / ".dms_deletion_pending.json"
    
    if pending_summaries.exists():
        pending_summaries.unlink()
        print(f"✓ Cleared old {pending_summaries.name}")
    if pending_approved.exists():
        pending_approved.unlink()
        print(f"✓ Cleared old {pending_approved.name}")
    if deletion_pending.exists():
        deletion_pending.unlink()
        print(f"✓ Cleared old {deletion_pending.name}")
    
    # Check for files that need conversion
    convertible = check_for_convertible_files(new_files)
    images_found = convertible['images']
    pdfs_found = convertible['pdfs']
    docx_found = convertible['docx']
    total_convertible = len(images_found) + len(pdfs_found) + len(docx_found)
    
    print(f"\nNext steps:")
    if total_convertible:
        conversion_files = []
        if images_found:
            conversion_files.append(f"{len(images_found)} image(s)")
        if pdfs_found:
            conversion_files.append(f"{len(pdfs_found)} PDF(s)")
        if docx_found:
            conversion_files.append(f"{len(docx_found)} DOCX file(s)")
        
        print(f"  1. Run: dms image-to-text (convert {', '.join(conversion_files)} to text/markdown)")
        print(f"  2. Run: dms summarize (generate summaries for converted files)")
    else:
        print(f"  1. Run: dms summarize (to generate summaries for new files)")
    print(f"  2. Run: dms review (to approve changes)")
    print(f"  3. Run: dms apply (to update index.html)")
    
    if missing_files:
        print(f"\n⚠️  MISSING FILES DETECTED:")
        print(f"  The following files are in the index but no longer exist on disk:")
        for f in missing_files:
            print(f"    • {f['path']} (was in {f['was_category']})")
        print(f"\n  To review and delete these from the index:")
        print(f"    Run: dms delete-entry")
        print(f"\n  Or to auto-remove all of them:")
        print(f"    Run: dms cleanup")
        print(f"\n  This will:")
        print(f"    1. Remove missing files from .dms_state.json")
        print(f"    2. Regenerate index.html without those entries")
        print(f"\n  Note: You can run cleanup at any time (before or after applying new changes)")
    
    # Prompt to continue
    if total_convertible:
        next_cmd = "image-to-text"
    else:
        next_cmd = "summarize"
    
    choice = input(f"\nStart 'dms {next_cmd}' now? [y/N]: ").strip().lower()
    if choice == 'y':
        result = subprocess.run(['dms', next_cmd])
        return result.returncode
    
    return 0

if __name__ == "__main__":
    exit(main())
