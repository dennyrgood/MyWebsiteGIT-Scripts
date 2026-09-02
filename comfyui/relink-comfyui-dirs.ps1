<#
.SYNOPSIS
  Re-establish the OneDrive junction remaps (input/output/models/workflows) for a
  ComfyUI-Easy-Install (or portable) install on the current machine.

.DESCRIPTION
  Run this LOCALLY on the target Windows box (imagebeast / travelbeast / chatworkhorse),
  not over SSH, junction/symlink creation needs to run in the box's own security context.

  Defaults to DRY RUN: it only reports what it would do. Pass -Apply to actually create links.

  Safety rules (do not change without deliberately deciding to):
    - Never deletes a real (non-link) directory that has content. If the target link path
      already exists as a normal folder with files in it, the script stops and asks you to
      move it aside by hand (e.g. rename to "output.old") before rerunning with -Apply.
    - Never overwrites an existing junction/symlink that already points somewhere. It will
      only skip and report the existing target; use -Force to replace a wrong link.
    - Requires the OneDrive target folder to already exist before linking to it (it will not
      create input/output/workflows/Models_bare on OneDrive for you).

.PARAMETER ComfyRoot
  Path to the ComfyUI-Easy-Install (or portable) root, the folder containing
  "Start ComfyUI.bat" / "run_nvidia_gpu.bat" and the ComfyUI\ subfolder.
  e.g. C:\ComfyUI_easy\ComfyUI-Easy-Install  or  C:\ComfyUI_windows_portable

.PARAMETER ModelsMode
  How models\ should be remapped:
    Junction  - junction the whole ComfyUI\models\ folder to OneDrive\...\Models_bare
                (this is what travelbeast and chatworkhorse use)
    ExtraYaml - leave ComfyUI\models\ as a real local folder and rely on
                ComfyUI\extra_model_paths.yaml pointing at a base_path elsewhere
                (this is what imagebeast uses; script will only verify + report, not touch it)
  Default: Junction. Pass ExtraYaml on imagebeast (or wherever you deliberately keep models local).

