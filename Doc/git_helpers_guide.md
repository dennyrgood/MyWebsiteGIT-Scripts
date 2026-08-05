# Git Helper Scripts Guide

A collection of interactive scripts that make git easier to use while teaching you the underlying git commands.

## Installation

```bash
chmod +x install-git-helpers.sh
./install-git-helpers.sh
source ~/.zshrc  # or ~/.bashrc
```

---

## Quick Reference

| Script | Purpose | Example |
|--------|---------|---------|
| `get-previous` | Recover old version of a file | `get-previous sync-this.sh` |
| `show-history` | See all changes to a file | `show-history myfile.py` |
| `git-undo` | Undo commits or changes | `git-undo` |
| `safe-experiment` | Try things without breaking main | `safe-experiment try-new-idea` |
| `merge-experiment` | Merge successful experiment | `merge-experiment` |
| `abandon-experiment` | Discard failed experiment | `abandon-experiment` |
| `what-changed` | Compare two versions | `what-changed v2.0 v4.0` |

---

## Detailed Usage

### 📁 get-previous

**Recover an old version of a file**

```bash
get-previous sync-this.sh
```

Shows you:
- Recent commits that modified the file
- Lets you pick which version you want
- Options to:
  - Save as `.old` file for comparison
  - Replace current file with old version
  - Just see the differences

**Git commands you'll learn:**
- `git log --oneline --follow -10 <file>`
- `git show <commit>:<file>`
- `git checkout <commit> -- <file>`
- `git diff <commit> HEAD -- <file>`

**Example workflow:**
```bash
# Your sync-this.sh is broken
get-previous sync-this.sh
# Enter: 7da1111 (the working version)
# Choose: 2 (replace current file)
./sync-this.sh "Restored sync-this from working version"
```

---

### 📜 show-history

**See the complete history of a file**

```bash
show-history inject.py
```

Shows chronological list of all changes with:
- Commit hash
- Date
- Commit message

**Git command you'll learn:**
- `git log --follow --pretty=format:"%h | %ad | %s" --date=short <file>`

**Use case:**
```bash
# "When did I break the parser?"
show-history parser.py
# See all changes, find the commit before it broke
```

---

### ↩️ git-undo

**Interactive undo helper**

```bash
git-undo
```

Guides you through:
- Undoing uncommitted changes to all files
- Undoing changes to one specific file
- Undoing your last commit (keeping or discarding changes)

**Git commands you'll learn:**
- `git status --short`
- `git reset --soft HEAD~1` (undo commit, keep changes)
- `git reset --hard HEAD~1` (undo commit, discard changes)
- `git reset --hard HEAD` (discard all uncommitted changes)
- `git checkout -- <file>` (discard changes to one file)

**Example scenarios:**

*Broke something, want to start over:*
```bash
git-undo
# Choose: 1 (throw away all edits)
# Confirm: yes I am sure
```

*Made a typo in commit message:*
```bash
git-undo
# Choose: 1 (undo last commit, keep changes)
# Now re-commit with correct message
```

---

### 🧪 safe-experiment

**Create a branch for experimenting**

```bash
safe-experiment try-claude-refactor
```

Creates a new branch so you can:
- Try risky changes
- Test AI suggestions
- Experiment freely
- Without risking your working code on main

**Git commands you'll learn:**
- `git status --porcelain`
- `git add -A`
- `git commit -m "message"`
- `git checkout -b <branch-name>`

**Example workflow:**
```bash
# Claude suggests a big refactor
safe-experiment claude-refactor
# Make changes, test them
./sync-this.sh "Trying Claude's suggestion"
# Run tests...
```

---

### ✅ merge-experiment

**Merge successful experiment back to main**

```bash
merge-experiment
# Or specify: merge-experiment claude-refactor
```

When your experiment worked:
- Commits any uncommitted changes
- Switches to main
- Merges your experiment branch
- Optionally pushes to GitHub
- Optionally deletes the experiment branch

**Git commands you'll learn:**
- `git checkout main`
- `git merge <branch-name>`
- `git push`
- `git branch -d <branch-name>`

**Example:**
```bash
# Your experiment worked!
merge-experiment
# Push to GitHub? yes
# Delete experiment branch? yes
```

---

### ❌ abandon-experiment

**Discard a failed experiment**

```bash
abandon-experiment
```

When your experiment failed:
- Returns you to main branch
- Deletes the experiment branch
- Your main branch is untouched (still has working code)

**Git commands you'll learn:**
- `git checkout main`
- `git branch -D <branch-name>` (force delete)

**Example:**
```bash
# Experiment didn't work out
abandon-experiment
# Type: abandon
# Back to safety on main branch
```

---

### 🔍 what-changed

**Compare any two versions**

```bash
# Compare two releases
what-changed v2.0 v4.0

# Compare commit to current
what-changed 7da1111 HEAD

# Compare specific file between versions
what-changed v2.0 v4.0 inject.py
```

**Git commands you'll learn:**
- `git diff <commit1> <commit2>`
- `git diff <commit1> <commit2> --stat`
- `git diff <commit1> <commit2> -- <file>`

