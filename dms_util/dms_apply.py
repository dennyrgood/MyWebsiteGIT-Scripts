#!/usr/bin/env python3
"""
dms_apply.py - Apply approved changes to index.html

Takes approved summaries from review and:
  1. Inserts new <li> entries into appropriate categories
  2. Creates new categories if needed
  3. Updates DMS_STATE with new file hashes
  4. Creates timestamped backup
"""
from __future__ import annotations
import argparse
import sys
import json
import re
import shutil
import html
from pathlib import Path
from datetime import datetime
import hashlib
from collections import defaultdict
from typing import Dict, List, Tuple

# --- Constants and Utility Functions (Unchanged) ---

def compute_file_hash(path: Path) -> str:
    """Compute SHA-256 hash"""
    if not path.exists():
        return "sha256:missing"
    sha = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(8192):
            sha.update(chunk)
    return f"sha256:{sha.hexdigest()}"

def extract_dms_state(index_path: Path) -> dict:
    """Extract DMS_STATE from index.html"""
    if not index_path.exists():
        return {"processed_files": {}, "categories": [], "last_scan": None}
    
    content = index_path.read_text(encoding='utf-8', errors='replace')
    state_pattern = re.compile(r'<!-- DMS_STATE\n(.*?)\n-->', re.DOTALL)
    match = state_pattern.search(content)
    
    if not match:
        return {"processed_files": {}, "categories": [], "last_scan": None}
    
    try:
        # Load the JSON string from the matched group
        state_json = match.group(1).strip()
        # Remove trailing '-->' if it was accidentally captured
        state_json = state_json.removesuffix('-->')
        
        # Strip comments
        state_json = re.sub(r'#.*', '', state_json)
        
        state = json.loads(state_json)
        return state
    except json.JSONDecodeError as e:
        print(f"WARNING: Could not decode DMS_STATE JSON: {e}", file=sys.stderr)
        return {"processed_files": {}, "categories": [], "last_scan": None}

def update_dms_state(content: str, new_state: dict) -> str:
    """Update DMS_STATE block in HTML content"""
    state_pattern = re.compile(r'<!-- DMS_STATE\n.*?\n-->', re.DOTALL)
    
    state_json = json.dumps(new_state, indent=2)
    new_block = f"<!-- DMS_STATE\n{state_json}\n-->"
    
    # Check if a state block already exists
    if state_pattern.search(content):
        return state_pattern.sub(new_block, content, count=1)
    
    # If no state block exists, try to insert it before the closing </main> tag
    if '</main>' in content:
        # Insert before </main> for proper HTML structure
        return content.replace('</main>', f"{new_block}\n</main>", 1)
        
    # Fallback: append to end
    return content + f"\n{new_block}"


def find_category_section(content: str, category_name: str) -> Tuple[int, int] | None:
    """
    Finds the start and end index (inclusive) of the <ul> inside a category section.
    
    Returns: (start_index, end_index) of the <ul> content, or None if not found.
    """
    # Regex to find the <section> with the correct data-category
    category_pattern = re.compile(
        rf'<section class="category".*?data-category="{re.escape(category_name)}".*?>',
        re.DOTALL | re.IGNORECASE
    )
    
    match_section = category_pattern.search(content)
    if not match_section:
        return None
        
    section_start = match_section.end()
    
    # Now find the <ul> inside this section
    ul_pattern = re.compile(r'<ul class="files">', re.DOTALL)
    ul_end_pattern = re.compile(r'</ul>', re.DOTALL)
    
    match_ul_start = ul_pattern.search(content, section_start)
    if not match_ul_start:
        return None # Category section found, but no <ul>
        
    ul_start = match_ul_start.end()
    
    # Find the closing </ul> *after* the opening <ul>
    match_ul_end = ul_end_pattern.search(content, ul_start)
    if not match_ul_end:
        return None # Opening <ul> found, but no closing </ul>
        
    ul_end = match_ul_end.start()
    
    return ul_start, ul_end

def create_file_entry(summary_info: dict, doc_dir: Path) -> str:
    """Generates the HTML <li> entry for a file."""
    
    file_path = summary_info['file']['path']
    # If the path is to a generated text file (in md_outputs), link to the original
    if 'md_outputs' in file_path and file_path.endswith('.txt'):
        # Original file path is typically file_path.removesuffix('.txt')
        # We need to strip the Doc/ prefix
        original_path = Path(file_path.removesuffix('.txt')).relative_to(doc_dir)
        link_path = str(original_path)
    else:
        # Standard link to the file itself
        link_path = file_path
    
    # Use the filename without extension as the title, or the explicit title if present
    file_title = summary_info.get('title') or Path(file_path).stem
    
    # Ensure all strings are HTML escaped to prevent XSS or malformed HTML
    title_escaped = html.escape(file_title)
    summary_escaped = html.escape(summary_info['summary'])
    category_escaped = html.escape(summary_info['category'])
    path_escaped = html.escape(file_path)
    link_path_escaped = html.escape(link_path)
    
    # Get extension for tags
    file_ext = Path(file_path).suffix.lstrip('.').upper() or 'N/A'
    
    # The data-pdf attribute is used if the file is a PDF and we link to the generated markdown
    # For simplicity, we can use the file extension to guide the tag display
    
    entry = f"""
    <li class="file" data-path="{path_escaped}" data-link="{link_path_escaped}">
      <div class="meta">
        <div class="title"><a href="#{link_path_escaped}" class="file-link">{title_escaped}</a></div>
        <div class="desc">{summary_escaped}</div>
        <div class="tags small-muted">{file_ext} · {category_escaped}</div>
      </div>
    </li>"""
    
    return entry.strip()

