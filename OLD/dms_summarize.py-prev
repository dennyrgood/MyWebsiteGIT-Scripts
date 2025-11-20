#!/usr/bin/env python3
"""
DMS_summarize.py - Generate AI summaries and category suggestions via Ollama

Uses Ollama API to generate:
  - Brief technical summary (<50 words)
  - Suggested category (existing or new)

Considers filename in the prompt for context.
"""
from __future__ import annotations
import argparse
import sys
import json
import requests
from pathlib import Path
from datetime import datetime

def load_config() -> dict:
    """Load DMS config"""
    config_path = Path(__file__).parent / "dms_config.json"
    if not config_path.exists():
        return {
            "ollama_model": "qwen2.5-coder:1.5b",
            "ollama_host": "http://ollama.ldmathes.cc:11434",
            "summary_max_words": 50,
            "temperature": 0.3
        }
    return json.loads(config_path.read_text(encoding='utf-8'))

def check_ollama(host: str, model: str) -> bool:
    """Check if Ollama is running and model is available"""
    try:
        # Check server
        resp = requests.get(f"{host}/api/tags", timeout=5)
        if resp.status_code != 200:
            print(f"ERROR: Ollama server not responding at {host}", file=sys.stderr)
            return False
        
        # Check if model exists
        models = resp.json().get('models', [])
        model_names = [m['name'] for m in models]
        
        if model not in model_names:
            print(f"ERROR: Model '{model}' not found in Ollama", file=sys.stderr)
            print(f"Available models: {', '.join(model_names)}", file=sys.stderr)
            print(f"\nPull the model with: ollama pull {model}", file=sys.stderr)
            return False
        
        return True
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Cannot connect to Ollama at {host}: {e}", file=sys.stderr)
        print("Make sure Ollama is running (ollama serve)", file=sys.stderr)
        return False

def read_file_content(file_path: Path, max_chars: int = 4000) -> str:
    """
    Read content. If file is binary (image/docx), 
    look for the converted text file in md_outputs/ 
    """
    suffix = file_path.suffix.lower()
    binary_exts = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.docx', '.doc', '.pdf'}
    
    # Check if we need to redirect to the converted text file
    if suffix in binary_exts:
        # Logic from your image_to_text script: 
        # Doc/image.png -> Doc/md_outputs/image.png.txt
        converted_path = file_path.parent / "md_outputs" / (file_path.name + ".txt")
        
        if converted_path.exists():
            try:
                # Read the converted text instead of the binary
                content = converted_path.read_text(encoding='utf-8', errors='replace')
                return f"[Content extracted from {converted_path.name}]:\n\n{content}"
            except Exception as e:
                return f"[Error reading converted text file: {e}]"
        else:
            return f"[Binary file ({suffix}). No converted text found in md_outputs/]"

    # Standard reading for non-binary files
    try:
        content = file_path.read_text(encoding='utf-8', errors='replace')
        if len(content) > max_chars:
            content = content[:max_chars] + "\n\n[... truncated ...]"
        return content
    except Exception as e:
        return f"[Error reading file: {e}]"

def generate_summary_and_category(
    file_info: dict,
    doc_dir: Path,
    existing_categories: list[str],
    config: dict
) -> dict:
    """Call Ollama to generate summary and suggest category (with Regex Rescue)"""
    import re # Import re for the rescue mission

    file_path = Path(file_info['abs_path'])
    file_name = file_path.name

    # Read content (using the binary-safe reader you hopefully added)
    content = read_file_content(file_path)

    # Build prompt
    categories_str = ", ".join(existing_categories)

    prompt = f"""Analyze this document.
Filename: {file_name}
Content Snippet:
{content}

Instructions:
1. Write a 1-sentence Technical Summary.
2. Pick a Category from: {categories_str}

Format your response as JSON:
{{
  "summary": "your summary here",
  "category": "category name"
}}
"""

    # Call Ollama
    try:
        resp = requests.post(
            f"{config['ollama_host']}/api/generate",
            json={
                "model": config['ollama_model'],
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0.1}
            },
            timeout=120
        )
        
        if resp.status_code != 200:
            return {"summary": f"[Error {resp.status_code}]", "category": "Uncategorized", "is_new_category": False, "error": True}
        
        result = resp.json()
        response_text = result.get('response', '').strip()
        
        # --- STRATEGY 1: Try standard JSON ---
        try:
            # Clean markdown code blocks if present
            clean_json = response_text.replace("```json", "").replace("```", "").strip()
            parsed = json.loads(clean_json)
            return {
                "summary": parsed.get('summary', '').strip(),
                "category": parsed.get('category', 'Uncategorized'),
                "is_new_category": parsed.get('category') not in existing_categories,
                "error": False
            }
        except json.JSONDecodeError:
            pass # JSON failed, move to Strategy 2

        # --- STRATEGY 2: The "Regex Rescue" (For chatty models) ---
        # 1. Find the Summary
        # Looks for "Summary: text" or "### Summary\n text"
        summary_match = re.search(r'(?:Summary|### Technical Summary)[:\s\n]+(.*?)(?:\n\n|\n###|Category:|$)', response_text, re.IGNORECASE | re.DOTALL)
        extracted_summary = summary_match.group(1).strip() if summary_match else response_text[:100].replace('\n', ' ')

        # 2. Find the Category
        # Looks for "Category: name"
        cat_match = re.search(r'Category[:\s]+([a-zA-Z0-9_\-\s]+)', response_text, re.IGNORECASE)
        extracted_category = cat_match.group(1).strip() if cat_match else "Uncategorized"

        # Clean up if it grabbed too much
        if len(extracted_category) > 30: 
             # If category is huge, it probably failed to match. Default to Uncategorized.
             extracted_category = "Uncategorized"

        print(f"  (Recovered info from non-JSON response)", file=sys.stderr)
        
        return {
            "summary": extracted_summary,
            "category": extracted_category,
            "is_new_category": extracted_category not in existing_categories,
            "error": False
        }
        
    except Exception as e:
        print(f"WARNING: AI failed on {file_name}: {e}", file=sys.stderr)
        return {"summary": "[AI Error]", "category": "Uncategorized", "is_new_category": False, "error": True}

