<#
.SYNOPSIS
  Snapshot a ComfyUI-Easy-Install (or portable) install tree, excluding the OneDrive-linked
  input/output/models/workflows dirs (junctions/symlinks) so the backup doesn't try to
  duplicate your model library or OneDrive image history.

.DESCRIPTION
  Dry run by default (robocopy /L, lists what it would do, copies nothing). Pass -Apply to
  actually copy. Uses robocopy so it's resumable/mirrorable and handles long paths cleanly.

  Excludes (by exact path, not bare name, so nothing unrelated gets caught):
    ComfyUI\input
    ComfyUI\output
    ComfyUI\models
    ComfyUI\user\default\workflows
  Plus /XJ as a backstop to skip any other junction/symlink robocopy encounters.

  Never deletes anything. If -BackupRoot already exists and is non-empty, it refuses to run
  (use a fresh path, or clear the old backup out yourself first with an explicit look at what's
  in it).

.PARAMETER ComfyRoot
  Source install root, e.g. C:\ComfyUI_easy\ComfyUI-Easy-Install

.PARAMETER BackupRoot
  Destination path for the snapshot, e.g. 'C:\ComfyUI_easy\ComfyUI-Easy-Install - BACKUP - 2026-09-01'
  Not required to exist yet; robocopy creates it.

.PARAMETER IncludeModels
  Also copy ComfyUI\models\. Leave this OFF (default) when models\ is itself a junction/symlink
  to external storage (travelbeast/chatworkhorse -- OneDrive Models_bare already IS the backup,
  no need to duplicate it). Turn this ON for a box where models\ is a real local folder holding
  actual data not otherwise backed up (e.g. imagebeast, which mixes a real local models\ tree
  with extra_model_paths.yaml -- some categories only exist locally, not under the yaml's
  base_path, so skipping models\ there would silently produce an incomplete backup).

.PARAMETER Apply
  Actually copy. Without this, robocopy runs in /L (list-only) mode.

.EXAMPLE
  .\backup-comfyui-install.ps1 -ComfyRoot 'C:\ComfyUI-Easy-Install' -BackupRoot 'C:\ComfyUI-Easy-Install - BACKUP - 2026-09-01'
.EXAMPLE
  .\backup-comfyui-install.ps1 -ComfyRoot 'C:\ComfyUI-Easy-Install' -BackupRoot 'C:\ComfyUI-Easy-Install - BACKUP - 2026-09-01' -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComfyRoot,

    [Parameter(Mandatory = $true)]
    [string]$BackupRoot,

    [switch]$IncludeModels,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ComfyRoot)) { throw "Source not found: $ComfyRoot" }

if (Test-Path $BackupRoot) {
    $existingCount = (Get-ChildItem -Path $BackupRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($existingCount -gt 0) {
        throw "BackupRoot '$BackupRoot' already exists and is not empty ($existingCount item(s)). Refusing to copy into it -- pick a fresh path, or clear it out yourself deliberately first."
    }
}

$excludeDirs = @(
    (Join-Path $ComfyRoot 'ComfyUI\input'),
    (Join-Path $ComfyRoot 'ComfyUI\output'),
    (Join-Path $ComfyRoot 'ComfyUI\user\default\workflows')
)
if (-not $IncludeModels) {
    $excludeDirs += (Join-Path $ComfyRoot 'ComfyUI\models')
}

Write-Host "Source:      $ComfyRoot"
Write-Host "Destination: $BackupRoot"
Write-Host "Excluding:"
$excludeDirs | ForEach-Object { Write-Host "  $_" }
Write-Host "Also excluding: any other junction/symlink robocopy encounters (/XJ)"
Write-Host "Mode: $(if ($Apply) { 'APPLY (copying)' } else { 'DRY RUN (/L -- listing only, nothing copied)' })"
Write-Host ""

$robocopyArgs = @(
    $ComfyRoot, $BackupRoot,
    '/E',      # copy subdirectories, including empty ones
    '/XJ',     # skip junctions/symlinks entirely
    '/XD'
) + $excludeDirs + @(
    '/R:2', '/W:5',   # limited retries -- don't hang forever on a locked file
    '/NFL', '/NDL',   # don't spam a full file/dir listing to the console
    '/TEE'
)

if (-not $Apply) {
    $robocopyArgs += '/L'
}

robocopy @robocopyArgs
$code = $LASTEXITCODE

# robocopy exit codes 0-7 are all "success" (bitmask of what happened); 8+ means real errors.
if ($code -ge 8) {
    Write-Error "robocopy reported errors (exit code $code). Review output above before trusting this backup."
    exit $code
}

Write-Host ""
Write-Host "robocopy finished (exit code $code -- $(if ($code -eq 0) { 'no changes needed / nothing to copy' } else { 'files copied, see summary above' }))."
if (-not $Apply) {
    Write-Host "This was a dry run. Rerun with -Apply to actually copy."
}
