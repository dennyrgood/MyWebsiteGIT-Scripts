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

def convert_docx_to_text(docx_path: Path) -> str:
    """Use pandoc to convert DOCX to plain text"""
    import subprocess
    try:
        result = subprocess.run(
            ['pandoc', '-f', 'docx', '-t', 'plain', str(docx_path)],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            return f"[Pandoc conversion failed: {result.stderr}]"
    except FileNotFoundError:
        return "[Pandoc not found - install with: brew install pandoc]"
    except Exception as e:
        return f"[DOCX conversion error: {e}]"

def process_images(doc_dir: Path, md_dir: Path, pending_report: dict) -> int:
    """Process all images and DOCX files in the pending report"""
    md_dir.mkdir(parents=True, exist_ok=True)
    
    # Get new files from pending report
    new_files = pending_report.get("new_files", [])
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff'}
    docx_exts = {'.docx', '.doc'}
    
    # Check if text versions already exist
    files_to_process = []
    for f in new_files:
        if f['ext'] in image_exts or f['ext'] in docx_exts:
            # Check if .txt already exists in md_outputs
            source_name = Path(f['abs_path']).name
            txt_name = f"{source_name}.txt"
            txt_path = md_dir / txt_name
            
            if txt_path.exists():
                print(f"Skipping {source_name} - text file already exists: {txt_path}")
                # Add existing txt to pending report
                new_files.append({
                    "path": f"./md_outputs/{txt_name}",
                    "abs_path": str(txt_path),
                    "hash": "",
                    "size": txt_path.stat().st_size,
                    "ext": ".txt",
                    "source_file": f['path']
                })
            else:
                files_to_process.append(f)
    
    if not files_to_process:
        print("No new image/DOCX files to process (or text files already exist).")
        return 0
    
    print(f"Processing {len(files_to_process)} file(s)...\n")
    
    processed = []
    for file_info in files_to_process:
        file_path = Path(file_info['abs_path'])
        print(f"Processing: {file_path.name}")
        
        # Determine processing method
        if file_info['ext'] in {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff'}:
            # Extract text via OCR
            text = extract_text_from_image(file_path)
            header = f"# {file_path.stem}\n\n"
            header += f"Source: {file_path.name} (OCR extracted)\n"
            header += f"Extracted: {datetime.now().isoformat()}\n\n"
            header += "---\n\n"
        
        elif file_info['ext'] in {'.docx', '.doc'}:
            # Convert DOCX via pandoc
            text = convert_docx_to_text(file_path)
            header = f"# {file_path.stem}\n\n"
            header += f"Source: {file_path.name} (converted from DOCX)\n"
            header += f"Converted: {datetime.now().isoformat()}\n\n"
            header += "---\n\n"
        else:
            print(f"  Skipping unsupported file type: {file_info['ext']}")
            continue
        
        # Save to md_outputs/
        output_name = f"{file_path.name}.txt"
        output_path = md_dir / output_name
        
        output_path.write_text(header + text, encoding='utf-8')
        print(f"  → Saved to: {output_path}")
        
        # Update pending report to include the text file
        new_text_file = {
            "path": f"./md_outputs/{output_name}",
            "abs_path": str(output_path),
            "hash": "",  # Will be computed in next scan
            "size": output_path.stat().st_size,
            "ext": ".txt",
            "source_file": file_info['path']
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
