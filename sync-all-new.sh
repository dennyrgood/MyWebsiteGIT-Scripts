#!/bin/bash

# =========================================================================
# Enhanced Sync Script (Minimalist Output with A/M/D Status)
# Runs from ANYWHERE: Automatically finds and synchronizes all Git 
# repositories within the directory containing the script's parent folder.
# Prints detailed report to CONSOLE and verbose log to Scripts/sync-all.log
# =========================================================================

# Exit immediately if a command exits with a non-zero status, unless handled.
# This is crucial for stability.
set -e

# --- 0. INITIAL SETUP ---

# Get the directory where this script file lives.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# Set the root directory for all repositories to the PARENT directory of the script.
REPO_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# Store the directory where the script was launched from.
START_DIR=$(pwd)
# Define the log file path
LOG_FILE="$SCRIPT_DIR/sync-all.log"
# Initialize error counter
ERROR_COUNT=0

# Start logging (using > to overwrite the previous log)
echo "=========================================" > "$LOG_FILE"
echo " Starting Universal Git Sync (Verbose Log)" >> "$LOG_FILE"
echo " Time: $(date)" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# Echo basic info to the console (Canvas)
echo "========================================="
echo " Starting Universal Git Sync (Minimalist)"
echo "========================================="
echo ""
echo "Repository Root Directory: $REPO_ROOT_DIR"
echo "Verbose Git Log is written to: $LOG_FILE"

# --- REPO PROCESSING FUNCTION ---

process_repo() {
    local REPO_PATH="$1"
    local REPO_NAME=$(basename "$REPO_PATH")
    local COMMIT_MESSAGE="$2"

    # Log start time for this repo
    echo "" >> "$LOG_FILE"
    echo "--- PROCESSING REPO: $REPO_NAME ($(date)) ---" >> "$LOG_FILE"
    echo "Path: $REPO_PATH" >> "$LOG_FILE"
    
    # Change to the repository directory
    if ! cd "$REPO_PATH"; then
        echo "❌ ERROR: Could not enter directory $REPO_PATH." >> "$LOG_FILE"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "❌ ERROR: Could not enter directory $REPO_NAME." 
        return
    fi
    
    # Initialize status variables for this repo
    local COMMITTED_CHANGES=""
    local PULLED_CHANGES=""
    local WAS_UP_TO_DATE=true
    
    # Capture the HEAD commit hash BEFORE the pull, to use for diff later.
    local PRE_PULL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")

    # --- STAGE & COMMIT BLOCK ---
    
    echo "-> Staging all changes..." >> "$LOG_FILE"
    git add -A 2>&1 | sed 's/^/   /' >> "$LOG_FILE"
    
    # Check if there are changes to commit
    local STAGED_FILES=$(git diff --name-only --staged)
    
    if [ -n "$STAGED_FILES" ]; then
        WAS_UP_TO_DATE=false
        
        echo "-> Committing changes..." >> "$LOG_FILE"
        # Commit changes. Use --no-verify to bypass hooks that fail automated commits.
        local COMMIT_OUTPUT=$(git commit -m "$COMMIT_MESSAGE" --no-verify 2>&1)
        echo "$COMMIT_OUTPUT" | sed 's/^/   /' >> "$LOG_FILE"
        
        # Check if commit was successful
        if echo "$COMMIT_OUTPUT" | grep -q 'file changed'; then
            local LAST_COMMIT_HASH=$(git rev-parse HEAD)
            # Use diff-tree to get the file status (A, M, D) for the latest commit
            COMMITTED_CHANGES=$(git diff-tree --no-commit-id --name-status "$LAST_COMMIT_HASH" | awk '{print $1 "   " $2}')
        else
            echo "❌ ERROR: Commit failed for $REPO_NAME." >> "$LOG_FILE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            echo "❌ ERROR: Commit failed for $REPO_NAME."
            cd "$START_DIR"
            return
        fi
    fi
    
    # --- PULL BLOCK (Web -> Mac) ---
    
    echo "-> Pulling remote changes (git pull --rebase)..." >> "$LOG_FILE"
    # Run pull and capture output, piping to log file
    local PULL_OUTPUT=$(git pull --rebase 2>&1)
    local PULL_EXIT_CODE=$?
    echo "$PULL_OUTPUT" | sed 's/^/   /' >> "$LOG_FILE"


    if [ $PULL_EXIT_CODE -ne 0 ]; then
        if echo "$PULL_OUTPUT" | grep -q 'CONFLICT'; then
            echo "❌ PULL FAILED! Please resolve conflicts manually in $REPO_NAME" >> "$LOG_FILE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            echo "❌ PULL FAILED! Please resolve conflicts manually in $REPO_NAME"
        elif echo "$PULL_OUTPUT" | grep -q 'Could not find remote branch'; then
            echo "⚠️ WARNING: Skipping pull for $REPO_NAME (No upstream branch set)." >> "$LOG_FILE"
            # No error count increment, just a warning.
        else
            echo "❌ ERROR: Pull failed unexpectedly for $REPO_NAME." >> "$LOG_FILE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            echo "❌ ERROR: Pull failed unexpectedly for $REPO_NAME."
        fi
        cd "$START_DIR"
        return
    fi
    
    # Check for successful pull resulting in changes
    if [ -n "$PRE_PULL_HEAD" ] && ! git diff --quiet "$PRE_PULL_HEAD" HEAD; then
        WAS_UP_TO_DATE=false
        PULLED_CHANGES=$(git diff --name-status "$PRE_PULL_HEAD" HEAD | awk '{print $1 "   " $2}')
    fi

    # --- PUSH BLOCK (Mac -> Web) ---
    
    echo "-> Pushing changes to remote (git push)..." >> "$LOG_FILE"
    local PUSH_OUTPUT=$(git push 2>&1)
    echo "$PUSH_OUTPUT" | sed 's/^/   /' >> "$LOG_FILE"

    if echo "$PUSH_OUTPUT" | grep -q 'error'; then
        echo "❌ PUSH FAILED for $REPO_NAME" >> "$LOG_FILE"
        echo "   Details: $PUSH_OUTPUT" >> "$LOG_FILE"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "❌ PUSH FAILED for $REPO_NAME"
        cd "$START_DIR"
        return
    elif [ "$WAS_UP_TO_DATE" = true ] && [ -z "$COMMITTED_CHANGES" ] && [ -z "$PULLED_CHANGES" ]; then
        # Quiet push, nothing happened, still up-to-date
        :
    else
        WAS_UP_TO_DATE=false
    fi
    
    # --- CONSOLE OUTPUT GENERATION ---
    
    if [ "$WAS_UP_TO_DATE" = true ]; then
        # Minimalist output for clean repos
        echo "✓ $REPO_NAME: Up-to-date"
    else
        # Detailed output block for active repos (printed directly to console)
        echo "✅ SYNCED: $REPO_NAME"
        
        # Log Pulled Changes (Web -> Mac)
        if [ -n "$PULLED_CHANGES" ]; then
            echo "   --- ⬇️ UPDATED FROM WEB -------------------"
            # Replace status codes with descriptions and format for console
            echo "$PULLED_CHANGES" | sed \
                -e 's/^A/A (Added)/' \
                -e 's/^M/M (Modified)/' \
                -e 's/^D/D (Deleted)/' \
                -e 's/ *//' | sed 's/^/   /' 
            echo "   -----------------------------------------"
        fi

        # Log Committed & Pushed Changes (Mac -> Web)
        if [ -n "$COMMITTED_CHANGES" ]; then
            echo "   --- COMMITTED & SYNCED CHANGES ----------"
            # Replace status codes with descriptions and format for console
            echo "$COMMITTED_CHANGES" | sed \
                -e 's/^A/A (Added)/' \
                -e 's/^M/M (Modified)/' \
                -e 's/^D/D (Deleted)/' \
                -e 's/ *//' | sed 's/^/   /'
            echo "   -----------------------------------------"
        fi
    fi

    # Return to the starting directory after processing this repo
    cd "$START_DIR"
    
}

