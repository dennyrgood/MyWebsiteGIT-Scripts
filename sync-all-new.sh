#!/bin/bash

# =========================================================================
# Enhanced Sync Script (Minimalist Output with A/M/D Status)
# Runs from ANYWHERE: Automatically finds and synchronizes all Git 
# repositories within the directory containing the script's parent folder.
# Prints detailed output ONLY for changes or errors.
# Logs all verbose Git activity to Scripts/sync-all.log
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

# Define the path for the verbose log file, overwriting it at the start.
LOG_FILE="$SCRIPT_DIR/sync-all.log"
echo "--- Starting Sync Run: $(date) ---" > "$LOG_FILE"

echo "========================================="
echo " Starting Universal Git Sync (Minimalist)"
echo "========================================="
echo ""
echo "Repository Root Directory: $REPO_ROOT_DIR"
echo "Verbose Log is being saved to: $LOG_FILE"

# --- 1. PROMPT FOR COMMIT MESSAGE ---

echo ""
echo "Enter commit message for any repos with changes (or press Enter for default):"
read -r COMMIT_MESSAGE

if [ -z "$COMMIT_MESSAGE" ]; then
    COMMIT_MESSAGE="Auto-sync from local changes"
fi

echo ""
echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"
echo ""

# --- FUNCTION: PROCESS SINGLE REPO ---

# All Git commands run inside this function are redirected to the log file.
process_repo() {
    local REPO_PATH=$1
    local REPO_NAME=$2
    local REPO_START_DIR=$3
    local COMMIT_MESSAGE=$4
    local LOG_FILE=$5
    
    # Initialize status variables for this repo (these return values are passed back to the main loop)
    local COMMITTED_CHANGES=""
    local PULLED_CHANGES=""
    local REPO_STATUS="SUCCESS"

    echo "--- PROCESSING REPO: $REPO_NAME ($(date)) ---" >> "$LOG_FILE"
    
    # Capture the HEAD commit hash BEFORE the pull, to use for diff later.
    PRE_PULL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    
    # --- STAGE & COMMIT BLOCK ---
    echo "-> Staging all changes..." >> "$LOG_FILE"
    git add -A >> "$LOG_FILE" 2>&1
    
    # Check if there are changes to commit
    STAGED_FILES=$(git diff --name-only --staged)
    
    if [ -n "$STAGED_FILES" ]; then
        echo "-> Committing changes..." >> "$LOG_FILE"
        
        # Commit changes. Use --no-verify to bypass hooks.
        COMMIT_OUTPUT=$(git commit -m "$COMMIT_MESSAGE" --no-verify 2>&1)
        COMMIT_EXIT_CODE=$?

        # Append commit output to log
        echo "$COMMIT_OUTPUT" >> "$LOG_FILE"
        
        # Check if commit was successful based on exit code
        if [ $COMMIT_EXIT_CODE -eq 0 ] && echo "$COMMIT_OUTPUT" | grep -q 'file changed'; then
            LAST_COMMIT_HASH=$(git rev-parse HEAD)
            # Use diff-tree to get the file status (A, M, D) for the latest commit
            COMMITTED_CHANGES=$(git diff-tree --no-commit-id --name-status "$LAST_COMMIT_HASH" | awk '{print $1 "   " $2}')
        else
            echo "❌ ERROR: Commit failed for $REPO_NAME. See $LOG_FILE for details."
            REPO_STATUS="COMMIT_FAIL"
            # Return failure status (1) if commit failed
            return 1
        fi
    fi
    
    # --- PULL BLOCK (Web -> Mac) ---
    
    echo "-> Pulling changes..." >> "$LOG_FILE"
    PULL_OUTPUT=$(git pull --rebase 2>&1)
    PULL_EXIT_CODE=$?
    echo "$PULL_OUTPUT" >> "$LOG_FILE"

    if [ $PULL_EXIT_CODE -ne 0 ]; then
        if echo "$PULL_OUTPUT" | grep -q 'CONFLICT'; then
            echo "❌ PULL FAILED! Please resolve conflicts manually in $REPO_PATH. See $LOG_FILE"
            REPO_STATUS="PULL_CONFLICT"
            return 1
        elif echo "$PULL_OUTPUT" | grep -q 'Could not find remote branch'; then
            echo "⚠️ WARNING: Skipping pull for $REPO_NAME (No upstream branch set)." >> "$LOG_FILE"
        else
            echo "❌ ERROR: Pull failed for $REPO_NAME with non-conflict error. See $LOG_FILE"
            REPO_STATUS="PULL_FAIL"
            return 1
        fi
    fi

    # Check for changes pulled from remote (only if pull succeeded)
    if [ $PULL_EXIT_CODE -eq 0 ]; then
        # FIX: Robustly get changes by diffing current HEAD against the HEAD before the pull.
        if [ -n "$PRE_PULL_HEAD" ] && ! git diff --quiet "$PRE_PULL_HEAD" HEAD; then
            PULLED_CHANGES=$(git diff --name-status "$PRE_PULL_HEAD" HEAD | awk '{print $1 "   " $2}')
        fi
    fi

    # --- PUSH BLOCK (Mac -> Web) ---
    
    echo "-> Pushing changes..." >> "$LOG_FILE"
    PUSH_OUTPUT=$(git push 2>&1)
    PUSH_EXIT_CODE=$?
    echo "$PUSH_OUTPUT" >> "$LOG_FILE"

    if [ $PUSH_EXIT_CODE -ne 0 ] && ! echo "$PUSH_OUTPUT" | grep -q 'Everything up-to-date'; then
        echo "❌ PUSH FAILED for $REPO_NAME. See $LOG_FILE for details."
        REPO_STATUS="PUSH_FAIL"
        return 1
    fi
    
    # Final success return (data is returned via echo)
    echo "$COMMITTED_CHANGES|$PULLED_CHANGES|$REPO_STATUS"
    return 0
}


