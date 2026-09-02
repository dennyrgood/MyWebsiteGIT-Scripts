<#
.SYNOPSIS
  ComfyUI core + node update, without depending on Pixaroma's Easy-Install wrapper .bat
  as an ongoing dependency. Reimplements the same steps directly and transparently:
    1. git checkout master -q  (or plain pull if already on master)
    2. run the OFFICIAL ComfyUI portable updater: update\update.py
       (this ships with vanilla ComfyUI portable releases too, confirmed present
       byte-for-byte on a non-Pixaroma install as well; not Pixaroma-specific)
    3. pip install av==16.0.1            (known-working pin; newer av breaks on this stack)
    4. pip install --force-reinstall numpy==1.26.4 --no-deps   (known-working pin)
    5. ComfyUI-Manager's own CLI: cm-cli.py update all   (standard tool, not Pixaroma's)
    6. clean stale "~*" partial-install folders under site-packages

.DESCRIPTION
  Dry run by default. Pass -Apply to actually change anything.

  Does NOT touch input/output/models/workflows junctions or symlinks, and does not create or
  remove any links, see relink-comfyui-dirs.ps1 for that, run separately if you want to verify.

.PARAMETER ComfyRoot
  Install root (folder containing ComfyUI\ and python_embeded\), e.g.
  C:\ComfyUI_easy\ComfyUI-Easy-Install, C:\ComfyUI-Easy-Install, C:\ComfyUI_windows_portable

.PARAMETER SwitchToMaster
  Required (with -Apply) if the repo is currently in detached HEAD (e.g. pinned to a tag).
  Separate flag on purpose, this is a bigger behavioral change than an ordinary pull.

.PARAMETER SkipNodeUpdate
  Skip the ComfyUI-Manager "update all" step (core-only update). Off by default.

.PARAMETER Apply
  Actually perform the update. Without this, only reports what it would do.

.EXAMPLE
  .\update-comfyui.ps1 -ComfyRoot 'C:\ComfyUI-Easy-Install'
.EXAMPLE
  .\update-comfyui.ps1 -ComfyRoot 'C:\ComfyUI-Easy-Install' -Apply
.EXAMPLE
  .\update-comfyui.ps1 -ComfyRoot 'C:\ComfyUI_easy\ComfyUI-Easy-Install' -SwitchToMaster -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComfyRoot,

    [switch]$SwitchToMaster,
    [switch]$SkipNodeUpdate,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$comfyDir  = Join-Path $ComfyRoot 'ComfyUI'
$pythonExe = Join-Path $ComfyRoot 'python_embeded\python.exe'
$updateDir = Join-Path $ComfyRoot 'update'
$updatePy  = Join-Path $updateDir 'update.py'
$sitePkgs  = Join-Path $ComfyRoot 'python_embeded\Lib\site-packages'
$cmCli     = Join-Path $comfyDir 'custom_nodes\ComfyUI-Manager\cm-cli.py'

if (-not (Test-Path $comfyDir))  { throw "No ComfyUI\ subfolder under $ComfyRoot" }
if (-not (Test-Path $pythonExe)) { throw "No embedded python at $pythonExe" }
if (-not (Test-Path $updatePy))  { throw "No official updater found at $updatePy -- this script expects the standard ComfyUI portable 'update\' folder to be present." }

Push-Location $comfyDir
try {
    Write-Host "=== $ComfyRoot ==="
    Write-Host "Mode: $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to actually update)' })"
    Write-Host ""

    $branch = git rev-parse --abbrev-ref HEAD
    $detached = ($branch -eq 'HEAD')
    $beforeCommit = git rev-parse --short HEAD
    $beforeDate = git log -1 --format='%ci'

    Write-Host "Current: $(if ($detached) { 'DETACHED HEAD' } else { "branch '$branch'" }) at $beforeCommit ($beforeDate)"
    Write-Host "  -> to roll back core after updating: git checkout $beforeCommit"
    Write-Host ""

    Write-Host "Fetching from origin (read-only)..."
    git fetch origin 2>&1 | Out-Null
    $behind = git rev-list --count "HEAD..origin/master"
    Write-Host "$behind commit(s) behind origin/master."
    if ($behind -gt 0) {
        git log --oneline "HEAD..origin/master" | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host ""

    if ($detached -and -not $SwitchToMaster) {
        Write-Warning "Detached HEAD. Pass -SwitchToMaster (with -Apply) to move onto master. Stopping (dry-run-safe)."
        return
    }

    if (-not $Apply) {
        Write-Host "[DRY RUN] Would run:"
        if ($detached) { Write-Host "  git checkout master" }
        Write-Host "  git checkout master -q   (fast-forwards on origin/master)"
        Write-Host "  $pythonExe $updatePy $comfyDir"
        Write-Host "  $pythonExe -m pip install av==16.0.1"
        Write-Host "  $pythonExe -m pip install --force-reinstall numpy==1.26.4 --no-deps"
        if (-not $SkipNodeUpdate) {
            if (Test-Path $cmCli) {
                Write-Host "  $pythonExe $cmCli update all"
            } else {
                Write-Host "  (ComfyUI-Manager cm-cli.py not found -- node update would be skipped)"
            }
        }
        return
    }

    if ($detached) {
        Write-Host "Switching from detached HEAD to master..."
        git checkout master
    }

    Write-Host "1/6: git checkout master -q"
    git checkout master -q
    git pull

    $afterCommit = git rev-parse --short HEAD
    $afterDate = git log -1 --format='%ci'
    Write-Host "Core now at $afterCommit ($afterDate)"
    Write-Host ""

    Write-Host "2/6: running official updater (update\update.py)"
    Pop-Location
    Push-Location $updateDir
    & $pythonExe '.\update.py' '..\ComfyUI\'
    if (Test-Path 'update_new.py') {
        Move-Item -Force 'update_new.py' 'update.py'
        Write-Host "Updater self-updated; running it again..."
        & $pythonExe '.\update.py' '..\ComfyUI\' '--skip_self_update'
    }
    Pop-Location
    Push-Location $comfyDir

    Write-Host "3/6: pinning av==16.0.1"
    & $pythonExe -s -m pip install 'av==16.0.1'

    Write-Host "4/6: cleaning stale '~*' partial-install folders"
    if (Test-Path $sitePkgs) {
        Get-ChildItem -Path $sitePkgs -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '~*' } |
            ForEach-Object {
                Write-Host "  removing stale $($_.FullName)"
                Remove-Item -Path $_.FullName -Recurse -Force
            }
    }

    if (-not $SkipNodeUpdate) {
        if (Test-Path $cmCli) {
            Write-Host "5/6: updating all custom nodes via ComfyUI-Manager"
            & $pythonExe -s $cmCli update all
        } else {
            Write-Warning "5/6: ComfyUI-Manager cm-cli.py not found at $cmCli -- skipping node update."
        }
    } else {
        Write-Host "5/6: skipped (-SkipNodeUpdate)"
    }

    Write-Host "6/6: pinning numpy==1.26.4"
    & $pythonExe -s -m pip install --force-reinstall 'numpy==1.26.4' --no-deps --no-cache-dir --no-warn-script-location --timeout=1000 --retries 5

    Write-Host ""
    Write-Host "Done. Core updated $beforeCommit -> $afterCommit."
    Write-Host "Restart ComfyUI and test a real saved workflow before considering this box done."
}
finally {
    Pop-Location
}
