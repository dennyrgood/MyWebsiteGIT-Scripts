#!/bin/bash

# --- 1. Get Current Branch Name ---
# This command gets the name of the currently checked-out branch.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# --- 2. Get Commit Message ---

DEFAULT_MESSAGE="Cleaning up files/sync from local to remote branch: $CURRENT_BRANCH"

# Check if message provided as command line argument
if [ -n "$1" ]; then
    COMMIT_MESSAGE="$1"
else
    # Prompt user for input
    echo "Enter commit message (or press Enter to use default):"
    read -r USER_MESSAGE

    # Set the final commit message
    if [ -z "$USER_MESSAGE" ]; then
        COMMIT_MESSAGE="$DEFAULT_MESSAGE"
    else
        COMMIT_MESSAGE="$USER_MESSAGE"
    fi
fi

echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"
echo "--- Syncing current branch: $CURRENT_BRANCH ---"
echo ""

# --- Show what's about to be committed ---
echo "Files to be committed:"
git status --short
echo ""

# --- 3. Git Operations: Commit Local Changes ---

# Stage all changes (additions, modifications, deletions) with verbose output
echo "Staging all changes..."
git add -A -v

# Commit staged changes
echo "Committing staged changes..."
git commit -m "$COMMIT_MESSAGE"

# Check if the commit was successful before proceeding
if [ $? -ne 0 ]; then
    echo "Warning: No changes to commit. Proceeding with pull/push sync."
fi


# --- 4. Git Operations: Pull and Push to Current Branch ---

# FETCH: Get all tags from remote
echo "Fetching tags from remote..."
git fetch --tags

# PULL: Fetch and merge remote changes for the current branch
echo "Pulling remote changes from origin/$CURRENT_BRANCH..."
git pull origin "$CURRENT_BRANCH"

# Check if pull was successful (handles merge conflicts)
if [ $? -ne 0 ]; then
    echo ""
    echo "â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â""
    echo "ERROR: Pull failed - likely due to merge conflicts"
    echo "â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â""
    echo ""
    echo "What to do next:"
    echo "  1. Run 'git status' to see conflicting files"
    echo "  2. Open and resolve conflicts in each file"
    echo "  3. Run 'git add <resolved-files>'"
    echo "  4. Run 'git commit' to complete the merge"
    echo "  5. Run this script again to push changes"
    echo ""
    exit 1
fi

# PUSH: Send local changes to the remote branch
echo "Pushing local changes to origin/$CURRENT_BRANCH..."
# The -u flag is included in case this is a brand new local branch 
# that hasn't been pushed upstream yet.
git push -u origin "$CURRENT_BRANCH"

# Check if push was successful
if [ $? -ne 0 ]; then
    echo ""
    echo "â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â""
    echo "ERROR: Push failed"
    echo "â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â"â""
    echo ""
    echo "Possible reasons:"
    echo "  - Network connectivity issues"
    echo "  - No permission to push to origin/$CURRENT_BRANCH"
    echo "  - Remote branch has been force-updated"
    echo ""
    echo "Your changes are still committed locally."
    echo "Run 'git status' for more information."
    echo ""
    exit 1
fi

echo ""
echo "âœ" Sync complete! All changes pushed to origin/$CURRENT_BRANCH"
