#!/usr/bin/env python3
"""
DMS_image_to_text.py - Convert image files to text descriptions

Uses pytesseract for OCR to extract text from images.
Saves results as .txt files in md_outputs/ parallel to PDF→MD pattern.

For example:
  Doc/diagram.png → Doc/md_outputs/diagram.png.txt
"""
from __future__ import annotations
import argparse
import sys
import json
from pathlib import Path
from datetime import datetime

def check_dependencies():
    """Check if pytesseract is available"""
    try:
        import pytesseract
        from PIL import Image
        return True
    except ImportError as e:
        print("ERROR: Required dependencies not found.", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        print("\nInstall dependencies:", file=sys.stderr)
        print("  pip install pytesseract pillow", file=sys.stderr)
        print("  brew install tesseract", file=sys.stderr)
        return False

def extract_text_from_image(image_path: Path) -> str:
    """Use pytesseract to extract text from image"""
    import pytesseract
    from PIL import Image
    
    try:
        img = Image.open(image_path)
        text = pytesseract.image_to_string(img)
        return text.strip()
    except Exception as e:
        print(f"WARNING: Failed to extract text from {image_path}: {e}", file=sys.stderr)
        return f"[OCR failed: {e}]"

def process_images(doc_dir: Path, md_dir: Path, pending_report: dict) -> int:
    """Process all images in the pending report"""
    md_dir.mkdir(parents=True, exist_ok=True)
    
    # Get new files from pending report
    new_files = pending_report.get("new_files", [])
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff'}
    
    image_files = [f for f in new_files if f['ext'] in image_exts]
    
    if not image_files:
        print("No new image files to process.")
        return 0
    
    print(f"Processing {len(image_files)} image file(s)...\n")
    
    processed = []
    for img_info in image_files:
        img_path = Path(img_info['abs_path'])
        print(f"Processing: {img_path.name}")
        
        # Extract text
        text = extract_text_from_image(img_path)
        
        # Save to md_outputs/
        output_name = f"{img_path.name}.txt"
        output_path = md_dir / output_name
        
        # Add header
        header = f"# {img_path.stem}\n\n"
        header += f"Source: {img_path.name} (OCR extracted)\n"
        header += f"Extracted: {datetime.now().isoformat()}\n\n"
        header += "---\n\n"
        
        output_path.write_text(header + text, encoding='utf-8')
        print(f"  → Saved to: {output_path}")
        
        # Update pending report to include the text file
        new_text_file = {
            "path": f"./md_outputs/{output_name}",
            "abs_path": str(output_path),
            "hash": "",  # Will be computed in next scan
            "size": output_path.stat().st_size,
            "ext": ".txt",
            "source_image": img_info['path']
        }
        processed.append(new_text_file)
    
    print(f"\n✓ Processed {len(processed)} image(s)")
    
    # Update pending report to include new text files
    pending_report['new_files'].extend(processed)
    pending_report['image_processing_done'] = True
    
    return 0

def main():
    parser = argparse.ArgumentParser(description="Convert images to text using OCR")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--md", default="Doc/md_outputs", help="Output directory for text files")
    args = parser.parse_args()
    
    if not check_dependencies():
        print("\nCannot proceed without dependencies.", file=sys.stderr)
        choice = input("Skip image processing? [y/N]: ").strip().lower()
        if choice == 'y':
            print("Skipping image processing.")
            return 0
        return 1
    
    doc_dir = Path(args.doc)
    md_dir = Path(args.md)
    
    # Load pending report from scan
    pending_path = doc_dir / ".dms_pending.json"
    if not pending_path.exists():
        print("ERROR: No pending scan report found.", file=sys.stderr)
        print("Run 'dms scan' first.", file=sys.stderr)
        return 1
    
    pending_report = json.loads(pending_path.read_text(encoding='utf-8'))
    
    # Process images
    rc = process_images(doc_dir, md_dir, pending_report)
    
    # Save updated report
    pending_path.write_text(json.dumps(pending_report, indent=2), encoding='utf-8')
    
    return rc

if __name__ == "__main__":
    sys.exit(main())