def create_category_section(category_name: str, file_entries: str) -> str:
    """
    Creates a new complete HTML section for a category.
    Includes the file entries (<li>) inside the <ul>.
    """
    category_escaped = html.escape(category_name)
    
    # Create the full section block
    section = f"""
<section class="category" data-category="{category_escaped}">
  <h2>{category_escaped}</h2>
  <ul class="files">
{file_entries}
  </ul>
</section>
"""
    return section.strip()


# --- Core Logic (Revised) ---

def apply_changes(index_path: Path, approved_summaries: List[dict], doc_dir: Path):
    """
    Reads index.html, inserts new entries, and updates the DMS state.
    Handles creation of new categories if they do not exist.
    """
    
    # 1. Load current content and DMS state
    content = index_path.read_text(encoding='utf-8')
    state = extract_dms_state(index_path)
    
    # 2. Group approved summaries by category
    categories_to_insert = defaultdict(list)
    for summary_info in approved_summaries:
        category = summary_info['category']
        if not category:
            print(f"WARNING: Skipping file with empty category: {summary_info['file']['path']}", file=sys.stderr)
            continue
        categories_to_insert[category].append(summary_info)

    updated_content = content
    insertion_count = 0
    
    # 3. Process each category
    for category, summaries in categories_to_insert.items():
        
        # Check if the category section already exists
        category_indices = find_category_section(updated_content, category)
        
        # Generate all <li> entries for this category
        new_list_items = "\n".join([
            create_file_entry(s, doc_dir) for s in summaries
        ])
        
        if category_indices:
            # Category exists: Insert new <li> items into the existing <ul>
            ul_start, ul_end = category_indices
            
            # Insert the new items before the closing </ul> tag (ul_end index)
            # Add a leading newline for clean formatting
            updated_content = (
                updated_content[:ul_end] + 
                "\n" + new_list_items + 
                updated_content[ul_end:]
            )
            insertion_count += len(summaries)
            print(f"  + Added {len(summaries)} file(s) to existing category: {category}")
            
        else:
            # Category does NOT exist: Create the entire new section and insert it
            print(f"  + Creating new category section: {category}")
            new_section = create_category_section(category, new_list_items)
            
            # Find insertion point for the new section: before the closing </main> tag
            if '</main>' in updated_content:
                # Insert before </main> for proper HTML structure
                updated_content = updated_content.replace('</main>', f"\n{new_section}\n</main>", 1)
                insertion_count += len(summaries)
                
                # Update DMS state with the new category
                if category not in state.get('categories', []):
                    state.setdefault('categories', []).append(category)
            else:
                print(f"ERROR: Could not find </main> tag to insert new category '{category}'. Skipping.", file=sys.stderr)
                # If insertion fails, the insertion_count remains unchanged for this group

    # 4. Update DMS State: Add approved files to processed_files
    for summary_info in approved_summaries:
        # Use the final category name
        category = summary_info['category']
        file_path = summary_info['file']['path']
        
        # Re-compute hash just in case, though it should be fresh from scan
        file_hash = compute_file_hash(doc_dir / file_path)
        
        # Update the state entry
        state['processed_files'][file_path] = {
            'hash': file_hash,
            'category': category,
            'summary': summary_info['summary']
        }
        
    state['last_scan'] = datetime.now().isoformat()
    
    # 5. Update the DMS_STATE block in the HTML
    final_content = update_dms_state(updated_content, state)
    
    # 6. Backup and write
    backup_path = index_path.parent / f"{index_path.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, backup_path)
    print(f"Backed up to: {backup_path}")
    
    # Only write if we actually inserted something (or if DMS state was the only update, which is fine)
    if insertion_count > 0 or content != final_content:
        index_path.write_text(final_content, encoding='utf-8')
        print(f"✓ Updated {index_path}")
    else:
        print(f"No content changes detected in {index_path}. Skipping file write.")


def main():
    parser = argparse.ArgumentParser(description="Apply approved changes to index.html")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    args = parser.parse_args()
    
    index_path = Path(args.index)
    doc_dir = index_path.parent
    pending_path = doc_dir / ".dms_pending.json"
    
    if not pending_path.exists():
        print("ERROR: No pending report found.", file=sys.stderr)
        return 1
    
    pending_report = json.loads(pending_path.read_text(encoding='utf-8'))
    
    approved_summaries = pending_report.get('approved_summaries', [])
    
    if not approved_summaries:
        print("No approved summaries to apply.")
        return 0
    
    print(f"Applying {len(approved_summaries)} change(s) to index.html...\n")
    
    apply_changes(index_path, approved_summaries, doc_dir)
    
    print("\n" + "="*70)
    print("Changes applied successfully!")
    print("="*70)
    
    # 7. Archive pending file (keep for debugging)
    try:
        from datetime import datetime
        archive_path = pending_path.parent / f".dms_pending.archive.{datetime.now().strftime('%Y%m%d%H%M%S')}.json"
        pending_path.rename(archive_path)
        print(f"\nAdded {len(approved_summaries)} file(s) to index.html")
        print(f"Archived pending file to {archive_path}")
    except OSError as e:
        print(f"WARNING: Could not archive pending file: {e}", file=sys.stderr)

    return 0

if __name__ == "__main__":
    sys.exit(main())