**Use cases:**
```bash
# "What did I change between v2 and v4?"
what-changed v2.0 v4.0

# "What changed in this file since last release?"
what-changed v3.0 HEAD inject.py
```

---

## Workflow Examples

### Scenario 1: Try AI Suggestion Safely

```bash
# Starting with working code on main
./sync-this.sh "Working version before AI experiment"

# Create experiment branch
safe-experiment try-ai-suggestion

# Paste AI code, test it
vi myfile.py
python myfile.py

# Works? Merge it!
merge-experiment

# Broken? Abandon it!
abandon-experiment
```

### Scenario 2: Recover Old Working Code

```bash
# Current code is broken
show-history myfile.py
# Find the last working version (say 7da1111)

get-previous myfile.py
# Enter: 7da1111
# Choose: 2 (replace)

./sync-this.sh "Restored working version of myfile"
```

### Scenario 3: Oops, Didn't Mean to Change That

```bash
# Edited 5 files, but one edit was wrong
git-undo
# Choose: 2 (throw away changes to one file)
# Enter: badfile.py

# Now just commit the other 4 files
./sync-this.sh "Fixed the parser (reverted accidental changes to badfile)"
```

### Scenario 4: Google Photos Breaks Your Code Again

```bash
# Current code stops working
show-history inject.py
# See: v4.0 was last working version

# Start from working version
safe-experiment fix-google-dec-2024

# Try fixes...
./sync-this.sh "Attempt 1: new scroll approach"
# Test... doesn't work

./sync-this.sh "Attempt 2: different timing"
# Test... works!

# Merge it back
merge-experiment
git tag -a v4.1 -m "Fixed for Google Dec 2024 update"
git push --tags
```

---

## Tips & Tricks

### Always See What Changed First
```bash
git status          # before using git-undo
show-history file   # before using get-previous
what-changed v1 v2  # before merging versions
```

### Commit Often
```bash
# Every time something works
./sync-this.sh "Parser working with new data format"
# Creates a restore point you can always get back to
```

### Use Branches for Experiments
```bash
# Instead of:
cp myfile.py myfile-backup.py  # DON'T DO THIS

# Do this:
safe-experiment try-new-approach
# Edit freely, then merge or abandon
```

### Compare Releases
```bash
# See what changed between versions
what-changed v2.0 v3.0

# Helpful when deciding which version to use
```

### Tag Stable Versions
```bash
# After successful merge
git tag -a v4.1 -m "Stable: Fixed Google Photos Dec 2024"
git push --tags
```

---

## Learning Git Commands

Every helper script shows the actual git commands it runs with a 📍 marker:

```
📍 Running: git log --oneline --follow -10 sync-this.sh
📍 Running: git show 7da1111:sync-this.sh
📍 Running: git checkout 7da1111 -- sync-this.sh
```

After using the helpers for a while, you'll naturally learn:
- When to use each command
- What the options mean
- How to use git directly

**Eventually you might just type:**
```bash
git log --oneline -10
git checkout abc1234 -- myfile.py
```

But the helpers are always there when you need guidance!

---

## Troubleshooting

### "Script not found"
```bash
# Make sure ~/bin is in your PATH
echo $PATH | grep "$HOME/bin"

# If not, add to ~/.zshrc:
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### "Permission denied"
```bash
chmod +x ~/bin/get-previous
chmod +x ~/bin/show-history
# ... etc for all scripts
```

### "Detached HEAD state"
```bash
# Just ran: git checkout abc1234
# Now you're looking at old code
# To get back:
git checkout main
```

### Scripts showing weird characters
```bash
# If you see encoding issues, your script might have
# gotten corrupted during copy/paste
# Re-run: ./install-git-helpers.sh
```

---

## Cheat Sheet

**Before ANY risky change:**
```bash
./sync-this.sh "Working version before trying X"
```

**When experimenting:**
```bash
safe-experiment <name>
# work...
merge-experiment    # if it worked
abandon-experiment  # if it failed
```

**When something breaks:**
```bash
show-history <file>
get-previous <file>
```

**When you make a mistake:**
```bash
git-undo
```

**To see what changed:**
```bash
what-changed <old> <new>
```

---

## Your Workflow Integration

### With sync-this.sh
```bash
# Works perfectly together!
./sync-this.sh "Description of changes"
# Already commits and pushes
```

### With Multiple AI Tools
```bash
# Before trying AI suggestion:
safe-experiment try-claude-idea

# After pasting AI code:
./sync-this.sh "Testing Claude suggestion"

# If broken:
abandon-experiment

# If works:
merge-experiment
```

### With vi
```bash
# In vi, you can run git commands:
:!git status
:!git log --oneline -5
:!show-history %
```

---

## Getting Help

Each script has built-in help:
```bash
get-previous          # shows usage
show-history          # shows usage
safe-experiment       # shows usage
# etc.
```

All scripts are interactive and guide you through the process!

---

**Remember:** Git keeps everything. You can always recover old code. Experiment freely!
