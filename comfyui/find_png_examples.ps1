$PngDir = "C:\Users\Pc\OneDrive\DropBoxReplacement\MathesDropBox\0ComfyUI\output"
$categories = @{
    "RMBG/birefnet" = @("rmbg", "birefnet")
    "insightface" = @("insightface", "buffalo_l")
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
$pngFiles = Get-ChildItem -Path $PngDir -Filter "*.png" -Recurse -File -ErrorAction SilentlyContinue
foreach ($f in $pngFiles) {
    $text = Get-WorkflowTextFromPng -PngPath $f.FullName
    if (-not $text) { continue }
    $lower = $text.ToLower()
    foreach ($cat in $categories.Keys) {
        foreach ($kw in $categories[$cat]) {
            if ($lower.Contains($kw)) {
                $results[$cat].Add($f.FullName)
                break
            }
        }
    }
}
foreach ($cat in $categories.Keys) {
    Write-Host "=== $cat -- $($results[$cat].Count) hits ==="
    $results[$cat] | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
}
