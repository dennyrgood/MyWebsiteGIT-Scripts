#Requires -Version 5.1
<#
.SYNOPSIS
    Sync every Git repository under the repo root (default: $HOME\repos).
    PowerShell equivalent of the bash `sync-all` script.

.PARAMETER Message
    Commit message used for every repo. Prompted for if omitted.

.PARAMETER RepoRoot
    Directory to search for repositories. Defaults to the first of C:\repos,
    D:\repos (amsterdamdesktop), or $HOME\repos that exists.

.PARAMETER DryRun
    Show what would happen without committing, pulling, or pushing.

.PARAMETER All
    Process all repos, even ones that are clean and up-to-date.

.EXAMPLE
    .\sync-all.ps1
    .\sync-all.ps1 "nightly sync" -DryRun
    .\sync-all.ps1 -All
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message,
    [string]$RepoRoot,
    [switch]$DryRun,
    [switch]$All
)

$ErrorActionPreference = 'Continue'

# --- CONFIGURATION ---
$UseRebase     = $true
$VerifyCommits = $true   # $false adds --no-verify (skip pre-commit hooks)
$ShowCommands  = $true
$SkipCleanRepos = -not $All

# --- REPO ROOT: C:\repos everywhere except amsterdamdesktop, which uses D:\repos ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $candidates = @('C:\repos', 'D:\repos', (Join-Path $HOME 'repos'))
    $RepoRoot = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $RepoRoot) {
        Write-Error "No repo root found. Tried: $($candidates -join ', '). Pass -RepoRoot explicitly."
        exit 1
    }
}

$startDir  = Get-Location
$errorCount = 0
$skipCount  = 0
$totalProcessed = 0

function Get-BranchStatus {
    param([string]$Branch)
    git fetch origin $Branch --quiet 2>$null
    $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) {
        return "No upstream set (will use -u on push)"
    }
    $ahead  = [int](git rev-list --count '@{u}..HEAD' 2>$null)
    $behind = [int](git rev-list --count 'HEAD..@{u}' 2>$null)
    if ($ahead -gt 0 -and $behind -gt 0) { return "^ $ahead ahead, v $behind behind" }
    elseif ($ahead -gt 0)  { return "^ $ahead ahead (needs push)" }
    elseif ($behind -gt 0) { return "v $behind behind (needs pull)" }
    else { return "Up to date" }
}

Write-Host "=========================================="
Write-Host "          MULTI-REPO SYNC SETUP           "
Write-Host "=========================================="
if ($DryRun) { Write-Host "DRY RUN MODE - No changes will be made"; Write-Host "" }

