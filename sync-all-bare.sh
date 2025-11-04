#!/bin/bash

# =========================================================================
# Ultra-Minimalist Core Git Sync Script
# Runs git commands on all detected repositories. No error handling logic 
# or verbose output—relies purely on Git's exit codes and standard output.
# =========================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 0. INITIAL SETUP (Minimum necessary for file path resolution) ---

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
START_DIR=$(pwd)

# --- 1. PROMPT FOR COMMIT MESSAGE (Required for git commit) ---

echo "Enter commit message for any repos with changes (or press Enter for default):"
read -r COMMIT_MESSAGE

if [ -z "$COMMIT_MESSAGE" ]; then
    COMMIT_MESSAGE="Auto-sync"
fi

# --- 2. FIND ALL REPOSITORIES (Excluding *.bkup/*.bak) ---

REPOS=()
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    # Exclude backup directories
    if [[ "$REPO_PATH" =~ \.BKUP|\.BAK|\.bkup|\.bak ]]; then
        continue
    fi
    REPOS+=("$REPO_PATH")
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

# --- 3. LOOP THROUGH REPOSITORIES AND RUN GIT COMMANDS ---

for REPO_PATH in "${REPOS[@]}"; do
    
    REPO_NAME=$(basename "$REPO_PATH")

    # Double check skip for backup directories. 
    if [[ "$REPO_NAME" =~ \.BKUP|\.BAK|\.bkup|\.bak ]]; then
        continue
    fi
    
    # Change to the repository directory. Uses '|| continue' instead of error logic.
    cd "$REPO_PATH" || continue
    
    # --- STAGE & COMMIT BLOCK ---
    
    # Stage all changes
    git add -A
    
    # Commit changes. Output will show if a commit occurred or if "nothing to commit".
    # Using '|| true' to prevent 'set -e' from exiting the script if there is nothing to commit.
    git commit -m "$COMMIT_MESSAGE" --no-verify || true
    
    # --- PULL BLOCK (Web -> Local) ---
    
    # Pull/rebase changes. Output will show if pull failed or if it updated.
    git pull --rebase
    
    # --- PUSH BLOCK (Local -> Web) ---
    
    # Push changes. Output will show if push failed or was successful/up-to-date.
    git push
    
    # Return to the starting directory. Uses '|| true' to ensure script doesn't stop here.
    cd "$START_DIR" || true
    
done

