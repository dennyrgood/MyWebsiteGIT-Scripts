#!/bin/bash
# Git Helper Scripts Installer
# This installs a set of helper scripts to make git easier to use

INSTALL_DIR="$HOME/bin"
BACKUP_DIR="$HOME/bin/backup-$(date +%Y%m%d-%H%M%S)"

echo "=========================================="
echo "Git Helper Scripts Installer"
echo "=========================================="
echo ""
echo "This will install helper scripts to: $INSTALL_DIR"
echo ""

# Create install directory if it doesn't exist
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
fi

# Backup existing scripts if they exist
EXISTING_SCRIPTS=0
for script in get-previous show-history git-undo safe-experiment merge-experiment abandon-experiment what-changed; do
    if [ -f "$INSTALL_DIR/$script" ]; then
        EXISTING_SCRIPTS=1
        break
    fi
done

if [ $EXISTING_SCRIPTS -eq 1 ]; then
    echo "⚠️  Found existing scripts. Backing up to: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    for script in get-previous show-history git-undo safe-experiment merge-experiment abandon-experiment what-changed; do
        if [ -f "$INSTALL_DIR/$script" ]; then
            cp "$INSTALL_DIR/$script" "$BACKUP_DIR/"
        fi
    done
    echo ""
fi

# Helper function definition for all scripts
read -r -d '' HELPER_FUNCTION << 'EOF'
# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}
EOF

# ============================================
# Script 1: get-previous
# ============================================
echo "Installing get-previous..."
cat > "$INSTALL_DIR/get-previous" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

if [ -z "$1" ]; then
    echo "Usage: get-previous <filename>"
    echo "Example: get-previous sync-this.sh"
    exit 1
fi

FILENAME="$1"

echo "=== Looking for previous versions of: $FILENAME ==="
echo ""

# Show commits that modified this file
echo "Recent commits that changed this file:"
run_git log --oneline --follow -10 "$FILENAME"

# Ask which version they want
echo "Enter the commit hash (like 7da1111) to see that version"
echo "Or press Enter to see the most recent change:"
read -r COMMIT

if [ -z "$COMMIT" ]; then
    COMMIT="HEAD~1"
fi

echo ""
echo "=== Content from commit $COMMIT ==="
run_git show "$COMMIT:$FILENAME"

echo ""
echo "=== What do you want to do? ==="
echo "1) Save this version as ${FILENAME}.old (for comparison)"
echo "2) Replace current file with this version"
echo "3) Just show me the differences"
echo "4) Never mind, exit"
read -r CHOICE

case $CHOICE in
    1)
        echo "📍 Running: git show $COMMIT:$FILENAME > ${FILENAME}.old"
        git show "$COMMIT:$FILENAME" > "${FILENAME}.old"
        echo ""
        echo "✓ Saved to ${FILENAME}.old"
        echo "Compare with: vi $FILENAME ${FILENAME}.old"
        ;;
    2)
        echo "⚠️  This will replace your current $FILENAME"
        echo "Type 'yes' to confirm:"
        read -r CONFIRM
        if [ "$CONFIRM" = "yes" ]; then
            run_git checkout "$COMMIT" -- "$FILENAME"
            echo "✓ File restored from commit $COMMIT"
            echo "Now run: ./sync-this.sh \"Restored $FILENAME from $COMMIT\""
        else
            echo "Cancelled."
        fi
        ;;
    3)
        echo "=== Differences between $COMMIT and current ==="
        run_git diff "$COMMIT" HEAD -- "$FILENAME"
        ;;
    4)
        echo "Exiting."
        ;;
    *)
        echo "Invalid choice. Exiting."
        ;;
esac
SCRIPT_EOF

# ============================================
# Script 2: show-history
# ============================================
echo "Installing show-history..."
cat > "$INSTALL_DIR/show-history" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

if [ -z "$1" ]; then
    echo "Usage: show-history <filename>"
    echo "Example: show-history sync-this.sh"
    exit 1
fi

FILENAME="$1"

echo "=== Complete history of: $FILENAME ==="
echo ""
run_git log --follow --pretty=format:"%h | %ad | %s" --date=short "$FILENAME"
echo ""
echo ""
echo "Tip: Use 'get-previous $FILENAME' to recover an old version"
SCRIPT_EOF

# ============================================
# Script 3: git-undo
# ============================================
echo "Installing git-undo..."
cat > "$INSTALL_DIR/git-undo" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

echo "=== Git Undo Helper ==="
echo ""
echo "Current status:"
run_git status --short

