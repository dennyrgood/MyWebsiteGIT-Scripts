#!/usr/bin/env python3
"""
dms_summarize.py - Generate AI summaries and category suggestions for new/changed files

Reads .dms_scan.json to find new/changed files.
Generates summaries AND suggests categories via Ollama.
Outputs: .dms_pending_summaries.json (awaiting user approval)

Does NOT update .dms_state.json (that happens in apply).
"""
import argparse
import sys
import json
import requests
from pathlib import Path
from datetime import datetime

def load_config() -> dict:
    """Load DMS config"""
    config_path = Path(__file__).parent.parent / "dms_config.json"
    if not config_path.exists():
        return {
            "ollama_model": "phi3:mini",
            "ollama_host": "https://ollama.ldmathes.cc",
            "summary_max_words": 50,
            "temperature": 0.3
        }
    return json.loads(config_path.read_text(encoding='utf-8'))

def load_scan_results(scan_path: Path) -> dict:
    """Load .dms_scan.json"""
    if not scan_path.exists():
        return {"new_files": [], "changed_files": []}
    return json.loads(scan_path.read_text(encoding='utf-8'))

def load_state(state_path: Path) -> dict:
    """Load .dms_state.json to get existing categories"""
    if not state_path.exists():
        return {"categories": [], "documents": {}}
    try:
        return json.loads(state_path.read_text(encoding='utf-8'))
    except:
        return {"categories": [], "documents": {}}

def read_file_content(file_path: Path) -> str:
    """Read file content safely"""
    try:
        if file_path.suffix in {'.txt', '.md', '.html', '.py', '.js', '.json'}:
            return file_path.read_text(encoding='utf-8', errors='replace')[:2000]
        return f"[Binary file: {file_path.name}]"
    except Exception as e:
        return f"[Error reading file: {e}]"

def find_text_conversion(file_path: str, doc_dir: Path) -> str:
    """Check if file has a text version in md_outputs/ (for images or PDFs)"""
    file_name = Path(file_path).name
    file_stem = Path(file_path).stem
    
    # Try exact match first: IMG_4664.jpeg.txt or document.pdf.txt
    text_file = doc_dir / "md_outputs" / (file_name + ".txt")
    if text_file.exists():
        return text_file.read_text(encoding='utf-8', errors='replace')[:2000]
    
    # Try stem only: IMG_4664.txt or document.txt
    text_file = doc_dir / "md_outputs" / (file_stem + ".txt")
    if text_file.exists():
        return text_file.read_text(encoding='utf-8', errors='replace')[:2000]
    
    return None

def check_ollama(host: str, model: str) -> bool:
    """Check if Ollama is running and model available"""
    try:
        resp = requests.get(f"{host}/api/tags", timeout=5)
        if resp.status_code != 200:
            return False
        tags = resp.json().get('models', [])
        return any(model in t.get('name', '') for t in tags)
    except:
        return False

