#!/bin/bash

# --- 1. Get Current Branch Name ---
# This command gets the name of the currently checked-out branch.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# --- 2. Get Commit Message ---

DEFAULT_MESSAGE="Cleaning up files/sync from local to remote branch: $CURRENT_BRANCH"

# Prompt user for input
echo "Enter commit message (or press Enter to use default):"
read -r USER_MESSAGE

# Set the final commit message
if [ -z "$USER_MESSAGE" ]; then
    COMMIT_MESSAGE="$DEFAULT_MESSAGE"
else
    COMMIT_MESSAGE="$USER_MESSAGE"
fi

echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"
echo "--- Syncing current branch: $CURRENT_BRANCH ---"


# --- 3. Git Operations: Commit Local Changes ---

# Stage all changes (additions, modifications, deletions)
echo "Staging all changes..."
git add -A

# Commit staged changes
echo "Committing staged changes..."
git commit -m "$COMMIT_MESSAGE"

# Check if the commit was successful before proceeding
if [ $? -ne 0 ]; then
    echo "Warning: No changes to commit. Proceeding with pull/push sync."
fi


# --- 4. Git Operations: Pull and Push to Current Branch ---

# PULL: Fetch and merge remote changes for the current branch
echo "Pulling remote changes from origin/$CURRENT_BRANCH..."
git pull origin "$CURRENT_BRANCH"

# PUSH: Send local changes to the remote branch
echo "Pushing local changes to origin/$CURRENT_BRANCH..."
# The -u flag is included in case this is a brand new local branch 
# that hasn't been pushed upstream yet.
git push -u origin "$CURRENT_BRANCH"