def extract_categories_from_state(doc_dir: Path) -> list[str]:
    """Extract categories from DMS_STATE in index.html"""
    index_path = doc_dir / "index.html"
    if not index_path.exists():
        return []
    
    content = index_path.read_text(encoding='utf-8', errors='replace')
    
    # Try DMS_STATE first
    import re
    state_pattern = re.compile(r'<!-- DMS_STATE\n(.*?)\n-->', re.DOTALL)
    match = state_pattern.search(content)
    
    if match:
        try:
            state = json.loads(match.group(1))
            return state.get('categories', [])
        except:
            pass
    
    # Fallback: parse from HTML
    cat_pattern = re.compile(r'data-category="([^"]+)"', re.IGNORECASE)
    categories = list(set(cat_pattern.findall(content)))
    return categories

def main():
    parser = argparse.ArgumentParser(description="Generate AI summaries and category suggestions")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--index", default="Doc/index.html", help="Path to index.html")
    parser.add_argument("--model", help="Override Ollama model")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be generated without saving")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    config = load_config()
    
    # Override model if specified
    if args.model:
        config['ollama_model'] = args.model
    
    print(f"Using model: {config['ollama_model']}")
    print(f"Ollama host: {config['ollama_host']}\n")
    
    # Check Ollama availability
    if not check_ollama(config['ollama_host'], config['ollama_model']):
        choice = input("\nOllama not available. Enter summaries manually? [y/N]: ").strip().lower()
        if choice != 'y':
            return 1
        manual_mode = True
    else:
        manual_mode = False
    
    # Load pending report
    pending_path = doc_dir / ".dms_pending.json"
    if not pending_path.exists():
        print("ERROR: No pending scan report found.", file=sys.stderr)
        print("Run 'dms scan' first.", file=sys.stderr)
        return 1
    
    pending_report = json.loads(pending_path.read_text(encoding='utf-8'))
    
    # Get files to process
    new_files = pending_report.get('new_files', [])
    changed_files = pending_report.get('changed_files', [])
    
    files_to_process = new_files + changed_files
    
    if not files_to_process:
        print("No files to summarize.")
        return 0
    
    # Get existing categories
    existing_categories = extract_categories_from_state(doc_dir)
    print(f"Existing categories: {', '.join(existing_categories)}\n")
    
    # Process each file
    summaries = []
    
    for i, file_info in enumerate(files_to_process, 1):
        print(f"[{i}/{len(files_to_process)}] Processing: {file_info['path']}")
        
        if manual_mode:
            # Manual entry
            print(f"  File: {Path(file_info['abs_path']).name}")
            summary = input("  Enter summary: ").strip()
            print(f"  Existing categories: {', '.join(existing_categories)}")
            category = input("  Enter category: ").strip()
            is_new = category not in existing_categories
        else:
            # AI generation
            result = generate_summary_and_category(
                file_info, doc_dir, existing_categories, config
            )
            
            summary = result['summary']
            category = result['category']
            is_new = result['is_new_category']
            
            print(f"  Summary: {summary}")
            print(f"  Category: {category} {'(NEW)' if is_new else ''}")
            
            if result.get('error'):
                # Allow manual override on error
                choice = input("  AI failed. Enter manually? [y/N]: ").strip().lower()
                if choice == 'y':
                    summary = input("  Enter summary: ").strip()
                    category = input("  Enter category: ").strip()
                    is_new = category not in existing_categories
        
        summaries.append({
            'file': file_info,
            'summary': summary,
            'category': category,
            'is_new_category': is_new
        })
        
        # Update existing categories list if new
        if is_new and category:
            existing_categories.append(category)
        
        print()
    
    # Save summaries to pending report
    pending_report['summaries'] = summaries
    pending_report['summarization_done'] = True
    
    if args.dry_run:
        print("Dry-run: Summary report:")
        print(json.dumps(summaries, indent=2))
        return 0
    
    pending_path.write_text(json.dumps(pending_report, indent=2), encoding='utf-8')
    print(f"✓ Summaries saved to {pending_path}")
    print(f"\nNext step: Run 'dms review' to approve/edit summaries")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
