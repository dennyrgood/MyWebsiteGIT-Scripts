#!/bin/bash

echo "=========================================="
echo "         GIT SYNC: PRE-SYNC STATUS        "
echo "=========================================="

# --- 1. Current Branch Status (Diagnostic Part) ---
CURRENT_BRANCH=$(git branch --show-current)
echo "=== Branch: $CURRENT_BRANCH ==="

# Show if branch has upstream and if it is ahead/behind
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
if [ -n "$UPSTREAM" ]; then
    echo "Tracking: $UPSTREAM"

    # Fetch to update remote refs quietly
    git fetch --quiet 2>/dev/null
    AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")

    if [ "$AHEAD" -gt 0 ] || [ "$BEHIND" -gt 0 ]; then
        echo "Status: ↑ $AHEAD ahead, ↓ $BEHIND behind."
    else
        echo "Status: ✓ Up to date with remote"
    fi
else
    echo "⚠️  No upstream branch set - Will set one during push."
fi

echo ""
echo "=== Files Changed Locally ==="
if git diff --quiet && git diff --staged --quiet; then
    echo "✓ No changes to commit"
else
    git status --short
fi

echo "=========================================="
echo "       GIT SYNC: START TRANSACTION        "
echo "=========================================="


# --- 2. Transactional Sync Logic (Commit, Pull, Push) ---

# Re-get Current Branch Name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_MESSAGE="Cleaning up files/sync from local to remote branch: $CURRENT_BRANCH"

# Check if message provided as command line argument
if [ -n "$1" ]; then
    COMMIT_MESSAGE="$1"
else
    # Prompt user for commit message
    echo "Enter commit message (or press Enter to use default):"
    read -r USER_MESSAGE

    if [ -z "$USER_MESSAGE" ]; then
        COMMIT_MESSAGE="$DEFAULT_MESSAGE"
    else
        COMMIT_MESSAGE="$USER_MESSAGE"
    fi
fi

echo "--- Using commit message: \"$COMMIT_MESSAGE\" ---"


# Stage all changes (additions, modifications, deletions)
echo "Staging all changes..."
git add -A

# Commit staged changes
echo "Committing staged changes..."
git commit -m "$COMMIT_MESSAGE"
COMMIT_STATUS=$? # Save commit result

if [ "$COMMIT_STATUS" -ne 0 ]; then
    echo "Warning: No new local changes were committed."
fi

# PULL: Fetch and merge remote changes
echo ""
echo "--- Running git pull to rebase remote changes ---"
git pull --rebase origin "$CURRENT_BRANCH"

# PUSH: Send local changes to the remote branch
echo ""
echo "--- Running git push to update remote ---"
# The -u flag ensures the upstream branch is set if it's a new branch
git push -u origin "$CURRENT_BRANCH"


echo "=========================================="
echo "          GIT SYNC: FINAL STATUS          "
echo "=========================================="

# Final status check to confirm push
echo "Current repository status after sync:"
git status

echo ""
echo "Last 5 Commits (check for new commit):"
git log --oneline -5

echo "=========================================="
echo "           GIT SYNC: FINISHED             "
echo "=========================================="
