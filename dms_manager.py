#!/usr/bin/env python3
"""
DMS_manager.py - Document Management System Wrapper

Main CLI for managing Doc/ directories across repos.
Orchestrates scanning, image processing, AI summarization, and index updates.

Usage:
  dms scan              # Find new/changed files
  dms process-images    # Convert images to text
  dms summarize         # Generate AI summaries (dry-run by default)
  dms review            # Interactive approval
  dms apply             # Write approved changes to index.html
  dms auto              # Run full workflow (scan → process → summarize → review → apply)
  dms init              # Create new index.html for a fresh Doc/ directory
  dms status            # Show current state
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import json
import subprocess

# Expected structure when run from repo root:
# ./Doc/
# ./Doc/index.html (or to be created)
# ./Doc/md_outputs/

CONFIG_NAME = "dms_config.json"

def find_scripts_dir() -> Path:
    """Locate the Scripts directory (should be on PATH or known location)"""
    # Try common location first
    common = Path.home() / "Documents" / "MyWebsiteGIT" / "Scripts"
    if common.exists():
        return common
    
    # Try to find via PATH
    import shutil
    test_script = shutil.which("DMS_scan.py")
    if test_script:
        return Path(test_script).parent
    
    print("ERROR: Cannot locate Scripts directory with DMS tools.", file=sys.stderr)
    print("Expected: ~/Documents/MyWebsiteGIT/Scripts", file=sys.stderr)
    sys.exit(1)

def load_config(scripts_dir: Path) -> dict:
    """Load configuration from Scripts/dms_config.json"""
    config_path = scripts_dir / CONFIG_NAME
    if not config_path.exists():
        # Create default config
        default = {
            "ollama_model": "qwen2.5-coder:14b",
            "ollama_host": "http://localhost:11434",
            "summary_max_words": 50,
            "temperature": 0.3,
            "enable_vision": False
        }
        config_path.write_text(json.dumps(default, indent=2), encoding='utf-8')
        print(f"Created default config at {config_path}")
        return default
    
    return json.loads(config_path.read_text(encoding='utf-8'))

def run_dms_script(script_name: str, args: list[str], scripts_dir: Path) -> int:
    """Execute a DMS script in the Scripts directory"""
    script_path = scripts_dir / script_name
    if not script_path.exists():
        print(f"ERROR: Script not found: {script_path}", file=sys.stderr)
        return 1
    
    cmd = [sys.executable, str(script_path)] + args
    result = subprocess.run(cmd)
    return result.returncode

def cmd_scan(args, scripts_dir: Path, config: dict):
    """Scan Doc/ for new or changed files"""
    print("==> Scanning Doc/ directory...")
    return run_dms_script("DMS_scan.py", ["--doc", "Doc", "--index", "Doc/index.html"], scripts_dir)

def cmd_process_images(args, scripts_dir: Path, config: dict):
    """Convert images to text descriptions"""
    print("==> Processing images...")
    return run_dms_script("DMS_image_to_text.py", ["--doc", "Doc", "--md", "Doc/md_outputs"], scripts_dir)

def cmd_summarize(args, scripts_dir: Path, config: dict):
    """Generate AI summaries via Ollama"""
    print("==> Generating AI summaries...")
    dry_run = ["--dry-run"] if args.dry_run else []
    model = ["--model", args.model] if args.model else ["--model", config.get("ollama_model", "qwen2.5-coder:14b")]
    return run_dms_script("DMS_summarize.py", 
                         ["--doc", "Doc", "--index", "Doc/index.html"] + dry_run + model, 
                         scripts_dir)

def cmd_review(args, scripts_dir: Path, config: dict):
    """Interactive review of proposed changes"""
    print("==> Starting interactive review...")
    return run_dms_script("DMS_review.py", ["--index", "Doc/index.html"], scripts_dir)

def cmd_apply(args, scripts_dir: Path, config: dict):
    """Apply approved changes to index.html"""
    print("==> Applying changes to index.html...")
    return run_dms_script("DMS_apply.py", ["--index", "Doc/index.html"], scripts_dir)

def cmd_auto(args, scripts_dir: Path, config: dict):
    """Run full workflow"""
    print("==> Running full DMS workflow...\n")
    
    steps = [
        ("Scan", lambda: cmd_scan(args, scripts_dir, config)),
        ("Process Images", lambda: cmd_process_images(args, scripts_dir, config)),
        ("Summarize", lambda: cmd_summarize(args, scripts_dir, config)),
        ("Review", lambda: cmd_review(args, scripts_dir, config)),
        ("Apply", lambda: cmd_apply(args, scripts_dir, config))
    ]
    
    for step_name, step_fn in steps:
        print(f"\n{'='*60}")
        print(f"Step: {step_name}")
        print('='*60)
        rc = step_fn()
        if rc != 0:
            print(f"\nERROR: {step_name} failed with code {rc}", file=sys.stderr)
            choice = input("Continue anyway? [y/N]: ").strip().lower()
            if choice != 'y':
                print("Workflow aborted.")
                return rc
    
    print("\n" + "="*60)
    print("DMS workflow complete!")
    print("="*60)
    return 0

def cmd_init(args, scripts_dir: Path, config: dict):
    """Initialize new index.html for a fresh Doc/ directory"""
    print("==> Initializing new Doc/index.html...")
    return run_dms_script("DMS_init.py", ["--doc", "Doc", "--index", "Doc/index.html"], scripts_dir)

def cmd_status(args, scripts_dir: Path, config: dict):
    """Show current DMS state"""
    print("==> Checking DMS status...")
    return run_dms_script("DMS_scan.py", ["--doc", "Doc", "--index", "Doc/index.html", "--status-only"], scripts_dir)

def main():
    parser = argparse.ArgumentParser(
        prog="dms",
        description="Document Management System - Manage Doc/ directories with AI summaries"
    )
    
    subparsers = parser.add_subparsers(dest="command", help="Command to run")
    
    # scan
    subparsers.add_parser("scan", help="Scan for new/changed files")
    
    # process-images
    subparsers.add_parser("process-images", help="Convert images to text")
    
    # summarize
    p_sum = subparsers.add_parser("summarize", help="Generate AI summaries")
    p_sum.add_argument("--dry-run", action="store_true", help="Show proposed summaries without saving")
    p_sum.add_argument("--model", help="Override Ollama model (e.g., qwen2.5-coder:7b)")
    
    # review
    subparsers.add_parser("review", help="Interactive review of changes")
    
    # apply
    subparsers.add_parser("apply", help="Apply approved changes to index.html")
    
    # auto
    subparsers.add_parser("auto", help="Run full workflow (scan → process → summarize → review → apply)")
    
    # init
    subparsers.add_parser("init", help="Create new index.html for fresh Doc/ directory")
    
    # status
    subparsers.add_parser("status", help="Show current DMS state")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 0
    
    # Check we're in a repo root with Doc/
    doc_dir = Path("Doc")
    if not doc_dir.exists() and args.command != "init":
        print("ERROR: No Doc/ directory found in current directory.", file=sys.stderr)
        print("Please run from a repository root, or use 'dms init' to create one.", file=sys.stderr)
        return 1
    
    scripts_dir = find_scripts_dir()
    config = load_config(scripts_dir)
    
    commands = {
        "scan": cmd_scan,
        "process-images": cmd_process_images,
        "summarize": cmd_summarize,
        "review": cmd_review,
        "apply": cmd_apply,
        "auto": cmd_auto,
        "init": cmd_init,
        "status": cmd_status
    }
    
    return commands[args.command](args, scripts_dir, config)

if __name__ == "__main__":
    sys.exit(main())
