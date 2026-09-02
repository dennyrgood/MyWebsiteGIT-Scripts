# =============================================================================
# Get-CustomNodes.ps1
# Lists all installed custom node directories in ComfyUI
# Output: console + optional text file
# =============================================================================

param(
    [string]$ComfyRoot = "C:\ComfyUI_easy\ComfyUI-Easy-Install\comfyui",
    [string]$OutputDir = ".\comfy-reports",
    [switch]$NoFile    # Use this switch to print to console only
)

# --- Setup ---
$timeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$hostName   = $env:COMPUTERNAME
$nodesPath  = Join-Path $ComfyRoot "custom_nodes"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  ComfyUI Custom Nodes Inventory" -ForegroundColor Cyan
Write-Host "  Host : $hostName" -ForegroundColor Cyan
Write-Host "  Root : $ComfyRoot" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

if (!(Test-Path $nodesPath)) {
    Write-Host "ERROR: custom_nodes path not found: $nodesPath" -ForegroundColor Red
    exit 1
}

# Get all directories (each directory = one custom node)
$nodes = Get-ChildItem -Path $nodesPath -Directory | Sort-Object Name

Write-Host "Found $($nodes.Count) custom node(s):" -ForegroundColor Green
Write-Host ""

$lines = @()
$lines += "ComfyUI Custom Nodes - $hostName - $timeStamp"
$lines += "Root: $ComfyRoot"
$lines += "=" * 60
$lines += ""

$i = 1
foreach ($node in $nodes) {
    # Folder LastWriteTime as a cheap recency proxy -- same signal class as
    # workflow file mtimes elsewhere in this pipeline. Not a git-commit date
    # (see comfy_fleet.py's disabled-node comment for why version/commit
    # tracking is deliberately out of scope for now), just "when was this
    # node's own folder last touched" (install, update, or a manual edit).
    $modDate = $node.LastWriteTime.ToString("yyyy-MM-dd")
    $line = "{0,3}. {1} || {2}" -f $i, $node.Name, $modDate
    Write-Host $line
    $lines += $line
    $i++
}

$lines += ""
$lines += "Total: $($nodes.Count) custom nodes"

Write-Host ""
Write-Host "Total: $($nodes.Count) custom nodes" -ForegroundColor Green

# --- Save to file unless -NoFile switch is used ---
if (!$NoFile) {
    if (!(Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }
    $outFile = Join-Path $OutputDir "$hostName-CustomNodes-$timeStamp.txt"
    $lines | Out-File -FilePath $outFile -Encoding utf8
    Write-Host ""
    Write-Host "Saved: $outFile" -ForegroundColor Yellow
}
