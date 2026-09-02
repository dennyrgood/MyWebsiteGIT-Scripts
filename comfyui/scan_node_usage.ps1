# scan_node_usage.ps1
# One-time scan: does ANY workflow (.json template) or output PNG's embedded
# workflow reference these "background" custom nodes/models by node-type
# name or internal path, even when no per-workflow filename widget shows up
# in the normal model-reference scan? Raw substring search on the full
# workflow JSON text -- catches node type names, hardcoded internal model
# paths, custom-node class names, regardless of exact JSON schema.

param(
    [string]$WorkflowDir = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\user\default\workflows",
    [string]$PngDir      = "C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\output"
)

$categories = @{
    "joycaption"  = @("joycaption")
    "RMBG/birefnet" = @("rmbg", "birefnet")
    "insightface" = @("insightface", "buffalo_l", "reactor", "faceanalysis", "pulid")
    "sam (segment anything)" = @("samloader", "sammodelloader", "sam_vit", "groundingdino")
    "facexlib" = @("facexlib", "facerestore", "faceparsing", "detection_resnet50", "parsing_bisenet")
}

function Get-WorkflowTextFromPng {
    param([string]$PngPath)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($PngPath)
        if ($bytes.Length -lt 8) { return $null }
        if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $null }
        $pos = 8
        $fallback = $null
        while ($pos -lt ($bytes.Length - 12)) {
            $chunkLen  = ([int]$bytes[$pos] -shl 24) -bor ([int]$bytes[$pos+1] -shl 16) -bor ([int]$bytes[$pos+2] -shl 8) -bor [int]$bytes[$pos+3]
            $chunkType = [System.Text.Encoding]::ASCII.GetString($bytes, $pos+4, 4)
            $dataStart = $pos + 8
            $dataEnd   = $dataStart + $chunkLen
            if ($chunkType -eq 'tEXt' -and $chunkLen -gt 0) {
                $nullPos = $dataStart
                while ($nullPos -lt $dataEnd -and $bytes[$nullPos] -ne 0x00) { $nullPos++ }
                $kwLen = $nullPos - $dataStart
                $keyword = if ($kwLen -gt 0) { [System.Text.Encoding]::GetEncoding(28591).GetString($bytes, $dataStart, $kwLen) } else { "" }
                $valueStart = $nullPos + 1
                $valueLen   = $dataEnd - $valueStart
                $isWorkflowChunk = ($keyword -eq "") -or ($keyword -eq "workflow") -or ($keyword -eq "prompt")
                if ($isWorkflowChunk -and $valueLen -gt 2) {
                    $jsonStr = [System.Text.Encoding]::UTF8.GetString($bytes, $valueStart, $valueLen).Trim()
                    if ($jsonStr.StartsWith("{")) {
                        if ($keyword -eq "prompt" -or $keyword -eq "") { return $jsonStr }
                        $fallback = $jsonStr
                    }
                }
            }
            $pos += 12 + $chunkLen
            if ($chunkType -eq 'IEND') { break }
        }
    } catch { }
    return $fallback
}

$results = @{}
foreach ($cat in $categories.Keys) { $results[$cat] = New-Object System.Collections.Generic.List[string] }

Write-Host "Scanning JSON workflows in $WorkflowDir ..."
$jsonFiles = Get-ChildItem -Path $WorkflowDir -Filter "*.json" -Recurse -File -ErrorAction SilentlyContinue
$jsonCount = 0
foreach ($f in $jsonFiles) {
    $jsonCount++
    try {
        $text = Get-Content -Path $f.FullName -Raw -Encoding UTF8
    } catch { continue }
    $lower = $text.ToLower()
    foreach ($cat in $categories.Keys) {
        foreach ($kw in $categories[$cat]) {
            if ($lower.Contains($kw)) {
                $results[$cat].Add("[json] " + $f.FullName.Substring($WorkflowDir.Length + 1))
                break
            }
        }
    }
}
Write-Host "  scanned $jsonCount json files"

Write-Host "Scanning output PNGs in $PngDir ..."
$pngFiles = Get-ChildItem -Path $PngDir -Filter "*.png" -Recurse -File -ErrorAction SilentlyContinue
$pngCount = 0
$pngParsed = 0
foreach ($f in $pngFiles) {
    $pngCount++
    $text = Get-WorkflowTextFromPng -PngPath $f.FullName
    if (-not $text) { continue }
    $pngParsed++
    $lower = $text.ToLower()
    foreach ($cat in $categories.Keys) {
        foreach ($kw in $categories[$cat]) {
            if ($lower.Contains($kw)) {
                $results[$cat].Add("[png] " + $f.FullName.Substring($PngDir.Length + 1))
                break
            }
        }
    }
}
Write-Host "  scanned $pngCount pngs, $pngParsed had embedded workflow data"
Write-Host ""
Write-Host "=== RESULTS ==="
foreach ($cat in $categories.Keys) {
    $hits = $results[$cat]
    Write-Host "$cat -- $($hits.Count) hits"
    $hits | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }
    if ($hits.Count -gt 8) { Write-Host "    ... and $($hits.Count - 8) more" }
}