# --- 2. FIND ALL REPOSITORIES ---

# Find all .git directories starting the search from the root, excluding backups
REPOS=()
while IFS= read -r DIR; do
    REPO_PATH=$(dirname "$DIR")
    # Use robust string matching (grep) to skip directories containing common backup strings (case-insensitive check)
    if echo "$REPO_PATH" | grep -q -iE '(\.BKUP|\.BAK|\.bkup|\.bak)'; then
        echo "--- SKIPPING: Backup directory detected: $REPO_PATH" >> "$LOG_FILE"
        continue
    fi
    REPOS+=("$REPO_PATH")
done < <(find "$REPO_ROOT_DIR" -maxdepth 3 -type d -name ".git" -not -path "$REPO_ROOT_DIR/.git")

REPO_COUNT=${#REPOS[@]}
echo "Found $REPO_COUNT repositories to process."
echo "-----------------------------------------"

# --- 3. LOOP THROUGH REPOSITORIES ---

for REPO_PATH in "${REPOS[@]}"; do
    
    REPO_NAME=$(basename "$REPO_PATH")
    
    # Change to the repository directory
    if ! cd "$REPO_PATH"; then
        echo "❌ ERROR: Could not enter directory $REPO_PATH. Skipping."
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    
    # Execute the processing function and capture its output (the COMMITTED|PULLED|STATUS string)
    RESULT=$(process_repo "$REPO_PATH" "$REPO_NAME" "$START_DIR" "$COMMIT_MESSAGE" "$LOG_FILE")
    EXIT_CODE=$?
    
    # Parse the result string: COMMITTED_CHANGES|PULLED_CHANGES|REPO_STATUS
    IFS='|' read -r COMMITTED_CHANGES PULLED_CHANGES REPO_STATUS <<< "$RESULT"
    
    # Handle errors and status outputs
    if [ $EXIT_CODE -ne 0 ] || [[ "$REPO_STATUS" == *FAIL* ]] || [[ "$REPO_STATUS" == *CONFLICT* ]]; then
        # Error messages are already printed inside the function
        ERROR_COUNT=$((ERROR_COUNT + 1))
    elif [ -z "$COMMITTED_CHANGES" ] && [ -z "$PULLED_CHANGES" ]; then
        # Minimalist output for clean repos
        echo "✓ $REPO_NAME: Up-to-date"
    else
        # Detailed output block for active repos
        echo "✅ SYNCED: $REPO_NAME"
        
        # Log Pulled Changes (Web -> Mac)
        if [ -n "$PULLED_CHANGES" ]; then
            echo "   --- ⬇️ UPDATED FROM WEB -------------------"
            # Replace status codes with descriptions and format
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
            # Replace status codes with descriptions and format
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
    
done

# --- 4. FINAL SUMMARY ---

echo "-----------------------------------------"
echo "         SUMMARY & ERRORS"
echo "-----------------------------------------"

if [ $ERROR_COUNT -gt 0 ]; then
    echo "🚨 $ERROR_COUNT repository(ies) encountered an error. Please check the Canvas for specific failures."
else
    echo "All repositories processed successfully."
fi
echo "========================================="