if ([string]::IsNullOrWhiteSpace($Message)) {
    Write-Host "Enter commit message (or press Enter for default):"
    $Message = Read-Host
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "Auto-sync from local changes" }
}
Write-Host "Using message: `"$Message`""
Write-Host "Root Directory: $RepoRoot"
Write-Host "=========================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    Write-Host "=========================================="
    Write-Error "Repository root directory not found: $RepoRoot"
    Write-Host "=========================================="
    exit 1
}

# --- FIND REPOSITORIES (.git up to 3 levels deep, excluding backup dirs) ---
$repos = Get-ChildItem -LiteralPath $RepoRoot -Directory -Filter '.git' -Depth 2 -Force -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Parent.FullName } |
    Where-Object { $_ -notmatch '\.bkup|\.bak|_backup|_bak' } |
    Sort-Object -Unique

Write-Host "Found $($repos.Count) repositories to process."
Write-Host ""

foreach ($repoPath in $repos) {
    $repoName = Split-Path $repoPath -Leaf
    $repoFailed = $false

    try { Set-Location -LiteralPath $repoPath -ErrorAction Stop }
    catch {
        Write-Host "=========================================="
        Write-Error "$repoName : ERROR - Cannot access directory"
        Write-Host "=========================================="
        $errorCount++
        Set-Location $startDir
        continue
    }

    Write-Host "=========================================="
    Write-Host "[repo] $repoName"
    Write-Host "=========================================="
    $totalProcessed++

    $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $branch = '' } else { $branch = $branch.Trim() }

    if ($branch -eq 'HEAD' -or -not $branch) {
        Write-Host "   Detached HEAD state - skipping (not on any branch)"
        Write-Host "      Tip: Run 'git checkout -b <branch-name>' to fix."
        $skipCount++
        Write-Host "------------------------------------------"
        Set-Location $startDir
        continue
    }

    Write-Host "   Branch: $branch"
    Write-Host "   Pre-Sync Remote: $(Get-BranchStatus $branch)"

    # --- Local changes (tracked + untracked) ---
    $hasChanges = $false
    $porcelain = @(git status --porcelain)
    $tracked   = @($porcelain | Where-Object { $_ -notmatch '^\?\?' })
    $untracked = @(git ls-files --others --exclude-standard)

    if ($tracked.Count -gt 0) {
        $hasChanges = $true
        Write-Host "   Files Changed Locally (Staging):"
        $tracked | ForEach-Object { Write-Host "      $_" }
    }
    if ($untracked.Count -gt 0) {
        $hasChanges = $true
        Write-Host "   Untracked Files Found: $($untracked.Count)"
        $untracked | Select-Object -First 10 | ForEach-Object { Write-Host "      ?? $_" }
        if ($untracked.Count -gt 10) {
            Write-Host "      ... and $($untracked.Count - 10) more"
        }
    }
    if (-not $hasChanges) { Write-Host "   Local Files: Clean working directory" }

    # --- Skip clean + up-to-date repos ---
    if (-not $hasChanges -and $SkipCleanRepos) {
        git fetch origin $branch --quiet 2>$null
        $local  = (git rev-parse '@' 2>$null)
        $remote = (git rev-parse '@{u}' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote -and $local -eq $remote) {
            Write-Host "   ------------------------------------------"
            Write-Host "   Skipping: Repository is clean and up-to-date."
            $skipCount++
            Write-Host "------------------------------------------"
            Set-Location $startDir
            continue
        }
    }

    Write-Host "   ------------------------------------------"
    Write-Host "   >>> START TRANSACTION <<<"

    # --- COMMIT ---
    if ($ShowCommands) { Write-Host "   Running: git add -A" }
    git add -A

    $staged = git diff --staged --name-only
    if (-not [string]::IsNullOrWhiteSpace($staged)) {
        $commitArgs = @('commit', '-m', $Message)
        if (-not $VerifyCommits) { $commitArgs += '--no-verify' }
        if ($ShowCommands) { Write-Host "   Running: git commit -m `"$Message`"" }

        if ($DryRun) {
            Write-Host "   [DRY RUN] Would commit changes with message: `"$Message`""
        } else {
            git @commitArgs | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "   Commit Successful"
            } else {
                Write-Error "   Commit failed in $repoName"
                Write-Host "      Tip: Check pre-commit hooks. Run 'git commit' manually."
                $errorCount++
                $repoFailed = $true
            }
        }
    } else {
        Write-Host "   No new changes to commit."
    }

    if ($repoFailed) {
        Write-Host "   >>> TRANSACTION FAILED (Commit) <<<"
        Write-Host "------------------------------------------"
        Set-Location $startDir
        continue
    }

    # --- PULL ---
    $pullArgs = @('pull')
    if ($UseRebase) { $pullArgs += '--rebase' }
    $pullArgs += @('origin', $branch)
    if ($ShowCommands) { Write-Host "   Running: git $($pullArgs -join ' ')" }

    if ($DryRun) {
        Write-Host "   [DRY RUN] Would pull from origin/$branch"
        $pullOutput = "Already up to date."
        $pullExit = 0
    } else {
        $pullOutput = (git @pullArgs 2>&1 | Out-String)
        $pullExit = $LASTEXITCODE
    }

    if ($pullExit -ne 0) {
        if ($pullOutput -match '(?i)conflict') {
            Write-Error "   MERGE CONFLICT in $repoName. Resolve manually."
        } else {
            Write-Error "   Pull failed unexpectedly in $repoName."
        }
        $errorCount++
        $repoFailed = $true
    } elseif ($pullOutput -notmatch '(?i)up.to.date') {
        Write-Host "   Pulled remote changes."
    } else {
        Write-Host "   Pull: Already up to date."
    }

    if ($repoFailed) {
        Write-Host "   >>> TRANSACTION FAILED (Pull) <<<"
        Write-Host "------------------------------------------"
        Set-Location $startDir
        continue
    }

    # --- PUSH ---
    if ($ShowCommands) { Write-Host "   Running: git push -u origin $branch" }
    if ($DryRun) {
        Write-Host "   [DRY RUN] Would push local changes to remote."
        $pushOutput = "Everything up-to-date"
        $pushExit = 0
    } else {
        $pushOutput = (git push -u origin $branch 2>&1 | Out-String)
        $pushExit = $LASTEXITCODE
    }

    if ($pushExit -ne 0) {
        Write-Error "   Push failed in $repoName. Check authentication or remote status."
        $errorCount++
    } elseif ($pushOutput -notmatch '(?i)up.to.date') {
        Write-Host "   Push Successful."
    } else {
        Write-Host "   Push: Nothing new to send."
    }

    # --- POST-SYNC STATUS ---
    Write-Host "   ------------------------------------------"
    Write-Host "   >>> POST-SYNC STATUS <<<"
    Write-Host "   Remote: $(Get-BranchStatus $branch)"
    Write-Host "   Local: $(@(git status --porcelain).Count) unstaged/staged files."
    Write-Host "   Last Commit: $(git log --oneline -1)"
    Write-Host "------------------------------------------"
    Set-Location $startDir
}

# --- SUMMARY ---
Set-Location $startDir
$successCount = $totalProcessed - $errorCount - $skipCount

Write-Host "=========================================="
Write-Host "          MULTI-REPO SYNC SUMMARY         "
Write-Host "=========================================="
Write-Host "Total Repositories Found: $($repos.Count)"
Write-Host "Repositories Processed:   $totalProcessed"
Write-Host "Successful Syncs:         $successCount"
if ($skipCount -gt 0)  { Write-Host "Skipped (Clean):          $skipCount (use -All to process)" }
if ($errorCount -gt 0) { Write-Host "Errors / Conflicts:       $errorCount" }
Write-Host "=========================================="

if ($errorCount -gt 0) {
    Write-Host "Completed with ERRORS. Review output above and resolve conflicts manually."
    exit 1
} elseif ($successCount -le 0 -and $totalProcessed -gt 0) {
    Write-Host "All repositories were already clean and up-to-date (or were skipped)."
    exit 0
} else {
    Write-Host "All targeted repositories synced successfully."
    exit 0
}
