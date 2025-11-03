#!/bin/bash

# =========================================================================
# Enhanced Sync Script (Minimalist Output)
# Finds and synchronizes all Git repositories in the parent directory.
# Only outputs details for repos that have changes or errors.
# =========================================================================

# Temporarily disable 'set -e' to allow us to handle non-zero exit codes (like git pull failure) gracefully inside the loop.
# We will use explicit checks ($? -ne 0) instead.
# set -e

echo "========================================="
echo " Starting Universal Git Sync (Minimalist) "
echo "========================================="
echo ""

# --- 0. DETERMINE REPOSITORY ROOT DIRECTORY ---

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Repository Root Directory: $REPO_ROOT_DIR"
echo ""

# --- 1. PROMPT FOR COMMIT MESSAGE ---

echo "Enter commit message for any repos with changes (or press Enter for default):"
read -r COMMIT_MESSAGE

if [ -z "$COMMIT_MESSAGE" ]; then
    COMMIT_MESSAGE="Auto-sync from local changes"
fi

echo ""
echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"
echo ""

# --- 2. FIND ALL REPOSITORIES (AUTOMATIC DISCOVERY) ---

REPOS=()
while IFS= read -r DIR; do
    REPO_PATH="${DIR%/.git}"
    if [ "$REPO_PATH" == "$SCRIPT_DIR" ]; then
        REPOS=("${REPO_PATH}" "${REPOS[@]}")
        continue
    fi
    REPOS+=("$REPO_PATH")
done < <(
    find "$REPO_ROOT_DIR" -type d \( -name "*.BKUP" -o -name "*.bkp" -o -name "*.BKUP-*" \) -prune -o -type d -name ".git" -print
)

REPOS=($(printf "%s\n" "${REPOS[@]}" | sort -u))

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "❌ Error: No git repositories found in '$REPO_ROOT_DIR' or its subdirectories."
    exit 1
fi

echo "Found ${#REPOS[@]} repositories to process."
echo "-----------------------------------------"

# --- 3. LOOP AND SYNC ---

START_DIR=$(pwd)
ERROR_LOG=""

for REPO_PATH in "${REPOS[@]}"; do
    
    # Reset tracking variables for this repo
    COMMITTED_FILES=""
    PULL_SUCCESS=true
    PUSH_SUCCESS=false
    CHANGES_DETECTED=false

    REPO_NAME=$(basename "$REPO_PATH")

    # Change to repo directory
    if ! cd "$REPO_PATH" 2>/dev/null; then
        ERROR_LOG+="\n❌ Error: Could not access $REPO_PATH"
        continue
    fi
    
    # Stage all changes
    git add -A
    
    # --- A. COMMIT LOCAL CHANGES ---
    if ! git diff --staged --quiet; then
        CHANGES_DETECTED=true
        COMMITTED_FILES=$(git diff --name-only --staged)
        
        # Commit changes
        if git commit -m "$COMMIT_MESSAGE"; then
            : # Commit successful, COMMITTED_FILES is set
        else
            ERROR_LOG+="\n❌ Commit failed for $REPO_NAME."
            cd "$START_DIR"
            continue
        fi
    fi
    
    # --- B. PULL REMOTE CHANGES ---
    
    # Capture the output of the pull operation
    PULL_OUTPUT=$(git pull --rebase 2>&1)
    PULL_STATUS=$?
    
    if [ $PULL_STATUS -ne 0 ]; then
        PULL_SUCCESS=false
        ERROR_LOG+="\n❌ PULL FAILED in $REPO_NAME:\n$PULL_OUTPUT\n   Please resolve conflicts manually in $REPO_PATH"
        cd "$START_DIR"
        continue
    fi

    # Check for files updated during pull/rebase
    PULLED_FILES=""
    if echo "$PULL_OUTPUT" | grep -q "Fast-forward\|Updated"; then
        CHANGES_DETECTED=true
        PULLED_FILES=$(echo "$PULL_OUTPUT" | grep -E '(\S+)(\s*)\|' | awk '{print $1}')
    fi
    
    # --- C. PUSH LOCAL CHANGES ---
    
    # 1. Attempt standard push
    PUSH_OUTPUT=$(git push 2>&1)
    if [ $? -eq 0 ]; then
        PUSH_SUCCESS=true
    # 2. If standard push fails (e.g., first push or missing upstream), try -u
    else
        PUSH_OUTPUT=$(git push -u origin main 2>&1)
        if [ $? -eq 0 ]; then
            PUSH_SUCCESS=true
            CHANGES_DETECTED=true # Force detail output if tracking was set
        else
            ERROR_LOG+="\n❌ PUSH FAILED in $REPO_NAME:\n$PUSH_OUTPUT"
            cd "$START_DIR"
            continue
        fi
    fi

    # --- D. CONDENSED OUTPUT ---
    
    if $CHANGES_DETECTED; then
        # Detailed output for changes
        echo "✅ SYNCED: $REPO_NAME"
        
        if [ -n "$PULLED_FILES" ]; then
            echo "   --- ⬇️ UPDATED FROM WEB -------------------"
            echo "$PULLED_FILES" | sed 's/^/   /g'
            echo "   -----------------------------------------"
        fi

        if [ -n "$COMMITTED_FILES" ]; then
            echo "   --- ⬆️ PUSHED TO WEB ----------------------"
            echo "$COMMITTED_FILES" | sed 's/^/   /g'
            echo "   -----------------------------------------"
        fi
        
    # We intentionally print nothing for a quiet, up-to-date repository
    # The final summary handles the overall status
    fi
    
    # Return to the starting directory after processing this repo
    cd "$START_DIR"
    
done

# --- 4. FINAL SUMMARY AND ERROR REPORT ---

echo "-----------------------------------------"
echo "         SUMMARY & ERRORS"
echo "-----------------------------------------"

if [ -z "$ERROR_LOG" ]; then
    echo "All repositories processed successfully."
else
    echo "Processing complete, but the following errors occurred:"
    echo -e "$ERROR_LOG"
fi

echo "========================================="

