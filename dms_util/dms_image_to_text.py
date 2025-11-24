#!/usr/bin/env python3
"""
dms_image_to_text.py - Convert images, PDFs, and DOCX files to text/markdown

Reads .dms_scan.json to find convertible files.
- Converts images (PNG, JPG, etc.) to text via OCR (tesseract)
- Converts PDFs to markdown via pandoc
- Converts DOCX to markdown via pandoc
Outputs text/markdown files to md_outputs/ for later summarization.

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

def find_convertible_files(files: list, doc_dir: Path) -> dict:
    """Find image, PDF, and DOCX files in the list"""
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'}
    pdf_exts = {'.pdf'}
    docx_exts = {'.docx', '.doc'}
    
    images = []
    pdfs = []
    docx_files = []
    
    for file_info in files:
        file_path = file_info.get('path', '')
        ext = Path(file_path).suffix.lower()
        if ext in image_exts:
            images.append(file_path)
        elif ext in pdf_exts:
            pdfs.append(file_path)
        elif ext in docx_exts:
            docx_files.append(file_path)
    
    return {
        'images': images,
        'pdfs': pdfs,
        'docx': docx_files
    }

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
            stderr_msg = result.stderr.strip() if result.stderr else "Unknown error"
            print(f"  ✗ Failed to convert {image_path}")
            print(f"     tesseract error: {stderr_msg[:150]}")
            return False
            
    except subprocess.TimeoutExpired:
        print(f"  ✗ tesseract timeout (60s) on {image_path}")
        return False
    except FileNotFoundError:
        print(f"  ✗ tesseract not found - install with: brew install tesseract")
        return False
    except Exception as e:
        print(f"  ✗ tesseract error on {image_path}: {type(e).__name__}: {e}")
        return False


def convert_pdf_to_markdown(pdf_path: str, doc_dir: Path, md_dir: Path) -> bool:
    """Convert PDF to text using pdftotext, then save as markdown"""
    
    full_path = doc_dir / pdf_path.lstrip('./')
    
    if not full_path.exists():
        print(f"  ⚠ PDF not found: {pdf_path}")
        return False
    
    # Create output filename
    output_filename = f"{Path(pdf_path).stem}.md"
    output_path = md_dir / output_filename
    
    if output_path.exists():
        print(f"  ✓ Already converted: {output_filename}")
        return True
    
    try:
        # Use pdftotext to extract text from PDF
        result = subprocess.run(
            ['pdftotext', str(full_path), '-'],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode != 0:
            stderr_msg = result.stderr.strip() if result.stderr else "Unknown error"
            print(f"  ✗ Failed to convert {pdf_path}")
            print(f"     pdftotext error: {stderr_msg[:150]}")
            return False
        
        if not result.stdout or len(result.stdout.strip()) == 0:
            print(f"  ✗ Failed to convert {pdf_path}: PDF extraction returned empty text")
            return False
        
        # Save as markdown with header
        md_content = f"# {Path(pdf_path).stem}\n\nExtracted from PDF: {Path(pdf_path).name}\n\n---\n\n{result.stdout}"
        output_path.write_text(md_content, encoding='utf-8')
        print(f"  ✓ Converted: {output_filename}")
        return True
            
    except subprocess.TimeoutExpired:
        print(f"  ✗ pdftotext timeout (120s) on {pdf_path}")
        return False
    except FileNotFoundError:
        print(f"  ✗ pdftotext not found - install with: brew install poppler")
        return False
    except Exception as e:
        print(f"  ✗ pdftotext error on {pdf_path}: {type(e).__name__}: {e}")
        return False


def convert_docx_to_markdown(docx_path: str, doc_dir: Path, md_dir: Path) -> bool:
    """Convert DOCX to markdown using pandoc"""
    
    full_path = doc_dir / docx_path.lstrip('./')
    
    if not full_path.exists():
        print(f"  ⚠ DOCX not found: {docx_path}")
        return False
    
    # Create output filename
    output_filename = f"{Path(docx_path).stem}.md"
    output_path = md_dir / output_filename
    
    if output_path.exists():
        print(f"  ✓ Already converted: {output_filename}")
        return True
    
    try:
        # Use pandoc to convert DOCX to markdown
        result = subprocess.run(
            ['pandoc', str(full_path), '-t', 'markdown', '-o', str(output_path)],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode != 0:
            stderr_msg = result.stderr.strip() if result.stderr else "Unknown error"
            print(f"  ✗ Failed to convert {docx_path}")
            print(f"     pandoc error: {stderr_msg[:150]}")
            return False
        
        if not output_path.exists():
            print(f"  ✗ Failed to convert {docx_path}: Output file not created")
            return False
        
        print(f"  ✓ Converted: {output_filename}")
        return True
            
    except subprocess.TimeoutExpired:
        print(f"  ✗ pandoc timeout (120s) on {docx_path}")
        return False
    except FileNotFoundError:
        print(f"  ✗ pandoc not found - install with: brew install pandoc")
        return False
    except Exception as e:
        print(f"  ✗ pandoc error on {docx_path}: {type(e).__name__}: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Convert images to text")
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
    
    files_by_type = find_convertible_files(all_files, doc_dir)
    images = files_by_type['images']
    pdfs = files_by_type['pdfs']
    docx_files = files_by_type['docx']
    
    total_convertible = len(images) + len(pdfs) + len(docx_files)
    
    if not total_convertible:
        print("No images, PDFs, or DOCX files to convert")
        return 0
    
    print(f"\n==> Converting documents to text/markdown...\n")
    
    converted = 0
    
    # Convert images
    if images:
        print(f"Images ({len(images)}):")
        for image_path in images:
            if convert_image_to_text(image_path, doc_dir, md_dir):
                converted += 1
        print()
    
    # Convert PDFs
    if pdfs:
        print(f"PDFs ({len(pdfs)}):")
        for pdf_path in pdfs:
            if convert_pdf_to_markdown(pdf_path, doc_dir, md_dir):
                converted += 1
        print()
    
    # Convert DOCX files
    if docx_files:
        print(f"DOCX files ({len(docx_files)}):")
        for docx_path in docx_files:
            if convert_docx_to_markdown(docx_path, doc_dir, md_dir):
                converted += 1
        print()
    
    print(f"✓ {converted}/{total_convertible} files converted\n")
    
    print("Next step:")
    print("  Run: dms summarize")
    
    # Prompt to continue
    choice = input(f"\nStart 'dms summarize' now? [y/N]: ").strip().lower()
    if choice == 'y':
        result = subprocess.run(['dms', 'summarize'])
        return result.returncode
    
    return 0

if __name__ == "__main__":
    exit(main())
