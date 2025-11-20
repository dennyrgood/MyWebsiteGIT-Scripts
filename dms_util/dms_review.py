#!/usr/bin/env python3
"""
dms_review.py - Interactive review of AI-generated summaries

Presents each file summary for approval/editing.
User can:
  - [a]pprove - accept as-is
  - [e]dit - modify summary/category
  - [s]kip - don't add this file to index
  - [q]uit - stop review (progress saved)
"""
from __future__ import annotations
import argparse
import sys
import json
from pathlib import Path

def show_file_preview(file_info: dict, num_lines: int = 10) -> None:
    """
    Show first few lines of file for context
    
    ISSUE 2 FIX: Skip preview for images and generated text files from md_outputs/
    """
    path = Path(file_info['abs_path'])
    
    # Skip images
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff'}
    if path.suffix.lower() in image_exts:
        print("  [Image file - preview skipped]")
        return
    
    # Skip generated text files from image processing (in md_outputs/)
    if 'md_outputs' in str(path):
        # Check if this is a converted file (e.g., image.png.txt)
        if '.txt' in path.name and any(ext in path.name for ext in ['.png', '.jpg', '.jpeg', '.gif', '.docx']):
            print("  [Generated text from conversion - preview skipped]")
            return
    
    try:
        with path.open('r', encoding='utf-8', errors='replace') as f:
            lines = []
            for _ in range(num_lines):
                line = f.readline()
                if not line:
                    break
                lines.append(line.rstrip())
        
        if lines:
            print("  File preview:")
            print("  " + "-"*60)
            for line in lines:
                print(f"  {line[:80]}")
            print("  " + "-"*60)
    except Exception as e:
        print(f"  [Cannot preview file: {e}]")

def review_summaries(pending_report: dict) -> dict:
    """Interactive review loop"""
    summaries = pending_report.get('summaries', [])
    
    if not summaries:
        print("No summaries to review.")
        return pending_report
    
    approved = []
    skipped = []
    
    print(f"\nReviewing {len(summaries)} file(s)\n")
    print("Commands: [a]pprove, [e]dit, [s]kip, [q]uit\n")
    
    for i, item in enumerate(summaries, 1):
        file_info = item['file']
        summary = item['summary']
        category = item['category']
        is_new_cat = item['is_new_category']
        
        print("="*70)
        print(f"[{i}/{len(summaries)}] {file_info['path']}")
        print("="*70)
        print(f"File: {Path(file_info['abs_path']).name}")
        print(f"Type: {file_info['ext']}")
        print(f"Size: {file_info['size'] / 1024:.1f} KB")
        print()
        
        # Show preview
        show_file_preview(file_info, num_lines=8)
        print()
        
        print(f"Summary: {summary}")
        print(f"Category: {category} {'(NEW CATEGORY)' if is_new_cat else ''}")
        print()
        
        while True:
            choice = input("Action [a/e/s/q] (default=a): ").strip().lower() or 'a'
            
            if choice == 'a':
                # Approve as-is
                approved.append({
                    'file': file_info,
                    'summary': summary,
                    'category': category,
                    'is_new_category': is_new_cat,
                    'approved': True
                })
                print("✓ Approved\n")
                break
            
            elif choice == 'e':
                # Edit
                print(f"Current summary: {summary}")
                new_summary = input("New summary (or Enter to keep): ").strip()
                if new_summary:
                    summary = new_summary
                
                print(f"Current category: {category}")
                new_category = input("New category (or Enter to keep): ").strip()
                if new_category:
                    category = new_category
                    is_new_cat = True  # Assume any edit creates potential new category
                
                approved.append({
                    'file': file_info,
                    'summary': summary,
                    'category': category,
                    'is_new_category': is_new_cat,
                    'approved': True
                })
                print("✓ Edited and approved\n")
                break
            
            elif choice == 's':
                # Skip
                skipped.append(file_info['path'])
                print("⊘ Skipped\n")
                break
            
            elif choice == 'q':
                # Quit
                print("\nStopping review. Progress saved.")
                pending_report['approved_summaries'] = approved
                pending_report['skipped_files'] = skipped
                pending_report['review_complete'] = False
                return pending_report
            
            else:
                print("Invalid choice. Use a/e/s/q")
    
    # All reviewed
    pending_report['approved_summaries'] = approved
    pending_report['skipped_files'] = skipped
    pending_report['review_complete'] = True
    
    return pending_report

def main():
    parser = argparse.ArgumentParser(description="Interactive review of AI summaries")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    args = parser.parse_args()
    
    doc_dir = Path(args.index).parent
    pending_path = doc_dir / ".dms_pending.json"
    
    if not pending_path.exists():
        print("ERROR: No pending report found.", file=sys.stderr)
        print("Run 'dms summarize' first.", file=sys.stderr)
        return 1
    
    pending_report = json.loads(pending_path.read_text(encoding='utf-8'))
    
    if not pending_report.get('summarization_done'):
        print("ERROR: Summarization not complete.", file=sys.stderr)
        print("Run 'dms summarize' first.", file=sys.stderr)
        return 1
    
    # Start review
    updated_report = review_summaries(pending_report)
    
    # Save progress
    pending_path.write_text(json.dumps(updated_report, indent=2), encoding='utf-8')
    
    # Summary
    approved = updated_report.get('approved_summaries', [])
    skipped = updated_report.get('skipped_files', [])
    
    print("\n" + "="*70)
    print("Review Summary")
    print("="*70)
    print(f"Approved: {len(approved)}")
    print(f"Skipped: {len(skipped)}")
    
    if updated_report.get('review_complete'):
        print("\n✓ Review complete!")
        print("Next step: Run 'dms apply' to update index.html")
    else:
        print("\n⊘ Review incomplete (stopped early)")
        print("Run 'dms review' again to continue, or 'dms apply' to apply what's approved so far")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
