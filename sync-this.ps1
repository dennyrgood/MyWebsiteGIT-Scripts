#Requires -Version 5.1
<#
.SYNOPSIS
    Sync the current Git repository: commit, pull --rebase, push.
    PowerShell equivalent of the bash `sync-this` script.

.PARAMETER Message
    Commit message. If omitted you will be prompted (Enter accepts the default).

.EXAMPLE
    .\sync-this.ps1
    .\sync-this.ps1 "fix the widget"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message
)

$ErrorActionPreference = 'Continue'

function Write-Rule { param([string]$Text)
    Write-Host "=========================================="
    if ($Text) { Write-Host $Text }
    if ($Text) { Write-Host "==========================================" }
}

# --- Must be inside a repo ---
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "This folder is not a Git repository."
    exit 1
}

Write-Rule "         GIT SYNC: PRE-SYNC STATUS        "

# --- 1. Current branch status ---
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -eq 'HEAD') {
    Write-Error "Detached HEAD state - not on any branch. Run 'git checkout -b <name>' first."
    exit 1
}
Write-Host "=== Branch: $branch ==="

$upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
if ($LASTEXITCODE -eq 0 -and $upstream) {
    Write-Host "Tracking: $($upstream.Trim())"
    git fetch --quiet 2>$null
    $ahead  = [int](git rev-list --count '@{u}..HEAD' 2>$null)
    $behind = [int](git rev-list --count 'HEAD..@{u}' 2>$null)
    if ($ahead -gt 0 -or $behind -gt 0) {
        Write-Host "Status: ^ $ahead ahead, v $behind behind."
    } else {
        Write-Host "Status: Up to date with remote"
    }
} else {
    Write-Host "No upstream branch set - will set one during push."
}

Write-Host ""
Write-Host "=== Files Changed Locally ==="
$dirty = git status --porcelain
if ([string]::IsNullOrWhiteSpace($dirty)) {
    Write-Host "No changes to commit"
} else {
    git status --short
}

Write-Rule "       GIT SYNC: START TRANSACTION        "

# --- 2. Commit message ---
$default = "Cleaning up files/sync from local to remote branch: $branch"
if ([string]::IsNullOrWhiteSpace($Message)) {
    Write-Host "Enter commit message (or press Enter to use default):"
    $Message = Read-Host
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = $default }
}
Write-Host "--- Using commit message: `"$Message`" ---"

# --- Stage + commit ---
Write-Host "Staging all changes..."
git add -A

$staged = git diff --staged --name-only
if ([string]::IsNullOrWhiteSpace($staged)) {
    Write-Host "No new local changes were committed."
} else {
    Write-Host "Committing staged changes..."
    git commit -m $Message
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Commit failed. Check pre-commit hooks; run 'git commit' manually."
        exit 1
    }
}

# --- Pull ---
Write-Host ""
Write-Host "--- Running git pull --rebase ---"
git pull --rebase origin $branch
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pull failed (possible conflict). Resolve manually, then re-run."
    exit 1
}

# --- Push ---
Write-Host ""
Write-Host "--- Running git push to update remote ---"
git push -u origin $branch
if ($LASTEXITCODE -ne 0) {
    Write-Error "Push failed. Check authentication or remote status."
    exit 1
}

Write-Rule "          GIT SYNC: FINAL STATUS          "
Write-Host "Current repository status after sync:"
git status
Write-Host ""
Write-Host "Last 5 Commits (check for new commit):"
git log --oneline -5
Write-Rule "           GIT SYNC: FINISHED             "
