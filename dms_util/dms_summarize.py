#!/usr/bin/env python3
"""
dms_summarize.py - Generate AI summaries and category suggestions via Ollama

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
            "ollama_host": "http://localhost:11434",
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
    """Read file content, truncate if too large"""
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
    config: dict,
    retry_count: int = 0,
    max_retries: int = 3
) -> dict:
    """Call Ollama to generate summary and suggest category (with retries)"""
    
    file_path = Path(file_info['abs_path'])
    file_name = file_path.name
    file_ext = file_info['ext']
    
    # Read content
    content = read_file_content(file_path, max_chars=4000)
    
    # Build prompt
    categories_str = ", ".join(existing_categories)
    
    prompt = f"""Analyze this document and provide a summary and category assignment.

Filename: {file_name}

Document content:
{content}

Task:
1. Write a brief technical summary (1-2 sentences, max 50 words) describing what this document contains and its purpose.
2. Choose the BEST category from this list: {categories_str}
   - Only propose a NEW category if none of the existing categories are appropriate.
   - New categories should be justified and follow the naming pattern of existing ones.

Respond ONLY with valid JSON in this exact format:
{{
  "summary": "your concise technical summary here",
  "category": "chosen category name",
  "is_new_category": false
}}

If proposing a new category, set is_new_category to true."""

    # Call Ollama
    try:
        resp = requests.post(
            f"{config['ollama_host']}/api/generate",
            json={
                "model": config['ollama_model'],
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": config.get('temperature', 0.3)
                }
            },
            timeout=120
        )
        
        if resp.status_code != 200:
            return {
                "summary": f"[AI generation failed: {resp.status_code}]",
                "category": existing_categories[0] if existing_categories else "Uncategorized",
                "is_new_category": False,
                "error": True
            }
        
        result = resp.json()
        response_text = result.get('response', '')
        
        # Try to parse JSON from response
        # Sometimes models wrap JSON in markdown code blocks
        json_text = response_text
        if '```json' in response_text:
            json_text = response_text.split('```json')[1].split('```')[0].strip()
        elif '```' in response_text:
            json_text = response_text.split('```')[1].split('```')[0].strip()
        
        parsed = json.loads(json_text)
        
        # Validate category
        suggested_cat = parsed.get('category', 'Uncategorized')
        is_new = suggested_cat not in existing_categories
        
        return {
            "summary": parsed.get('summary', '').strip(),
            "category": suggested_cat,
            "is_new_category": is_new,
            "error": False
        }
        
    except json.JSONDecodeError as e:
        if retry_count < max_retries:
            print(f"  ⚠ JSON parse failed (attempt {retry_count + 1}/{max_retries})", file=sys.stderr)
            choice = input("  Retry? [y/N]: ").strip().lower()
            if choice == 'y':
                import time
                time.sleep(1)  # Brief pause before retry
                return generate_summary_and_category(file_info, doc_dir, existing_categories, config, retry_count + 1, max_retries)
        
        print(f"WARNING: Failed to parse AI response: {e}", file=sys.stderr)
        return {
            "summary": "[AI response parsing failed - please enter manually]",
            "category": existing_categories[0] if existing_categories else "Uncategorized",
            "is_new_category": False,
            "error": True
        }
    except Exception as e:
        error_msg = str(e)
        if "timeout" in error_msg.lower() or "connection" in error_msg.lower():
            # Network/timeout error - worth retrying
            if retry_count < max_retries:
                print(f"  ⚠ Network error (attempt {retry_count + 1}/{max_retries}): {e}", file=sys.stderr)
                choice = input("  Retry? [y/N]: ").strip().lower()
                if choice == 'y':
                    import time
                    time.sleep(2)  # Longer pause for network issues
                    return generate_summary_and_category(file_info, doc_dir, existing_categories, config, retry_count + 1, max_retries)
        else:
            # Other error - probably not worth retrying
            print(f"WARNING: AI generation failed: {e}", file=sys.stderr)
        
        return {
            "summary": "[AI generation error - please enter manually]",
            "category": existing_categories[0] if existing_categories else "Uncategorized",
            "is_new_category": False,
            "error": True
        }

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
