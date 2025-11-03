#!/bin/bash

# --- 1. Get Commit Message ---

DEFAULT_MESSAGE="Cleaning up files/sync from local to web"

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

# --- 2. Git Operations ---

# Stage all changes (additions, modifications, deletions)
echo "Staging all changes..."
git add -A

# Commit staged changes
echo "Committing staged changes..."
git commit -m "$COMMIT_MESSAGE"

# Check if the commit was successful before proceeding
if [ $? -ne 0 ]; then
    # The commit fails if there are no changes to commit.
    # We will still proceed to pull/push, which is often desirable for a sync script.
    echo "Warning: No changes to commit. Proceeding with pull/push sync."
fi

# PULL: Fetch and merge remote changes before pushing local changes
echo "Pulling remote changes from origin main..."
git pull origin main

# PUSH: Send local changes to the remote branch
echo "Pushing local changes to origin main..."
git push origin main