.PARAMETER WorkflowLinkType
  Junction or SymbolicLink for user\default\workflows. Default: Junction (matches
  imagebeast/travelbeast; recommended over SymbolicLink for consistency, junctions
  don't need admin/dev-mode). chatworkhorse currently uses SymbolicLink; pass
  -WorkflowLinkType Junction -Force there to convert it, or leave it if you don't care.

.PARAMETER Apply
  Actually create the links. Without this flag, nothing on disk is changed.

.PARAMETER Force
  Replace an existing junction/symlink even if it already points somewhere (still refuses
  to touch a real non-link directory with content, that always requires manual action).

.EXAMPLE
  # Dry run on travelbeast, see what it would do
  .\relink-comfyui-dirs.ps1 -ComfyRoot 'C:\ComfyUI-Easy-Install'

.EXAMPLE
  # Actually apply on chatworkhorse, models via junction (its current mechanism)
  .\relink-comfyui-dirs.ps1 -ComfyRoot 'C:\ComfyUI_windows_portable' -ModelsMode Junction -Apply

.EXAMPLE
  # imagebeast (old style): models stay local via extra_model_paths.yaml, just fix input/output/workflows
  .\relink-comfyui-dirs.ps1 -ComfyRoot 'C:\ComfyUI_easy\ComfyUI-Easy-Install' -ModelsMode ExtraYaml -Apply

.EXAMPLE
  # imagebeast (junction mechanism, data stays local, not OneDrive):
  .\relink-comfyui-dirs.ps1 -ComfyRoot 'C:\ComfyUI_easy\ComfyUI-Easy-Install' -ModelsMode Junction -ModelsTarget 'C:\ComfyUI_Models' -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComfyRoot,

    [ValidateSet('Junction', 'ExtraYaml')]
    [string]$ModelsMode = 'Junction',

    # Only used when -ModelsMode Junction. Defaults to OneDrive Models_bare (travelbeast/
    # chatworkhorse's setup). Override for a box whose model data lives somewhere else but
    # should still use the junction *mechanism*, e.g. imagebeast's local C:\ComfyUI_Models
    # (data stays local, only the remap mechanism becomes a junction instead of a yaml).
    [string]$ModelsTarget,

    [ValidateSet('Junction', 'SymbolicLink')]
    [string]$WorkflowLinkType = 'Junction',

    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Resolve this machine's OneDrive base path automatically ---
# All three boxes use the same OneDrive subtree shape, just different usernames.
$oneDriveBase = Join-Path $env:USERPROFILE 'OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI'

if (-not (Test-Path $oneDriveBase)) {
    throw "Expected OneDrive folder not found: $oneDriveBase`nThis script assumes the standard 0ComfyUI layout under the current user's OneDrive. Adjust `$oneDriveBase manually if this box differs."
}

$comfyDir = Join-Path $ComfyRoot 'ComfyUI'
if (-not (Test-Path $comfyDir)) {
    throw "No ComfyUI\ subfolder found under $ComfyRoot, is -ComfyRoot correct?"
}

Write-Host "ComfyUI root:    $ComfyRoot"
Write-Host "ComfyUI\ dir:    $comfyDir"
Write-Host "OneDrive base:   $oneDriveBase"
Write-Host "Mode:            $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to actually make changes)' })"
Write-Host ""

function Ensure-Link {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$LinkType   # 'Junction' or 'SymbolicLink'
    )

    Write-Host "--- $LinkPath ---"

    if (-not (Test-Path $TargetPath)) {
        Write-Warning "  Target does not exist, skipping: $TargetPath"
        return
    }

    $existing = Get-Item -Path $LinkPath -Force -ErrorAction SilentlyContinue

    if ($existing) {
        if ($existing.LinkType) {
            $existingTarget = $existing.Target
            if ($existingTarget -eq $TargetPath) {
                Write-Host "  Already correct: $($existing.LinkType) -> $existingTarget"
                return
            }
            Write-Host "  Existing $($existing.LinkType) points elsewhere: $existingTarget"
            if (-not $Force) {
                Write-Warning "  Leaving as-is. Rerun with -Force to repoint it to: $TargetPath"
                return
            }
            if ($Apply) {
                Remove-Item -Path $LinkPath -Force
                Write-Host "  Removed old link."
            } else {
                Write-Host "  [DRY RUN] Would remove old link and relink to $TargetPath"
                return
            }
        } else {
            # Real directory/file, not a link. Never auto-delete.
            $itemCount = (Get-ChildItem -Path $LinkPath -Force -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Warning "  '$LinkPath' is a REAL directory (not a link) with $itemCount item(s)."
            Write-Warning "  Not touching it. Move it aside by hand first, e.g.:"
            Write-Warning "    Rename-Item '$LinkPath' '$LinkPath.local-backup'"
            Write-Warning "  then rerun this script."
            return
        }
    }

    if ($Apply) {
        New-Item -ItemType $LinkType -Path $LinkPath -Target $TargetPath | Out-Null
        Write-Host "  Created $LinkType -> $TargetPath"
    } else {
        Write-Host "  [DRY RUN] Would create $LinkType -> $TargetPath"
    }
}

# --- output / input (always junctions, consistent across all three boxes already) ---
Ensure-Link -LinkPath (Join-Path $comfyDir 'output') -TargetPath (Join-Path $oneDriveBase 'output') -LinkType 'Junction'
Ensure-Link -LinkPath (Join-Path $comfyDir 'input')  -TargetPath (Join-Path $oneDriveBase 'input')  -LinkType 'Junction'

# --- workflows: the real path ComfyUI reads is user\default\workflows ---
$userDefaultDir = Join-Path $comfyDir 'user\default'
if (-not (Test-Path $userDefaultDir)) {
    if ($Apply) {
        New-Item -ItemType Directory -Path $userDefaultDir -Force | Out-Null
    } else {
        Write-Host "[DRY RUN] Would create $userDefaultDir"
    }
}
Ensure-Link -LinkPath (Join-Path $userDefaultDir 'workflows') -TargetPath (Join-Path $oneDriveBase 'workflows') -LinkType $WorkflowLinkType

# --- models ---
if ($ModelsMode -eq 'Junction') {
    $resolvedModelsTarget = if ($ModelsTarget) { $ModelsTarget } else { Join-Path $oneDriveBase 'Models_bare' }
    Ensure-Link -LinkPath (Join-Path $comfyDir 'models') -TargetPath $resolvedModelsTarget -LinkType 'Junction'
} else {
    Write-Host "--- models ---"
    $modelsDir = Join-Path $comfyDir 'models'
    $yamlPath = Join-Path $comfyDir 'extra_model_paths.yaml'

    if (-not (Test-Path $modelsDir)) {
        # A from-scratch copy (e.g. a robocopy backup that excluded models\ entirely) won't
        # have this folder at all. ComfyUI still expects the local models\ tree (with its
        # tracked placeholder stub files) to exist even when extra_model_paths.yaml redirects
        # the actual model data elsewhere -- restore it from git rather than leaving it missing.
        Write-Warning "  models\ does not exist at all under $comfyDir (likely a from-scratch copy that excluded it)."
        if ($Apply) {
            Write-Host "  Restoring tracked models\ placeholder tree via 'git checkout -- models' (no real model data involved)..."
            Push-Location $comfyDir
            git checkout -- models
            Pop-Location
        } else {
            Write-Host "  [DRY RUN] Would run: git checkout -- models  (in $comfyDir)"
        }
    } else {
        Write-Host "  models\ already exists locally, leaving as-is."
    }

    if (Test-Path $yamlPath) {
        Write-Host "  ModelsMode=ExtraYaml: extra_model_paths.yaml present:"
        Get-Content $yamlPath | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Warning "  ModelsMode=ExtraYaml but no extra_model_paths.yaml found at $yamlPath, models are NOT remapped on this box. Create the yaml by hand or rerun with -ModelsMode Junction."
    }
}

Write-Host ""
Write-Host "Done. $(if (-not $Apply) { 'Nothing was changed (dry run). Rerun with -Apply to make these changes.' })"
