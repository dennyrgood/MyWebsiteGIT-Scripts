#!/bin/bash

# =========================================================================
# Minimal Git Sync Script
# Syncs all Git repositories, showing only essential information
# =========================================================================

set -e

# --- SETUP ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
START_DIR=$(pwd)
ERROR_COUNT=0

# --- COMMIT MESSAGE ---
echo "Enter commit message (or press Enter for default):"
read -r COMMIT_MESSAGE
COMMIT_MESSAGE=${COMMIT_MESSAGE:-"Auto-sync from local changes"}
echo ""

# --- FIND REPOSITORIES ---
REPOS=()
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    if [[ ! "$REPO_PATH" =~ \.BKUP|\.BAK|\.bkup|\.bak|_backup|_bak ]]; then
        REPOS+=("$REPO_PATH")
    fi
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

# --- PROCESS REPOSITORIES ---
for REPO_PATH in "${REPOS[@]}"; do
    REPO_NAME=$(basename "$REPO_PATH")
    
    cd "$REPO_PATH" || { 
        echo "❌ $REPO_NAME: Cannot access directory" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
        cd "$START_DIR"
        continue
    }
    
    echo "📂 $REPO_NAME"
    
    # --- COMMIT LOCAL CHANGES ---
    git add -A
    
    if ! git diff --staged --quiet; then
        # List changed files
        echo "   Changes to commit:"
        git diff --staged --name-status | while read status file; do
            case "$status" in
                A) echo "      + $file" ;;
                M) echo "      ~ $file" ;;
                D) echo "      - $file" ;;
                *) echo "      $status $file" ;;
            esac
        done
        
        if git commit -m "$COMMIT_MESSAGE" --no-verify &>/dev/null; then
            echo "   ✓ Committed"
        else
            echo "   ❌ Commit failed" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    fi
    
    # --- PULL FROM REMOTE ---
    PULL_OUTPUT=$(git pull --rebase 2>&1)
    
    if [ $? -ne 0 ]; then
        if echo "$PULL_OUTPUT" | grep -q 'CONFLICT'; then
            echo "   ❌ CONFLICT - resolve manually" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        elif echo "$PULL_OUTPUT" | grep -q 'no tracking'; then
            echo "   ⚠ No upstream branch"
        else
            echo "   ❌ Pull failed" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    elif ! echo "$PULL_OUTPUT" | grep -q 'up to date'; then
        echo "   ↓ Pulled changes"
    fi
    
    # --- PUSH TO REMOTE ---
    PUSH_OUTPUT=$(git push 2>&1)
    
    if echo "$PUSH_OUTPUT" | grep -q 'error'; then
        echo "   ❌ Push failed" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
    elif ! echo "$PUSH_OUTPUT" | grep -q 'Everything up-to-date'; then
        echo "   ↑ Pushed changes"
    fi
    
    echo ""
    cd "$START_DIR"
done

# --- SUMMARY ---
echo "━━━━━━━━━━━━━━━━━━━━"
if [ $ERROR_COUNT -gt 0 ]; then
    echo "⚠ Completed with $ERROR_COUNT error(s)"
    exit 1
else
    echo "✓ All repositories synced"
fi
echo "━━━━━━━━━━━━━━━━━━━━"