def generate_summary_and_category(file_content: str, file_name: str, existing_categories: list, config: dict) -> dict:
    """Call Ollama to generate both summary AND category suggestion"""
    try:
        categories_str = ", ".join(existing_categories) if existing_categories else "Guides, Models, Scripts, Workflows, QuickRefs"
        
        prompt = f"""Analyze this document and provide a summary and category assignment.

Filename: {file_name}

Document content:
{file_content}

Task:
1. Write a brief technical summary (1-2 sentences, max 50 words) describing what this document contains and its purpose.
2. Choose the BEST category from this list: {categories_str}
   - Only propose a NEW category if none of the existing categories are appropriate.
   - New categories should be justified and follow the naming pattern of existing ones.

Respond ONLY with valid JSON in this exact format:
{{
  "summary": "your concise technical summary here (max 50 words)",
  "category": "chosen category name",
  "is_new_category": false
}}

If proposing a new category, set is_new_category to true."""

        resp = requests.post(
            f"{config['ollama_host']}/api/generate",
            json={
                "model": config['ollama_model'],
                "prompt": prompt,
                "temperature": 0.2,  # Lower temperature for more consistent output
                "stream": False
            },
            timeout=120
        )
        
        if resp.status_code != 200:
            return None
        
        response_text = resp.json().get('response', '').strip()
        
        # Try to parse JSON from response
        json_text = response_text
        if '```json' in response_text:
            json_text = response_text.split('```json')[1].split('```')[0].strip()
        elif '```' in response_text:
            json_text = response_text.split('```')[1].split('```')[0].strip()
        
        parsed = json.loads(json_text)
        
        return {
            "summary": parsed.get('summary', '').strip(),
            "category": parsed.get('category', 'Guides'),
            "is_new_category": parsed.get('is_new_category', False),
            "error": False
        }
        
    except json.JSONDecodeError as e:
        print(f"  ⚠ WARNING: Failed to parse AI response as JSON", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  ✗ Error: {e}", file=sys.stderr)
        return None

def truncate_summary(summary: str, max_words: int = 50) -> tuple:
    """Truncate summary to max_words and return (summary, was_truncated)"""
    words = summary.split()
    if len(words) <= max_words:
        return summary, False
    
    truncated = ' '.join(words[:max_words]) + '…'
    return truncated, True

def find_image_for_text_file(text_file_path: str, doc_dir: Path) -> str:
    """Find the original image file for a text file created by OCR"""
    # text_file format: ./md_outputs/IMG_4666.jpeg.txt or ./md_outputs/IMG_4666 copy.txt
    # original image: ./IMG_4666.jpeg or ./IMG_4666 copy.jpeg
    
    text_name = Path(text_file_path).name
    
    if not text_name.endswith('.txt'):
        return None
    
    # Remove .txt to get the potential original name
    without_txt = text_name[:-4]  # e.g., "IMG_4666.jpeg" or "IMG_4666 copy"
    
    # Try exact match first (for IMG_4666.jpeg.txt -> IMG_4666.jpeg)
    potential_path = doc_dir / without_txt
    if potential_path.exists():
        return f"./{without_txt}"
    
    # If that didn't work, look for files that start with this name
    # (for IMG_4666 copy.txt -> IMG_4666 copy.jpeg)
    image_exts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'}
    for ext in image_exts:
        potential_path = doc_dir / (without_txt + ext)
        if potential_path.exists():
            return f"./{without_txt + ext}"
    
    return None

def main():
    parser = argparse.ArgumentParser(description="Generate AI summaries for new files")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--model", help="Override Ollama model")
    parser.add_argument("--dry-run", action="store_true", help="Show what would happen, don't write")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    scan_path = doc_dir / ".dms_scan.json"
    state_path = doc_dir / ".dms_state.json"
    pending_path = doc_dir / ".dms_pending_summaries.json"
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    # Load config
    config = load_config()
    if args.model:
        config['ollama_model'] = args.model
    
    print("==> Generating AI summaries...\n")
    print(f"Using model: {config['ollama_model']}")
    print(f"Ollama host: {config['ollama_host']}\n")
    
    # Check Ollama is available
    if not check_ollama(config['ollama_host'], config['ollama_model']):
        print(f"ERROR: Cannot connect to Ollama at {config['ollama_host']}")
        print(f"Make sure Ollama is running (ollama serve)")
        return 1
    
    # Load state to get existing categories
    state = load_state(state_path)
    existing_categories = state.get('categories', [])
    
    # Load scan results
    scan_results = load_scan_results(scan_path)
    files_to_summarize = scan_results.get('new_files', []) + scan_results.get('changed_files', [])
    
    if not files_to_summarize:
        print("No files to summarize.")
        return 0
    
    # Check if we have partial progress - resume from there
    already_done = set()
    if pending_path.exists():
        print(f"Found partial progress in {pending_path}")
        try:
            existing = json.loads(pending_path.read_text(encoding='utf-8'))
            already_done = {s['file']['path'] for s in existing.get('summaries', [])}
            print(f"✓ {len(already_done)} already summarized, resuming from there\n")
            summaries = existing.get('summaries', [])
        except:
            summaries = []
    else:
        summaries = []
    
    # Filter out already-done files
    files_to_process = [f for f in files_to_summarize if f.get('path') not in already_done]
    
    print(f"Summarizing {len(files_to_process)}/{len(files_to_summarize)} file(s)...\n")
    
    for i, file_info in enumerate(files_to_process, 1):
        file_path = file_info.get('path', '')
        full_path = doc_dir / file_path.lstrip('./')
        
        print(f"[{len(already_done) + i}/{len(files_to_summarize)}] {Path(file_path).name}")
        
        if not full_path.exists():
            print(f"  ⚠ File not found\n")
            continue
        
        # Check if this is an image or PDF and we have a text conversion
        content = None
        text_conversion_path = None
        file_ext = full_path.suffix.lower()
        
        if file_ext in {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.pdf'}:
            converted_text = find_text_conversion(file_path, doc_dir)
            if converted_text:
                content = converted_text
                # Try to find which text file was actually used
                file_stem = full_path.stem
                text_file_stem = doc_dir / "md_outputs" / (file_stem + ".txt")
                text_file_full = doc_dir / "md_outputs" / (full_path.name + ".txt")
                
                if text_file_stem.exists():
                    text_conversion_path = f"./md_outputs/{file_stem}.txt"
                elif text_file_full.exists():
                    text_conversion_path = f"./md_outputs/{full_path.name}.txt"
                
                conversion_type = "PDF text" if file_ext == '.pdf' else "OCR text"
                print(f"  ℹ Using {conversion_type} conversion")
        
        # If no text conversion, read file content normally
        if content is None:
            content = read_file_content(full_path)
        
        # Generate summary AND get category suggestion
        result = generate_summary_and_category(content, Path(file_path).name, existing_categories, config)
        
        if result and not result.get('error'):
            summary = result['summary']
            category = result['category']
            is_new_cat = result['is_new_category']
            
            # Truncate if needed
            word_count = len(summary.split())
            truncated_summary, was_truncated = truncate_summary(summary, 50)
            
            if was_truncated:
                print(f"  ⚠ WARNING: Summary exceeded 50 words ({word_count}), truncated")
            
            if is_new_cat:
                print(f"  ℹ New category suggested: {category}")
            
            print(f"  Summary: {truncated_summary[:60]}...")
            print(f"  Category: {category}\n")
            
            # Check if this text file has a corresponding image
            file_entry = {
                "path": file_path,
                "hash": file_info.get('hash', ''),
                "size": file_info.get('size', 0)
            }
            
            # If we used a text conversion for an image, record that
            if text_conversion_path:
                file_entry['readable_version'] = text_conversion_path
            # If this is a text file in md_outputs, check for original image
            elif './md_outputs/' in file_path and file_path.endswith('.txt'):
                image_path = find_image_for_text_file(file_path, doc_dir)
                if image_path:
                    file_entry['readable_version'] = image_path
            
            summaries.append({
                "file": file_entry,
                "summary": truncated_summary,
                "category": category,
                "is_new_category": is_new_cat,
                "title": Path(file_path).stem,
                "timestamp": datetime.now().isoformat()
            })
        else:
            print(f"  ✗ Failed to generate summary\n")
    
    if args.dry_run:
        print(f"DRY RUN: Would save {len(summaries)} summary/summaries")
        return 0
    
    # Save pending summaries
    pending_data = {
        "timestamp": datetime.now().isoformat(),
        "summaries": summaries
    }
    
    pending_path.write_text(json.dumps(pending_data, indent=2), encoding='utf-8')
    
    print(f"\n✓ Generated {len(summaries)} summary/summaries")
    print(f"✓ Saved to {pending_path}")
    print(f"\nNext step:")
    print(f"  Run: dms review")
    
    return 0

if __name__ == "__main__":
    exit(main())