# --- 1. PROMPT FOR COMMIT MESSAGE (Console) ---

echo ""
echo "Enter commit message for any repos with changes (or press Enter for default):"
read -r COMMIT_MESSAGE

if [ -z "$COMMIT_MESSAGE" ]; then
    COMMIT_MESSAGE="Auto-sync from local changes"
fi

echo ""
echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"
echo ""

# --- 2. FIND ALL REPOSITORIES ---

# Find all .git directories starting the search from the root, excluding backups
REPOS=()
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    # Exclude directories containing common backup strings (case-insensitive check)
    if [[ "$REPO_PATH" =~ \.BKUP|\.BAK|\.bkup|\.bak ]]; then
        echo "Skipping backup directory: $REPO_PATH" >> "$LOG_FILE"
        continue
    fi
    REPOS+=("$REPO_PATH")
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

REPO_COUNT=${#REPOS[@]}
echo "Found $REPO_COUNT repositories to process."
echo "-----------------------------------------"

# --- 3. LOOP THROUGH REPOSITORIES ---

for REPO_PATH in "${REPOS[@]}"; do
    process_repo "$REPO_PATH" "$COMMIT_MESSAGE"
done

# --- 4. FINAL SUMMARY (Console) ---

echo "-----------------------------------------"
echo "         SUMMARY & ERRORS"
echo "-----------------------------------------"

if [ $ERROR_COUNT -gt 0 ]; then
    echo "🚨 $ERROR_COUNT repository(ies) encountered an error. Check $LOG_FILE for details."
else
    echo "All repositories processed successfully."
fi
echo "========================================="

