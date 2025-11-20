#!/usr/bin/env python3
"""
DMS Interactive Menu System
Main entry point for Document Management System
"""
import sys
import subprocess
from pathlib import Path

def run_cmd(cmd_list, description=""):
    """Run a DMS command"""
    if description:
        print(f"\n{'='*60}")
        print(f"→ {description}")
        print('='*60 + "\n")
    result = subprocess.run(cmd_list)
    return result.returncode

def check_system():
    """Run system diagnostics"""
    print("\n" + "="*70)
    print("SYSTEM DIAGNOSTICS")
    print("="*70 + "\n")
    
    # Check Python
    print(f"✓ Python {sys.version.split()[0]}")
    
    # Check git
    try:
        result = subprocess.run(['git', '--version'], capture_output=True, text=True, timeout=5)
        print(f"✓ {result.stdout.strip()}")
    except:
        print("✗ Git not found")
    
    # Check Ollama
    try:
        result = subprocess.run(['which', 'ollama'], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            print(f"✓ Ollama found at {result.stdout.strip()}")
        else:
            print("✗ Ollama not found in PATH")
    except:
        print("✗ Could not check for Ollama")
    
    # Check tesseract
    try:
        result = subprocess.run(['which', 'tesseract'], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            print(f"✓ Tesseract found (OCR support)")
        else:
            print("⚠ Tesseract not found (OCR will not work)")
    except:
        print("⚠ Could not check for Tesseract")
    
    # Check current dir
    cwd = Path.cwd()
    if (cwd / '.git').exists():
        print(f"✓ Git repo: {cwd}")
    else:
        print(f"⚠ Not in git repo: {cwd}")
    
    if (cwd / 'Doc').exists():
        print(f"✓ Doc/ directory found")
        state_file = cwd / 'Doc' / '.dms_state.json'
        if state_file.exists():
            print(f"✓ State file exists")
        else:
            print(f"⚠ No .dms_state.json (run init to create)")
    else:
        print(f"⚠ No Doc/ directory found")
    
    print("\n" + "="*70 + "\n")

def show_menu():
    """Display the main menu"""
    print("\n" + "="*70)
    print(" "*18 + "DMS - Document Management System")
    print("="*70)
    
    print("\nStandard Workflow:")
    print("  1 / scan          Scan for new/changed files")
    print("  2 / image-to-text Convert images to text")
    print("  3 / summarize     Generate AI summaries")
    print("  4 / review        Interactive review of changes")
    print("  5 / apply         Apply approved changes to index.html")
    
    print("\nDIAGNOSTIC")
    print("  6 / c             Check system (Ollama / Python / paths)")
    print("  7 / l             View logs / last run output")
    
    print("\nSETUP NEW DMS")
    print("  8 / i             Initialize Doc/ & .dms_state.json")
    print("  9 / s             Configure Ollama & models")
    
    print("\nAUX COMMANDS")
    print("  o                 Convert images to text (OCR)")
    print("  x                 Cleanup missing files from state")
    print("  d                 Delete entries from state")
    
    print("\nOther:")
    print("  status            Show current DMS state")
    print("  cleanup           Cleanup missing files")
    print("  render            Regenerate index.html")
    print("  init              Initialize new DMS")
    print("  delete-entry      Delete entries from state")
    
    print("\nOther Commands:")
    print("  h                 Help / keyboard shortcuts")
    print("  menu              Show this menu again")
    print("  q                 Quit")
    
    print("="*70)

def show_help():
    """Display help text"""
    print("\n" + "="*70)
    print("DMS - Document Management System Help")
    print("="*70)
    print("""
STANDARD WORKFLOW:
  1. dms scan              - Find new/changed files in Doc/
  2. dms image-to-text     - Convert images to text (OCR)
  3. dms summarize         - Generate AI summaries for each file
  4. dms review            - Review and approve summaries
  5. dms apply             - Apply changes to .dms_state.json and index.html

NUMERIC SHORTCUTS:
  1-5: Standard workflow commands (in order)
  6/c: System check
  7/l: View logs
  8/i: Initialize new DMS
  9/s: Configure Ollama
  o: Image-to-text
  x: Cleanup
  d: Delete entries

EXPECTED WORKFLOW:
  The typical process is to go through the standard workflow steps in order.
  After scan and summarize, use review to approve changes before applying.

QUICK TIPS:
  - Run '1' (scan) first to see what changed
  - Run '3' (summarize) to generate AI summaries
  - Run '4' (review) to edit summaries before they're applied
  - Run '5' (apply) to make the changes permanent
  - Run 'status' to check current state

FILES TRACKED:
  .dms_state.json              - Current state of all documents
  .dms_scan.json               - Last scan results (new/changed/missing)
  .dms_pending_summaries.json  - Pending AI summaries
  .dms_pending_approved.json   - Approved summaries waiting to be applied
  index.html                   - Generated HTML index with all documents
""")
    print("="*70 + "\n")

def main():
    """Main menu loop"""
    while True:
        show_menu()
        
        choice = input("\nEnter command or number: ").strip().lower()
        
        if choice in ['q', 'quit', 'exit']:
            print("\nGoodbye!")
            return 0
        
        elif choice in ['menu', '']:
            continue
        
        elif choice in ['h', 'help']:
            show_help()
            input("Press Enter to continue...")
        
        # Standard workflow by number
        elif choice in ['1', 'scan']:
            run_cmd(['dms', 'scan'], "Scan for new/changed files")
            input("\nPress Enter to continue...")
        
        elif choice in ['2', 'image-to-text']:
            run_cmd(['dms', 'image-to-text'], "Convert images to text")
            input("\nPress Enter to continue...")
        
        elif choice in ['3', 'summarize']:
            run_cmd(['dms', 'summarize'], "Generate AI summaries")
            input("\nPress Enter to continue...")
        
        elif choice in ['4', 'review']:
            run_cmd(['dms', 'review'], "Interactive review of changes")
            input("\nPress Enter to continue...")
        
        elif choice in ['5', 'apply']:
            run_cmd(['dms', 'apply'], "Apply approved changes to index.html")
            input("\nPress Enter to continue...")
        
        # Diagnostic
        elif choice in ['6', 'c']:
            check_system()
            input("Press Enter to continue...")
        
        elif choice in ['7', 'l']:
            print("\n" + "="*60)
            print("LAST RUN LOGS")
            print("="*60 + "\n")
            print("(Log viewing not yet implemented)")
            print("Check Doc/ for .dms_*.json files for latest state\n")
            print("="*60 + "\n")
            input("Press Enter to continue...")
        
        # Setup new DMS
        elif choice in ['8', 'i']:
            run_cmd(['dms', 'init'], "Initialize new DMS")
            input("\nPress Enter to continue...")
        
        elif choice in ['9', 's']:
            print("\n" + "="*60)
            print("CONFIGURE OLLAMA")
            print("="*60)
            print("""
Edit dms_config.json to change:
  - ollama_model: AI model to use
  - ollama_host: Ollama server URL
  - temperature: AI creativity (0.0-1.0)
  - summary_max_words: Target summary length

Common models:
  phi3:mini (small, fast)
  qwen2.5-coder:7b (better quality)
  mistral:7b (balanced)

Current config: ~/Documents/MyWebsiteGIT/Scripts/dms_config.json
""")
            print("="*60 + "\n")
            input("Press Enter to continue...")
        
        # Aux commands
        elif choice in ['o']:
            run_cmd(['dms', 'image-to-text'], "Convert images to text (OCR)")
            input("\nPress Enter to continue...")
        
        elif choice in ['x']:
            run_cmd(['dms', 'cleanup'], "Cleanup missing files from state")
            input("\nPress Enter to continue...")
        
        elif choice == 'd':
            run_cmd(['dms', 'delete-entry'], "Delete entries from state")
            input("\nPress Enter to continue...")
        
        # Full command names
        elif choice == 'status':
            run_cmd(['dms', 'status'], "Show current DMS state")
            input("\nPress Enter to continue...")
        
        elif choice == 'cleanup':
            run_cmd(['dms', 'cleanup'], "Cleanup missing files")
            input("\nPress Enter to continue...")
        
        elif choice == 'render':
            run_cmd(['dms', 'render'], "Regenerate index.html")
            input("\nPress Enter to continue...")
        
        elif choice == 'delete-entry':
            run_cmd(['dms', 'delete-entry'], "Delete entries from state")
            input("\nPress Enter to continue...")
        
        else:
            print(f"\n✗ Unknown command: {choice}")
            print("Type 'h' for help or 'menu' to refresh")
            input("\nPress Enter to continue...")

if __name__ == "__main__":
    exit(main())
