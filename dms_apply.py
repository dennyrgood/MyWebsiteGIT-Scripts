#!/usr/bin/env python3
"""
DMS_apply.py - Apply approved changes to index.html

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
        return json.loads(match.group(1))
    except:
        return {"processed_files": {}, "categories": [], "last_scan": None}

def update_dms_state(index_path: Path, new_state: dict) -> str:
    """Update DMS_STATE in index.html content"""
    content = index_path.read_text(encoding='utf-8', errors='replace')
    
    state_json = json.dumps(new_state, indent=2)
    new_state_block = f"<!-- DMS_STATE\n{state_json}\n-->"
    
    # Replace existing or insert after <body>
    state_pattern = re.compile(r'<!-- DMS_STATE\n.*?\n-->', re.DOTALL)
    
    if state_pattern.search(content):
        content = state_pattern.sub(new_state_block, content)
    else:
        # Insert after <body>
        body_pos = content.find('<body>')
        if body_pos != -1:
            insert_pos = content.find('>', body_pos) + 1
            content = content[:insert_pos] + '\n' + new_state_block + '\n' + content[insert_pos:]
    
    return content

def find_category_section(content: str, category: str) -> tuple[int, int] | None:
    """Find the <ul class="files"> section for a category. Returns (ul_open_end, ul_close_start)"""
    # Try exact match first
    pattern = re.compile(
        rf'<section\s+class="category"\s+data-category="{re.escape(category)}"[^>]*>.*?<ul\s+class="files"[^>]*>',
        re.DOTALL | re.IGNORECASE
    )
    match = pattern.search(content)
    
    if not match:
        # Try h2 match
        pattern2 = re.compile(
            rf'<section\s+class="category"[^>]*>.*?<h2>{re.escape(category)}</h2>.*?<ul\s+class="files"[^>]*>',
            re.DOTALL | re.IGNORECASE
        )
        match = pattern2.search(content)
    
    if not match:
        return None
    
    ul_open_end = match.end()
    
    # Find closing </ul>
    ul_close_pattern = re.compile(r'</ul\s*>', re.IGNORECASE)
    ul_close_match = ul_close_pattern.search(content[ul_open_end:])
    
    if not ul_close_match:
        return None
    
    ul_close_start = ul_open_end + ul_close_match.start()
    
    return (ul_open_end, ul_close_start)

def create_category_section(category: str, display_name: str = None) -> str:
    """Create new category section HTML"""
    if not display_name:
        display_name = category
    
    return f'''
        <section class="category" data-category="{html.escape(category)}">
          <h2>{html.escape(display_name)}</h2>
          <ul class="files">
          </ul>
        </section>
'''

def create_file_entry(item: dict, doc_dir: Path) -> str:
    """Create <li> entry HTML"""
    file_info = item['file']
    summary = item['summary']
    category = item['category']
    
    data_path = file_info['path']
    
    # Determine data-pdf
    data_pdf = ""
    file_path = Path(file_info['abs_path'])
    
    # If this is an MD in md_outputs, look for matching PDF
    if data_path.startswith('./md_outputs/'):
        stem = file_path.stem
        # Remove .txt or other extensions from stem if present (e.g., image.png.txt -> image.png)
        if '.' in stem:
            potential_orig = stem  # Keep as-is for now
        
        # Check for PDF with same stem in Doc/
        for ext in ['.pdf', '.PDF']:
            pdf_candidate = doc_dir / f"{file_path.stem}{ext}"
            if pdf_candidate.exists():
                data_pdf = f"./{pdf_candidate.name}"
                break
    
    # If this IS a PDF, reference itself
    if file_info['ext'] == '.pdf':
        data_pdf = data_path
    
    # Determine file type label for tags
    ext = file_info['ext'].upper().lstrip('.')
    if ext == 'MD':
        type_label = 'MD'
    elif ext in ['TXT', 'TEXT']:
        type_label = 'TXT'
    elif ext == 'PDF':
        type_label = 'PDF'
    else:
        type_label = ext
    
    tags = f"{type_label} · {category}"
    
    # Title: use filename stem, cleaned up
    title = file_path.stem.replace('_', ' ').replace('-', ' ')
    
    return f'''
            <li class="file" data-path="{html.escape(data_path)}" data-pdf="{html.escape(data_pdf)}">
              <div class="meta">
                <div class="title"><a href="#" class="file-link">{html.escape(title)}</a></div>
                <div class="desc">{html.escape(summary)}</div>
                <div class="tags small-muted">{html.escape(tags)}</div>
              </div>
            </li>
'''

def apply_changes(index_path: Path, approved_summaries: list, doc_dir: Path) -> None:
    """Apply approved changes to index.html"""
    content = index_path.read_text(encoding='utf-8', errors='replace')
    
    # Get current state
    state = extract_dms_state(index_path)
    existing_categories = set(state.get('categories', []))
    
    # Group by category
    by_category = {}
    for item in approved_summaries:
        cat = item['category']
        by_category.setdefault(cat, []).append(item)
    
    # Track insertions (from end to start to preserve positions)
    insertions = []
    new_categories_html = []
    
    for category, items in by_category.items():
        # Check if category exists
        cat_position = find_category_section(content, category)
        
        if cat_position:
            # Insert into existing category
            ul_open_end, ul_close_start = cat_position
            
            # Build entries
            entries_html = ''.join(create_file_entry(item, doc_dir) for item in items)
            
            insertions.append((ul_close_start, entries_html))
        else:
            # New category - build section
            new_section = create_category_section(category, category)
            
            # Insert entries into the section
            entries_html = ''.join(create_file_entry(item, doc_dir) for item in items)
            new_section = new_section.replace('</ul>', entries_html + '\n          </ul>')
            
            new_categories_html.append(new_section)
            existing_categories.add(category)
    
    # Apply insertions (reverse order to maintain positions)
    for position, html_content in sorted(insertions, reverse=True):
        content = content[:position] + html_content + content[position:]
    
    # Insert new categories before closing </div></aside> of sidebar
    if new_categories_html:
        # Find the lists div closing
        lists_close = re.search(r'</div>\s*</aside>', content, re.IGNORECASE)
        if lists_close:
            insert_pos = lists_close.start()
            all_new_cats = '\n'.join(new_categories_html)
            content = content[:insert_pos] + all_new_cats + '\n' + content[insert_pos:]
    
    # Update DMS_STATE
    for item in approved_summaries:
        file_info = item['file']
        file_path = Path(file_info['abs_path'])
        file_hash = compute_file_hash(file_path)
        
        state['processed_files'][file_info['path']] = {
            "hash": file_hash,
            "last_processed": datetime.now().isoformat(),
            "summary_approved": True,
            "title": file_path.stem,
            "description": item['summary']
        }
    
    state['categories'] = sorted(list(existing_categories))
    state['last_scan'] = datetime.now().isoformat()
    
    content = update_dms_state(index_path, state)
    
    # Backup and write
    backup_path = index_path.parent / f"{index_path.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(index_path, backup_path)
    print(f"Backed up to: {backup_path}")
    
    index_path.write_text(content, encoding='utf-8')
    print(f"✓ Updated {index_path}")

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
    print(f"\nAdded {len(approved_summaries)} file(s) to index.html")
    
    # Clean up pending report
    pending_path.unlink()
    print(f"Cleaned up {pending_path}")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