if [ -z "$(git status --porcelain)" ]; then
    echo "No uncommitted changes found."
    echo ""
    echo "Do you want to undo your last commit?"
    echo "1) Undo last commit, keep the changes (to re-edit)"
    echo "2) Undo last commit, throw away the changes (danger!)"
    echo "3) Never mind"
    read -r CHOICE
    
    case $CHOICE in
        1)
            echo "Last commit:"
            run_git log -1 --oneline
            echo "Type 'yes' to undo this commit but keep your files:"
            read -r CONFIRM
            if [ "$CONFIRM" = "yes" ]; then
                run_git reset --soft HEAD~1
                echo "✓ Commit undone. Your changes are still in your files."
            fi
            ;;
        2)
            echo "⚠️  DANGER: This will permanently delete your last commit's changes!"
            echo "Last commit:"
            run_git log -1 --oneline
            echo ""
            echo "Type 'yes I am sure' to proceed:"
            read -r CONFIRM
            if [ "$CONFIRM" = "yes I am sure" ]; then
                run_git reset --hard HEAD~1
                echo "✓ Commit and changes deleted."
            fi
            ;;
        3)
            echo "Cancelled."
            ;;
    esac
else
    echo "You have uncommitted changes. What do you want to undo?"
    echo "1) Throw away ALL my edits since last commit"
    echo "2) Throw away changes to ONE file"
    echo "3) Never mind"
    read -r CHOICE
    
    case $CHOICE in
        1)
            echo "⚠️  This will delete ALL your edits since last commit!"
            echo "Type 'yes I am sure' to proceed:"
            read -r CONFIRM
            if [ "$CONFIRM" = "yes I am sure" ]; then
                run_git reset --hard HEAD
                echo "✓ All changes thrown away. Back to last commit."
            fi
            ;;
        2)
            echo "Which file?"
            run_git status --short
            echo "Enter filename:"
            read -r FILENAME
            if [ -n "$FILENAME" ]; then
                run_git checkout -- "$FILENAME"
                echo "✓ $FILENAME restored to last committed version."
            fi
            ;;
        3)
            echo "Cancelled."
            ;;
    esac
fi
SCRIPT_EOF

# ============================================
# Script 4: safe-experiment
# ============================================
echo "Installing safe-experiment..."
cat > "$INSTALL_DIR/safe-experiment" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

if [ -z "$1" ]; then
    echo "Usage: safe-experiment <experiment-name>"
    echo "Example: safe-experiment try-new-parser"
    echo ""
    echo "This creates a branch so you can experiment without breaking main."
    exit 1
fi

BRANCH_NAME="$1"

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  You have uncommitted changes:"
    run_git status --short
    echo "Commit them first? (yes/no)"
    read -r COMMIT_FIRST
    
    if [ "$COMMIT_FIRST" = "yes" ]; then
        echo "Enter commit message:"
        read -r MSG
        run_git add -A
        run_git commit -m "$MSG"
        run_git push
    else
        echo "Please commit or stash your changes first."
        exit 1
    fi
fi

echo "Creating experimental branch: $BRANCH_NAME"
run_git checkout -b "$BRANCH_NAME"

echo "✓ You're now on branch: $BRANCH_NAME"
echo ""
echo "Work freely! When done:"
echo "  - If it worked: merge-experiment $BRANCH_NAME"
echo "  - If it failed: abandon-experiment"
SCRIPT_EOF

# ============================================
# Script 5: merge-experiment
# ============================================
echo "Installing merge-experiment..."
cat > "$INSTALL_DIR/merge-experiment" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

