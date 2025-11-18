#!/bin/bash

# =========================================================================
# Multi-Repository Git Sync Script (Updated for detailed status output)
# Syncs all Git repositories on their current branches, with clear logging.
# =========================================================================

# --- CONFIGURATION ---
USE_REBASE=true       # Set to true to use rebase instead of merge
VERIFY_COMMITS=true   # Set to false to skip pre-commit hooks
SHOW_COMMANDS=true    # Set to false to hide git command traces
DRY_RUN=false         # Set to true to see what would happen without doing it
SKIP_CLEAN_REPOS=true # Set to false to process all repos even if up-to-date

# --- SETUP ---
# SCRIPT_DIR is determined dynamically, but is NOT used to find the repos.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
#
# IMPORTANT MODIFICATION: 
# The REPO_ROOT_DIR is now a fixed path (relative to the user's home directory ~)
# This allows the script to be run from ~/bin or anywhere else.
REPO_ROOT_DIR="$HOME/Documents/MywebsiteGIT"
#
START_DIR=$(pwd)
ERROR_COUNT=0
SKIP_COUNT=0
TOTAL_PROCESSED=0

# --- HELPER FUNCTION: GET BRANCH STATUS ---
# Outputs a simple status string (e.g., "↑ 3 ahead, ↓ 1 behind" or "✓ Up to date")
get_branch_status() {
    local branch="$1"
    git fetch origin "$branch" --quiet 2>/dev/null
    
    # Check if upstream is set
    UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
    if [ -z "$UPSTREAM" ]; then
        echo "⚠️  No upstream set (will use -u on push)"
        return
    fi

    # Calculate ahead/behind
    AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")

    if [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -gt 0 ]; then
        echo "⚠️  ↑ $AHEAD ahead, ↓ $BEHIND behind"
    elif [ "$AHEAD" -gt 0 ]; then
        echo "↑ $AHEAD ahead (needs push)"
    elif [ "$BEHIND" -gt 0 ]; then
        echo "↓ $BEHIND behind (needs pull)"
    else
        echo "✓ Up to date"
    fi
}

# --- PARSE ARGUMENTS ---
COMMIT_MESSAGE=""

# First, check if first argument is not a flag (positional message)
if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
    COMMIT_MESSAGE="$1"
    shift
fi

# Then parse remaining flags
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            echo "🔍 DRY RUN MODE - No changes will be made"
            echo ""
            shift
            ;;
        --verbose)
            SHOW_COMMANDS=true
            shift
            ;;
        --all)
            SKIP_CLEAN_REPOS=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# --- COMMIT MESSAGE ---
echo "=========================================="
echo "          MULTI-REPO SYNC SETUP           "
echo "=========================================="

# Only prompt if message not provided via command line
if [ -z "$COMMIT_MESSAGE" ]; then
    echo "Enter commit message (or press Enter for default):"
    read -r COMMIT_MESSAGE
    COMMIT_MESSAGE=${COMMIT_MESSAGE:-"Auto-sync from local changes"}
fi

echo "Using message: \"$COMMIT_MESSAGE\""
echo "Root Directory: $REPO_ROOT_DIR"
echo "=========================================="
echo ""

# --- VALIDATE ROOT DIRECTORY ---
if [ ! -d "$REPO_ROOT_DIR" ]; then
    echo "=========================================="
    echo "✗ ERROR: Repository root directory not found." >&2
    echo "Please confirm $REPO_ROOT_DIR exists." >&2
    echo "=========================================="
    exit 1
fi


# --- FIND REPOSITORIES ---
REPOS=()
# Find all .git directories up to 3 levels deep, excluding .git at the root
# The filtering for *.bkup has been moved into the main loop for clarity and robustness.
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    if [[ ! "$REPO_PATH" =~ \.bkup|\.bak|_backup|_bak ]]; then
        REPOS+=("$REPO_PATH")
    fi
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

echo "Found ${#REPOS[@]} repositories to process."
echo ""

