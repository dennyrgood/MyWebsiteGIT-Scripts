#!/usr/bin/env python3
"""
dms_image_to_text.py - Convert images AND PDFs to text

Reads .dms_scan.json to find images/PDFs in new files.
- Converts images (PNG, JPG) to text via OCR (tesseract)
- Converts PDFs to text/markdown via PyMuPDF (fitz)
Outputs text files to md_outputs/ for later summarization.

Does NOT update any state files - just produces intermediate text files.
"""
import argparse
import sys
import json
import subprocess
from pathlib import Path

def load_scan_results(scan_path: Path) -> dict:
    """Load .dms_scan.json to see what changed"""
    if not scan_path.exists():
        print(f"No scan results found at {scan_path}")
        return {"new_files": [], "changed_files": []}
    
    return json.loads(scan_path.read_text(encoding='utf-8'))

def find_convertible_files(files: list, doc_dir: Path) -> tuple:
    """Find image and PDF files in the list"""
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'}
    pdf_exts = {'.pdf'}
    
    images = []
    pdfs = []
    
    for file_info in files:
        file_path = file_info.get('path', '')
        ext = Path(file_path).suffix.lower()
        if ext in image_exts:
            images.append(file_path)
        elif ext in pdf_exts:
            pdfs.append(file_path)
    
    return images, pdfs

def convert_image_to_text(image_path: str, doc_dir: Path, md_dir: Path) -> bool:
    """Convert image to text using tesseract"""
    
    full_path = doc_dir / image_path.lstrip('./')
    
    if not full_path.exists():
        print(f"  ⚠ Image not found: {image_path}")
        return False
    
    # Create output filename
    output_filename = f"{Path(image_path).stem}.txt"
    output_path = md_dir / output_filename
    
    if output_path.exists():
        print(f"  ✓ Already converted: {output_filename}")
        return True
    
    try:
        # Use tesseract to extract text
        result = subprocess.run(
            ['tesseract', str(full_path), str(output_path.with_suffix(''))],
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode == 0 and output_path.exists():
            print(f"  ✓ Converted: {output_filename}")
            return True
        else:
            print(f"  ✗ Failed to convert {image_path}: {result.stderr[:100]}")
            return False
            
    except FileNotFoundError:
        print(f"  ✗ tesseract not found - install with: brew install tesseract")
        return False
    except Exception as e:
        print(f"  ✗ Error: {e}")
        return False

def convert_pdf_to_text(pdf_path: str, doc_dir: Path, md_dir: Path) -> bool:
    """Convert PDF to text/markdown using tools_pdf_to_md_textonly.py"""
    
    full_path = doc_dir / pdf_path.lstrip('./')
    
    if not full_path.exists():
        print(f"  ⚠ PDF not found: {pdf_path}")
        return False
    
    # Create output filename
    output_filename = f"{Path(pdf_path).stem}.txt"
    output_path = md_dir / output_filename
    
    if output_path.exists():
        print(f"  ✓ Already converted: {output_filename}")
        return True
    
    try:
        # Find the PDF conversion tool
        scripts_dir = Path.home() / "Documents/MyWebsiteGIT/Scripts"
        pdf_tool = scripts_dir / "tools_pdf_to_md_textonly.py"
        
        if not pdf_tool.exists():
            print(f"  ✗ PDF tool not found at {pdf_tool}")
            return False
        
        # Run the PDF tool
        result = subprocess.run(
            ['python3', str(pdf_tool), str(full_path), '--out-dir', str(md_dir)],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        # Check if it created an output file (might be .md instead of .txt)
        md_output = md_dir / f"{Path(pdf_path).stem}.md"
        
        if md_output.exists():
            # Rename .md to .txt for consistency with image OCR
            md_output.rename(output_path)
            print(f"  ✓ Converted: {output_filename}")
            return True
        elif result.returncode == 0:
            print(f"  ✓ Converted: {output_filename}")
            return True
        else:
            print(f"  ✗ Failed to convert {pdf_path}: {result.stderr[:100]}")
            return False
            
    except Exception as e:
        print(f"  ✗ Error: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Convert images and PDFs to text")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    scan_path = doc_dir / ".dms_scan.json"
    md_dir = doc_dir / "md_outputs"
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    # Create md_outputs if needed
    md_dir.mkdir(exist_ok=True)
    
    # Load scan results
    scan_data = load_scan_results(scan_path)
    all_files = scan_data.get('new_files', []) + scan_data.get('changed_files', [])
    
    images, pdfs = find_convertible_files(all_files, doc_dir)
    
    if not images and not pdfs:
        print("No images or PDFs to convert")
        return 0
    
    print(f"\n==> Converting images and PDFs to text...\n")
    
    if images:
        print(f"Images ({len(images)}):")
        converted_img = 0
        for image_path in images:
            if convert_image_to_text(image_path, doc_dir, md_dir):
                converted_img += 1
        print(f"✓ {converted_img}/{len(images)} images converted\n")
    
    if pdfs:
        print(f"PDFs ({len(pdfs)}):")
        converted_pdf = 0
        for pdf_path in pdfs:
            if convert_pdf_to_text(pdf_path, doc_dir, md_dir):
                converted_pdf += 1
        print(f"✓ {converted_pdf}/{len(pdfs)} PDFs converted\n")
    
    print("Next step:")
    print("  Run: dms summarize")
    
    return 0

if __name__ == "__main__":
    exit(main())