if [ -z "$1" ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" = "main" ]; then
        echo "Usage: merge-experiment <branch-name>"
        echo "You're on main. Switch to your experiment branch first."
        exit 1
    fi
    BRANCH_NAME="$CURRENT_BRANCH"
else
    BRANCH_NAME="$1"
fi

echo "Merging experiment branch: $BRANCH_NAME into main"
echo ""

# Commit any changes first
if [ -n "$(git status --porcelain)" ]; then
    echo "Committing current changes..."
    echo "Enter commit message:"
    read -r MSG
    run_git add -A
    run_git commit -m "$MSG"
fi

# Switch to main and merge
run_git checkout main
run_git merge "$BRANCH_NAME"

if [ $? -eq 0 ]; then
    echo "✓ Experiment merged successfully!"
    echo ""
    echo "Push to GitHub? (yes/no)"
    read -r PUSH
    if [ "$PUSH" = "yes" ]; then
        run_git push
    fi
    
    echo ""
    echo "Delete experiment branch? (yes/no)"
    read -r DELETE
    if [ "$DELETE" = "yes" ]; then
        echo "📍 Running: git branch -d $BRANCH_NAME"
        git branch -d "$BRANCH_NAME"
        echo ""
        echo "✓ Branch deleted."
    fi
else
    echo ""
    echo "⚠️  Merge had conflicts. Resolve them, then run:"
    echo "  git commit"
    echo "  git push"
fi
SCRIPT_EOF

# ============================================
# Script 6: abandon-experiment
# ============================================
echo "Installing abandon-experiment..."
cat > "$INSTALL_DIR/abandon-experiment" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" = "main" ]; then
    echo "You're on main branch. Nothing to abandon."
    exit 0
fi

echo "⚠️  You're about to abandon branch: $CURRENT_BRANCH"
echo "All changes on this branch will be lost."
echo ""
echo "Type 'abandon' to confirm:"
read -r CONFIRM

if [ "$CONFIRM" = "abandon" ]; then
    run_git checkout main
    echo "📍 Running: git branch -D $CURRENT_BRANCH"
    git branch -D "$CURRENT_BRANCH"
    echo ""
    echo "✓ Branch abandoned. You're back on main with your safe code."
else
    echo "Cancelled."
fi
SCRIPT_EOF

# ============================================
# Script 7: what-changed
# ============================================
echo "Installing what-changed..."
cat > "$INSTALL_DIR/what-changed" << 'SCRIPT_EOF'
#!/bin/bash

# Helper function to show and run git commands
run_git() {
    echo "📍 Running: git $@"
    git "$@"
    local result=$?
    echo ""
    return $result
}

if [ -z "$1" ]; then
    echo "Usage: what-changed <commit1> <commit2> [filename]"
    echo "Example: what-changed v2.0 v4.0"
    echo "Example: what-changed v2.0 HEAD sync-this.sh"
    echo ""
    echo "Shows what changed between two commits"
    exit 1
fi

COMMIT1="$1"
COMMIT2="${2:-HEAD}"
FILENAME="$3"

if [ -n "$FILENAME" ]; then
    echo "=== Changes to $FILENAME between $COMMIT1 and $COMMIT2 ==="
    run_git diff "$COMMIT1" "$COMMIT2" -- "$FILENAME"
else
    echo "=== All changes between $COMMIT1 and $COMMIT2 ==="
    run_git diff "$COMMIT1" "$COMMIT2" --stat
    echo ""
    echo "For detailed changes, run:"
    echo "  git diff $COMMIT1 $COMMIT2"
fi
SCRIPT_EOF

# Make all scripts executable
echo ""
echo "Making scripts executable..."
chmod +x "$INSTALL_DIR/get-previous"
chmod +x "$INSTALL_DIR/show-history"
chmod +x "$INSTALL_DIR/git-undo"
chmod +x "$INSTALL_DIR/safe-experiment"
chmod +x "$INSTALL_DIR/merge-experiment"
chmod +x "$INSTALL_DIR/abandon-experiment"
chmod +x "$INSTALL_DIR/what-changed"

# Check if bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "⚠️  $INSTALL_DIR is not in your PATH"
    echo ""
    echo "Add this line to your ~/.zshrc or ~/.bashrc:"
    echo "    export PATH=\"\$HOME/bin:\$PATH\""
    echo ""
    echo "Then run: source ~/.zshrc"
    echo ""
    
    read -p "Would you like me to add it to ~/.zshrc now? (yes/no): " ADD_PATH
    if [ "$ADD_PATH" = "yes" ]; then
        echo "" >> ~/.zshrc
        echo "# Added by git-helpers installer" >> ~/.zshrc
        echo "export PATH=\"\$HOME/bin:\$PATH\"" >> ~/.zshrc
        echo "✓ Added to ~/.zshrc"
        echo "Run: source ~/.zshrc"
    fi
fi

echo ""
echo "=========================================="
echo "✓ Installation Complete!"
echo "=========================================="
echo ""
echo "Installed scripts:"
echo "  - get-previous      (recover old versions of files)"
echo "  - show-history      (see file history)"
echo "  - git-undo          (undo commits or changes)"
echo "  - safe-experiment   (create experiment branch)"
echo "  - merge-experiment  (merge successful experiment)"
echo "  - abandon-experiment (discard failed experiment)"
echo "  - what-changed      (compare versions)"
echo ""
echo "See GIT-HELPERS-GUIDE.md for usage examples"
echo ""

if [ $EXISTING_SCRIPTS -eq 1 ]; then
    echo "Old scripts backed up to: $BACKUP_DIR"
    echo ""
fi