# --- PROCESS REPOSITORIES ---
for REPO_PATH in "${REPOS[@]}"; do
    REPO_NAME=$(basename "$REPO_PATH")
    REPO_FAILED=false
    
    cd "$REPO_PATH" || { 
        echo "=========================================="
        echo "✗ $REPO_NAME: ERROR - Cannot access directory" >&2
        echo "=========================================="
        ERROR_COUNT=$((ERROR_COUNT + 1))
        cd "$START_DIR"
        continue
    }

    echo "=========================================="
    echo "📂 $REPO_NAME"
    echo "=========================================="

    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
    
    # --- CHECK FOR DETACHED HEAD ---
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    
    if [ "$CURRENT_BRANCH" = "HEAD" ]; then
        echo "   ⚠️    Detached HEAD state - skipping (not on any branch)" >&2
        echo "      Tip: Run 'git checkout -b <branch-name>' to fix."
        SKIP_COUNT=$((SKIP_COUNT + 1))
        echo "------------------------------------------"
        cd "$START_DIR"
        continue
    fi
    
    echo "   Branch: $CURRENT_BRANCH"
    
    # --- PRE-SYNC STATUS ---
    echo "   Pre-Sync Remote: $(get_branch_status "$CURRENT_BRANCH")"
    
    # Check for uncommitted changes (INCLUDING UNTRACKED FILES)
    HAS_CHANGES=false
    
    # Check for modified/staged files
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        HAS_CHANGES=true
        echo "   Files Changed Locally (Staging):"
        git status --short | sed 's/^/      /'
    elif ! git diff --staged --quiet 2>/dev/null; then
        HAS_CHANGES=true
        echo "   Files Staged (Ready for commit):"
        git diff --staged --name-status | while read status file; do
            case "$status" in
                A) echo "      + $file" ;;
                M) echo "      ~ $file" ;;
                D) echo "      - $file" ;;
                *) echo "      $status $file" ;;
            esac
        done
    fi
    
    # NEW: Check for untracked files
    UNTRACKED_COUNT=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
    if [ "$UNTRACKED_COUNT" -gt 0 ]; then
        HAS_CHANGES=true
        echo "   Untracked Files Found: $UNTRACKED_COUNT"
        git ls-files --others --exclude-standard | head -10 | sed 's/^/      ?? /'
        if [ "$UNTRACKED_COUNT" -gt 10 ]; then
            echo "      ... and $((UNTRACKED_COUNT - 10)) more"
        fi
    fi
    
    if [ "$HAS_CHANGES" = false ]; then
        echo "   Local Files: ✓ Clean working directory"
    fi
    
    # --- SKIP IF NO CHANGES AND UP-TO-DATE ---
    if [ "$HAS_CHANGES" = false ] && [ "$SKIP_CLEAN_REPOS" = true ]; then
        git fetch origin "$CURRENT_BRANCH" --quiet 2>/dev/null
        LOCAL=$(git rev-parse @ 2>/dev/null)
        REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
        
        if [ "$LOCAL" = "$REMOTE" ] && [ -n "$REMOTE" ]; then
            echo "   ------------------------------------------"
            echo "   ✓ Skipping: Repository is clean and up-to-date."
            SKIP_COUNT=$((SKIP_COUNT + 1))
            echo "------------------------------------------"
            cd "$START_DIR"
            continue
        fi
    fi
    
    # --- COMMIT LOCAL CHANGES ---
    echo "   ------------------------------------------"
    echo "   >>> START TRANSACTION <<<"
    
    if [ "$SHOW_COMMANDS" = true ]; then
        echo "   🔧 Running: git add -A"
    fi
    git add -A
    
    COMMIT_MADE=false
    if ! git diff --staged --quiet 2>/dev/null; then
        
        COMMIT_CMD="git commit -m \"$COMMIT_MESSAGE\""
        if [ "$VERIFY_COMMITS" = false ]; then
            COMMIT_CMD="$COMMIT_CMD --no-verify"
        fi
        
        if [ "$SHOW_COMMANDS" = true ]; then
            echo "   🔧 Running: $COMMIT_CMD"
        fi
        
        if [ "$DRY_RUN" = true ]; then
            echo "   [DRY RUN] Would commit changes with message: \"$COMMIT_MESSAGE\""
            COMMIT_MADE=true
        elif eval "$COMMIT_CMD" &>/dev/null; then
            echo "   ✓ Commit Successful"
            COMMIT_MADE=true
        else
            echo "   ✗ Commit failed" >&2
            echo "      Tip: Check pre-commit hooks. Run 'git commit' manually."
            ERROR_COUNT=$((ERROR_COUNT + 1))
            REPO_FAILED=true
        fi
    else
        echo "   ✓ No new changes to commit."
    fi
    
    # Skip pull/push if commit failed
    if [ "$REPO_FAILED" = true ]; then
        echo "   >>> TRANSACTION FAILED (Commit) <<<"
        echo "------------------------------------------"
        cd "$START_DIR"
        continue
    fi
    
    # --- PULL FROM REMOTE ---
    PULL_CMD="git pull"
    if [ "$USE_REBASE" = true ]; then
        PULL_CMD="$PULL_CMD --rebase"
    fi
    PULL_CMD="$PULL_CMD origin $CURRENT_BRANCH"
    
    if [ "$SHOW_COMMANDS" = true ]; then
        echo "   🔧 Running: $PULL_CMD"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "   [DRY RUN] Would pull from origin/$CURRENT_BRANCH"
        PULL_OUTPUT="Already up to date."
        PULL_EXIT=0
    else
        PULL_OUTPUT=$($PULL_CMD 2>&1)
        PULL_EXIT=$?
    fi
    
    if [ $PULL_EXIT -ne 0 ]; then
        if echo "$PULL_OUTPUT" | grep -qi "conflict"; then
            echo "   ✗ MERGE CONFLICT detected. Resolve manually." >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
            REPO_FAILED=true
        else
            echo "   ✗ Pull failed unexpectedly." >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
            REPO_FAILED=true
        fi
    elif ! echo "$PULL_OUTPUT" | grep -qi "up.to.date\|already up to date"; then
        echo "   ↓ Pulled remote changes."
    else
        echo "   ✓ Pull: Already up to date."
    fi
    
    # Skip push if pull failed (especially due to conflicts)
    if [ "$REPO_FAILED" = true ]; then
        echo "   >>> TRANSACTION FAILED (Pull) <<<"
        echo "------------------------------------------"
        cd "$START_DIR"
        continue
    fi
    
    # --- PUSH TO REMOTE ---
    if [ "$SHOW_COMMANDS" = true ]; then
        echo "   🔧 Running: git push -u origin $CURRENT_BRANCH"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "   [DRY RUN] Would push local changes to remote."
        PUSH_OUTPUT="Everything up-to-date"
        PUSH_EXIT=0
    else
        PUSH_OUTPUT=$(git push -u origin "$CURRENT_BRANCH" 2>&1)
        PUSH_EXIT=$?
    fi
    
    if [ $PUSH_EXIT -ne 0 ]; then
        echo "   ✗ Push failed. Check authentication or remote status." >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
    elif ! echo "$PUSH_OUTPUT" | grep -qi "up.to.date\|everything up-to-date"; then
        echo "   ↑ Push Successful."
    else
        echo "   ✓ Push: Nothing new to send."
    fi

    # --- POST-SYNC STATUS ---
    echo "   ------------------------------------------"
    echo "   >>> POST-SYNC STATUS <<<"
    echo "   Remote: $(get_branch_status "$CURRENT_BRANCH")"
    echo "   Local: $(git status --short 2>/dev/null | wc -l | tr -d ' ')" "unstaged/staged files."
    echo "   Last Commit: $(git log --oneline -1 2>/dev/null || echo "N/A")"
    echo "------------------------------------------"
    cd "$START_DIR"
done

# --- SUMMARY ---
echo "=========================================="
echo "          MULTI-REPO SYNC SUMMARY         "
echo "=========================================="
SUCCESS_COUNT=$((TOTAL_PROCESSED - ERROR_COUNT - SKIP_COUNT))

echo "Total Repositories Found: ${#REPOS[@]}"
echo "Repositories Processed:   $TOTAL_PROCESSED"
echo "Successful Syncs:         $SUCCESS_COUNT"
if [ $SKIP_COUNT -gt 0 ]; then
    echo "Skipped (Clean):          $SKIP_COUNT (use --all to process)"
fi
if [ $ERROR_COUNT -gt 0 ]; then
    echo "Errors / Conflicts:       $ERROR_COUNT"
fi
echo "=========================================="

if [ $ERROR_COUNT -gt 0 ]; then
    echo "⚠️    Completed with ERRORS. Please review output above and resolve conflicts manually."
    exit 1
elif [ $SUCCESS_COUNT -eq 0 ] && [ $TOTAL_PROCESSED -gt 0 ]; then
    echo "✓ All repositories were already clean and up-to-date (or were skipped)."
    exit 0
else
    echo "✓ All targeted repositories synced successfully."
    exit 0
fi
