#!/bin/bash

# =========================================================================
# Core Git Sync Script (Function Only)
# Synchronizes all Git repositories within the script's parent folder.
# Output is minimalist: only prints errors, warnings, and the final summary.
# =========================================================================

# Exit immediately if a command exits with a non-zero status, unless handled.
set -e

# --- 0. INITIAL SETUP ---

# Get the directory where this script file lives.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# Set the root directory for all repositories to the PARENT directory of the script.
REPO_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# Store the directory where the script was launched from.
START_DIR=$(pwd)
# Initialize error counter
ERROR_COUNT=0

# --- 1. PROMPT FOR COMMIT MESSAGE ---

echo "Enter commit message for any repos with changes (or press Enter for default):"
read -r COMMIT_MESSAGE

if [ -z "$COMMIT_MESSAGE" ]; then
    COMMIT_MESSAGE="Auto-sync from local changes"
fi

# --- 2. FIND ALL REPOSITORIES ---

# Find all .git directories starting the search from the root, excluding backups
REPOS=()
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    # Simple check to skip directories containing common backup strings (case-insensitive check)
    if [[ "$REPO_PATH" =~ \.BKUP|\.BAK|\.bkup|\.bak ]]; then
        continue
    fi
    REPOS+=("$REPO_PATH")
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

# --- 3. LOOP THROUGH REPOSITORIES ---

for REPO_PATH in "${REPOS[@]}"; do
    
    REPO_NAME=$(basename "$REPO_PATH")
    
    # Initialize status variable for this repo
    WAS_ACTIVE=false

    # Skip backup directories. 
    if [[ "$REPO_NAME" =~ \.BKUP|\.BAK|\.bkup|\.bak ]]; then
        continue
    fi
    
    # Change to the repository directory
    cd "$REPO_PATH" || { echo "ERROR: Cannot change directory to $REPO_PATH" >&2; ERROR_COUNT=$((ERROR_COUNT + 1)); cd "$START_DIR"; continue; }
    
    # --- STAGE & COMMIT BLOCK ---
    
    # Stage all changes
    git add -A
    
    # Check if there are changes to commit
    STAGED_FILES=$(git diff --name-only --staged)
    
    if [ -n "$STAGED_FILES" ]; then
        WAS_ACTIVE=true
        
        # Commit changes.
        COMMIT_OUTPUT=$(git commit -m "$COMMIT_MESSAGE" --no-verify 2>&1)
        
        # Check if commit was successful by ensuring it did NOT result in "nothing to commit"
        if ! echo "$COMMIT_OUTPUT" | grep -q 'nothing to commit'; then
            echo "$REPO_NAME: Committed changes."
        else
            # This path *shouldn't* be hit if STAGED_FILES check worked, but catches genuine commit errors
            echo "ERROR: Commit failed for $REPO_NAME." >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
            cd "$START_DIR"
            continue
        fi
    fi
    
    # --- PULL BLOCK (Web -> Local) ---
    
    PULL_OUTPUT=$(git pull --rebase 2>&1)
    PULL_EXIT_CODE=$?

    if [ $PULL_EXIT_CODE -ne 0 ]; then
        WAS_ACTIVE=true # Log error/warning
        if echo "$PULL_OUTPUT" | grep -q 'CONFLICT'; then
            echo "FATAL ERROR: Pull failed with conflicts in $REPO_PATH. Resolve manually." >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        elif echo "$PULL_OUTPUT" | grep -q 'Could not find remote branch'; then
            echo "WARNING: Skipping pull for $REPO_NAME (No upstream branch set)."
        else
            echo "ERROR: Pull failed for $REPO_NAME. Details: $PULL_OUTPUT" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
        cd "$START_DIR"
        continue
    elif ! echo "$PULL_OUTPUT" | grep -q 'up to date'; then
        WAS_ACTIVE=true
        echo "$REPO_NAME: Pulled changes from remote."
    fi

    # --- PUSH BLOCK (Local -> Web) ---
    
    PUSH_OUTPUT=$(git push 2>&1)

    if echo "$PUSH_OUTPUT" | grep -q 'Everything up-to-date'; then
        : # Quiet push
    elif echo "$PUSH_OUTPUT" | grep -q 'error'; then
        WAS_ACTIVE=true # Log error
        # Push failure
        echo "ERROR: PUSH FAILED for $REPO_NAME. Details: $PUSH_OUTPUT" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
    else
        WAS_ACTIVE=true
        echo "$REPO_NAME: Successfully pushed changes."
    fi
    
    # --- LISTING OUTPUT ---
    if [ "$WAS_ACTIVE" = false ]; then
        echo "$REPO_NAME: Up-to-date"
    fi
    
    # Return to the starting directory after processing this repo
    cd "$START_DIR"
    
done

# --- 4. FINAL SUMMARY ---

echo ""
echo "--- SYNC COMPLETE ---"
if [ $ERROR_COUNT -gt 0 ]; then
    echo "🚨 $ERROR_COUNT repository(ies) encountered an error." >&2
else
    echo "All repositories processed successfully."
fi
echo "---------------------"

