# =============================================================================
# Get-WorkflowModelMap.ps1
#
# Scans ComfyUI workflow files (JSON + PNG with embedded workflow metadata)
# and maps every model reference found back to the actual model file on disk.
#
# Outputs:
#   *-full_map.csv        - one row per (workflow, model) pair
#   *-model_usage.csv     - one row per model: how many workflows use it
#   *-unused_models.csv   - models on disk never referenced in any workflow
#   *-missing_models.csv  - models referenced in workflows but not on disk
#   *-summary.txt         - human-readable summary
#
# Requirements: PowerShell 5.1+ (Windows 10/11). No extra modules needed.
# =============================================================================

param(
    [string]$ComfyRoot         = "C:\ComfyUI_easy\ComfyUI-Easy-Install\comfyui",
    [string]$WorkflowDir       = "",       # JSON workflow folder (defaults to ComfyRoot\user\default\workflows)
    [string]$PngDir            = "",       # Separate folder to scan for PNG files with embedded workflows
    [string]$ModelsPath        = "",       # Override default models dir (e.g. -ModelsPath "D:\AI\models")
    [string]$StartingPrimesDir = "",       # 000 Starting Images folder - PNGs tagged as source=starting_images
    [string]$OutputDir         = ".\comfy-reports",
    [switch]$NoFile
)

# ---------------------------------------------------------------------------
# 0. Setup
# ---------------------------------------------------------------------------
$timeStamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$hostName   = $env:COMPUTERNAME
$modelsPath = if ($ModelsPath) { $ModelsPath } else { Join-Path $ComfyRoot "models" }

if (!$WorkflowDir) {
    $WorkflowDir = Join-Path $ComfyRoot "user\default\workflows"
    if (!(Test-Path $WorkflowDir)) {
        $WorkflowDir = Join-Path $ComfyRoot "workflows"
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  ComfyUI Workflow -> Model Map"              -ForegroundColor Cyan
Write-Host "  Host      : $hostName"                      -ForegroundColor Cyan
Write-Host "  Workflows : $WorkflowDir"                   -ForegroundColor Cyan
if ($PngDir) {
Write-Host "  PNG Dir   : $PngDir"                        -ForegroundColor Cyan
}
if ($StartingPrimesDir) {
Write-Host "  Primes Dir: $StartingPrimesDir"             -ForegroundColor Cyan
}
Write-Host "  Models    : $modelsPath"                    -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

foreach ($p in @($modelsPath, $WorkflowDir)) {
    if (!(Test-Path $p)) {
        Write-Host "ERROR: Path not found: $p" -ForegroundColor Red
        exit 1
    }
}
if ($PngDir -and !(Test-Path $PngDir)) {
    Write-Host "ERROR: PngDir not found: $PngDir" -ForegroundColor Red
    exit 1
}
if ($StartingPrimesDir -and !(Test-Path $StartingPrimesDir)) {
    Write-Host "WARNING: StartingPrimesDir not found: $StartingPrimesDir" -ForegroundColor Yellow
    $StartingPrimesDir = ""
}

# ---------------------------------------------------------------------------
# 1. Build model inventory
# ---------------------------------------------------------------------------
Write-Host "Building model inventory..." -ForegroundColor Yellow

$modelExtensions = @('.safetensors', '.ckpt', '.pt', '.pth', '.bin', '.gguf')
$modelInventory  = @{}

Get-ChildItem -Path $modelsPath -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $modelExtensions -contains $_.Extension.ToLower() } |
    ForEach-Object {
        $file     = $_
        $relPath  = $file.FullName.Substring($modelsPath.Length).TrimStart('\','/')
        $parts    = $relPath -split '[/\\]'
        $category = if ($parts.Count -gt 1) { $parts[0] } else { "root" }
        $key      = $file.Name.ToLower()
        if ($modelInventory.ContainsKey($key)) {
            $key = "$key|$($file.FullName.ToLower())"
        }
        $modelInventory[$key] = [PSCustomObject]@{
            filename      = $file.Name
            category      = $category
            full_path     = $file.FullName
            relative_path = $relPath
            size_gb       = [math]::Round($file.Length / 1GB, 3)
        }
    }

Write-Host "  Found $($modelInventory.Count) model file(s) on disk" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Helper: resolve model reference to inventory entry
# ---------------------------------------------------------------------------
function Resolve-ModelRef {
    param([string]$Ref)
    if (!$Ref) { return $null }
    $normalized = $Ref -replace '\\', '/'
    $basename   = ($normalized -split '/')[-1].ToLower()
    if ($modelInventory.ContainsKey($basename)) { return $modelInventory[$basename] }
    $hit = $modelInventory.Keys | Where-Object { $_ -like "$basename|*" } | Select-Object -First 1
    if ($hit) { return $modelInventory[$hit] }
    foreach ($entry in $modelInventory.Values) {
        if ($entry.relative_path.ToLower().EndsWith($normalized.ToLower())) { return $entry }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 2. Model input keys used by ComfyUI nodes
# ---------------------------------------------------------------------------
$modelKeys = @(
    'ckpt_name', 'lora_name', 'model_name', 'vae_name',
    'control_net_name', 'unet_name', 'clip_name', 'clip_name1',
    'clip_name2', 'ipadapter_file', 'weight_name', 'file'
)

# "Background" node types -- nodes that load a model internally (often
# hardcoded to a fixed folder, e.g. JoyCaption/RMBG/insightface-style nodes
# resolve their own model path in Python rather than exposing a filename
# widget) rather than through one of the $modelKeys widgets above. A
# workflow using only these would previously be silently skipped entirely
# (zero resolvable model refs), so background-model usage never showed up
# in any report -- confirmed missing multiple real JoyCaption/RMBG/
# insightface workflows on 2026-09-01. Matched by node type/class_type
# substring, case-insensitive. Not meant to resolve to a specific on-disk
# file (these often aren't in $modelKeys at all) -- just to record "this
# workflow uses this feature" so it's visible in full_map instead of
# invisible.
$backgroundNodeKeywords = @(
    'rmbg', 'birefnet', 'insightface', 'reactor',
    'faceanalysis', 'pulid', 'samloader', 'sammodelloader', 'facexlib',
    'facerestore', 'faceparsing'
)

# Exact-match node type names -- for cases where the real class_type is a
# short code that doesn't contain a recognizable keyword as a substring
# (ComfyUI-JoyCaption registers "JC"/"JC_adv"/"JC_GGUF"/etc, not anything
# containing "joycaption" -- confirmed by reading the actual workflow JSON
# node types directly on 2026-09-02, since the substring approach above
# missed it entirely). "JC" alone is too short/generic to safely
# substring-match (would hit unrelated class names), so these need an
# exact (case-insensitive) match instead.
$backgroundNodeExactTypes = @(
    'jc', 'jc_adv', 'jc_gguf', 'jc_gguf_adv', 'jc_extraoptions'
)

# ---------------------------------------------------------------------------
# Helper: extract model refs from parsed workflow JSON
# ---------------------------------------------------------------------------
function Get-RefsFromWorkflow {
    param($workflow)
    $refs = [System.Collections.Generic.List[PSObject]]::new()
    if ($null -eq $workflow) { return $refs }

    $nodesList = $null
    if ($workflow.PSObject.Properties['nodes']) {
        $nodesList = $workflow.nodes
    } else {
        $nodesList = $workflow.PSObject.Properties.Value |
            Where-Object { $_ -is [PSCustomObject] -and $_.PSObject.Properties['class_type'] }
    }
    if ($null -eq $nodesList) { return $refs }

    foreach ($node in $nodesList) {
        if ($null -eq $node) { continue }
        $classType = ""
        $nodeTitle = ""
        if ($node.PSObject.Properties['class_type']) { $classType = $node.class_type }
        if ($node.PSObject.Properties['type'])        { $classType = $node.type }
        if ($node.PSObject.Properties['_meta'])       { $nodeTitle = $node._meta.title }
        if (!$nodeTitle -and $node.PSObject.Properties['title']) { $nodeTitle = $node.title }
        if (!$nodeTitle) { $nodeTitle = $classType }
        $label = if ($nodeTitle -and $nodeTitle -ne $classType) { "$nodeTitle ($classType)" } else { $classType }

        $foundFileRef = $false

        if ($node.PSObject.Properties['widgets_values']) {
            $wv = $node.widgets_values
            if ($wv -is [System.Collections.IEnumerable]) {
                foreach ($v in $wv) {
                    if ($v -is [string] -and $v -match '\.(safetensors|ckpt|pt|pth|bin|gguf)$') {
                        $refs.Add([PSCustomObject]@{ node_label = $label; model_ref = $v; is_background = $false })
                        $foundFileRef = $true
                    }
                }
            }
        }

        if ($node.PSObject.Properties['inputs']) {
            $inputs = $node.inputs
            foreach ($key in $modelKeys) {
                if ($inputs.PSObject.Properties[$key]) {
                    $v = $inputs.$key
                    if ($v -is [string] -and $v -match '\.(safetensors|ckpt|pt|pth|bin|gguf)$') {
                        $refs.Add([PSCustomObject]@{ node_label = $label; model_ref = $v; is_background = $false })
                        $foundFileRef = $true
                    }
                }
            }
        }

        # Background-model node: no resolvable filename widget was found on
        # this node, but its type matches a known "loads a model internally"
        # node (JoyCaption/RMBG/insightface-style). Record it as a distinct
        # "feature used" reference rather than skipping the node silently --
        # model_ref is a synthetic marker, not a real filename to resolve.
        if (!$foundFileRef -and $classType) {
            $ctLower = $classType.ToLower()
            $isBgNode = $backgroundNodeExactTypes -contains $ctLower
            if (!$isBgNode) {
                foreach ($kw in $backgroundNodeKeywords) {
                    if ($ctLower.Contains($kw)) { $isBgNode = $true; break }
                }
            }
            if ($isBgNode) {
                $refs.Add([PSCustomObject]@{ node_label = $label; model_ref = "[background-model:$classType]"; is_background = $true })
            }
        }
    }
    return $refs
}

# ---------------------------------------------------------------------------
# Helper: parse PNG tEXt chunks to extract ComfyUI workflow JSON
#
# Your ComfyUI output PNGs store JSON directly in tEXt chunks with NO keyword
# (null byte at position 0, raw JSON immediately after). We try:
#   1. No keyword - raw JSON starting at byte 0 of chunk data
#   2. Known keywords: "workflow", "prompt"
# ---------------------------------------------------------------------------
function Get-WorkflowFromPng {
    param([string]$PngPath)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($PngPath)

        # Verify PNG signature
        if ($bytes.Length -lt 8) { return $null }
        if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or
            $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $null }

        $pos = 8

        while ($pos -lt ($bytes.Length - 12)) {
            $chunkLen  = ([int]$bytes[$pos]   -shl 24) -bor `
                         ([int]$bytes[$pos+1] -shl 16) -bor `
                         ([int]$bytes[$pos+2] -shl 8)  -bor `
                          [int]$bytes[$pos+3]
            $chunkType = [System.Text.Encoding]::ASCII.GetString($bytes, $pos+4, 4)
            $dataStart = $pos + 8
            $dataEnd   = $dataStart + $chunkLen

            if ($chunkType -eq 'tEXt' -and $chunkLen -gt 0) {

                # Find the null separator between keyword and value
                $nullPos = $dataStart
                while ($nullPos -lt $dataEnd -and $bytes[$nullPos] -ne 0x00) { $nullPos++ }

                $kwLen = $nullPos - $dataStart
                $keyword = if ($kwLen -gt 0) {
                                [System.Text.Encoding]::GetEncoding(28591).GetString($bytes, $dataStart, $kwLen)
                           } else { "" }
                $valueStart = $nullPos + 1
                $valueLen   = $dataEnd - $valueStart

                # Accept: no keyword, or keyword is "workflow" or "prompt"
                $isWorkflowChunk = ($keyword -eq "") -or ($keyword -eq "workflow") -or ($keyword -eq "prompt")

                # Also accept: chunk starts directly with { (no keyword at all, null is first byte)
                if (!$isWorkflowChunk -and $bytes[$dataStart] -eq 0x7B) {
                    $isWorkflowChunk = $true
                    $valueStart = $dataStart
                    $valueLen   = $chunkLen
                }

                if ($isWorkflowChunk -and $valueLen -gt 2) {
                    $jsonStr = [System.Text.Encoding]::UTF8.GetString($bytes, $valueStart, $valueLen).Trim()
                    if ($jsonStr.StartsWith("{")) {
                        try {
                            $parsed = $jsonStr | ConvertFrom-Json -ErrorAction Stop
                            if ($parsed) {
                                # Stash all valid chunks, prefer prompt (API format has model refs in inputs)
                                # then workflow (graph format has model refs in widgets_values)
                                if ($keyword -eq "prompt" -or $keyword -eq "") {
                                    return $parsed   # API format - has model refs directly, return immediately
                                }
                                $script:_wfFallback = $parsed   # workflow format - keep as fallback
                            }
                        } catch { }
                    }
                }
            }

            $pos += 12 + $chunkLen
            if ($chunkType -eq 'IEND') { break }
        }
    } catch { }
    # Return workflow-format chunk if we found one but no prompt chunk
    if ($script:_wfFallback) {
        $result = $script:_wfFallback
        $script:_wfFallback = $null
        return $result
    }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: process a single file (json or png) and add rows to $mapRows
#
# $rootDir is the scan root this file came from (WorkflowDir/PngDir/
# StartingPrimesDir) -- used to compute workflow_file as the FULL relative
# path from that root, not just "sourceLabel\bare filename". The old
# bare-filename form silently dropped any subfolder (e.g. an output PNG in
# output\one-node-flux-2-klein\FK_00011_.png showed up as just
# "png-outputs\FK_00011_.png", losing the real subfolder -- confirmed wrong
# 2026-09-02 when hand-verifying a test file against this exact bug).
# ---------------------------------------------------------------------------
function Process-WorkflowFile {
    param($wf, [string]$sourceLabel, [string]$rootDir)

    $workflow = $null

    if ($wf.Extension -eq '.json') {
        try {
            $content  = Get-Content -Path $wf.FullName -Raw -Encoding UTF8
            $workflow = $content | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Host "  SKIP (bad JSON): $($wf.Name)" -ForegroundColor DarkGray
            return $false
        }
    } elseif ($wf.Extension -eq '.png') {
        $workflow = Get-WorkflowFromPng -PngPath $wf.FullName
        if (!$workflow) { return $false }
    }

    $refs = Get-RefsFromWorkflow -workflow $workflow
    if ($refs.Count -eq 0) { return $false }

    $relFromRoot = if ($rootDir -and $wf.FullName.StartsWith($rootDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        $wf.FullName.Substring($rootDir.Length).TrimStart('\','/')
    } else {
        $wf.Name
    }
    $wfRel = "$sourceLabel\$relFromRoot"

    foreach ($r in $refs) {
        if ($r.is_background) {
            # Not a real filename -- don't resolve it and don't feed it into
            # allModelRefs (that set drives unused-model detection by
            # filename match, which this synthetic marker would corrupt).
            $script:mapRows.Add([PSCustomObject]@{
                source            = $sourceLabel
                workflow_file     = $wfRel
                workflow_dir      = $wf.DirectoryName
                workflow_modified = $wf.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                node_label        = $r.node_label
                model_ref         = $r.model_ref
                model_filename    = "(background model -- see node_label, not a resolvable file)"
                model_category    = "background-model"
                model_path        = ""
                model_size_gb     = ""
                on_disk           = "N/A"
            })
            continue
        }

        $resolved      = Resolve-ModelRef -Ref $r.model_ref
        $normalizedRef = $r.model_ref.ToLower() -replace '\\','/'
        [void]$script:allModelRefs.Add($normalizedRef)

        $script:mapRows.Add([PSCustomObject]@{
            source            = $sourceLabel
            workflow_file     = $wfRel
            workflow_dir      = $wf.DirectoryName
            workflow_modified = $wf.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            node_label        = $r.node_label
            model_ref         = $r.model_ref
            model_filename    = if ($resolved) { $resolved.filename }  else { "(not found on disk)" }
            model_category    = if ($resolved) { $resolved.category }  else { "" }
            model_path        = if ($resolved) { $resolved.full_path } else { "" }
            model_size_gb     = if ($resolved) { $resolved.size_gb }   else { "" }
            on_disk           = if ($resolved) { "YES" } else { "NO" }
        })
    }
    return $true
}

# ---------------------------------------------------------------------------
# 3. Scan workflow JSON files
# ---------------------------------------------------------------------------
Write-Host "Scanning JSON workflows in: $WorkflowDir" -ForegroundColor Yellow

$jsonFiles = @(Get-ChildItem -Path $WorkflowDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.json' })

Write-Host "  Found $($jsonFiles.Count) JSON file(s)" -ForegroundColor Green

$mapRows      = [System.Collections.Generic.List[PSObject]]::new()
$allModelRefs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$processed    = 0
$skipped      = 0

foreach ($wf in $jsonFiles) {
    $ok = Process-WorkflowFile -wf $wf -sourceLabel "workflows" -rootDir $WorkflowDir
    if ($ok) { $processed++ } else { $skipped++ }
}

Write-Host "  Processed : $processed  |  Skipped: $skipped" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Scan PNG files (workflow dir first, then PngDir if specified)
# ---------------------------------------------------------------------------
$pngDirsToScan = @()

# PNGs inside the workflow folder
$wfPngs = @(Get-ChildItem -Path $WorkflowDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.png' })
if ($wfPngs.Count -gt 0) { $pngDirsToScan += [PSCustomObject]@{ files = $wfPngs; label = "workflows-png"; root = $WorkflowDir } }

# Dedicated output/PNG folder
if ($PngDir) {
    Write-Host ""
    Write-Host "Scanning PNG outputs in: $PngDir" -ForegroundColor Yellow
    $outputPngs = @(Get-ChildItem -Path $PngDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.png' })
    Write-Host "  Found $($outputPngs.Count) PNG file(s)" -ForegroundColor Green
    if ($outputPngs.Count -gt 0) { $pngDirsToScan += [PSCustomObject]@{ files = $outputPngs; label = "png-outputs"; root = $PngDir } }
}

$pngProcessed = 0
$pngSkipped   = 0

foreach ($batch in $pngDirsToScan) {
    foreach ($wf in $batch.files) {
        $ok = Process-WorkflowFile -wf $wf -sourceLabel $batch.label -rootDir $batch.root
        if ($ok) { $pngProcessed++ } else { $pngSkipped++ }
    }
}

if ($pngDirsToScan.Count -gt 0) {
    Write-Host "  PNG processed : $pngProcessed  |  Skipped (no workflow data): $pngSkipped" -ForegroundColor Green
}

# Dedicated Starting Primes folder (tagged as source=starting_images)
if ($StartingPrimesDir) {
    Write-Host ""
    Write-Host "Scanning Starting Images (prime set) in: $StartingPrimesDir" -ForegroundColor Yellow
    $primePngs = @(Get-ChildItem -Path $StartingPrimesDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.png' })
    Write-Host "  Found $($primePngs.Count) PNG file(s)" -ForegroundColor Green
    $primeProcessed = 0
    $primeSkipped   = 0
    foreach ($wf in $primePngs) {
        $ok = Process-WorkflowFile -wf $wf -sourceLabel "starting_images" -rootDir $StartingPrimesDir
        if ($ok) { $primeProcessed++ } else {
            $primeSkipped++
            Write-Host "  SKIPPED (no workflow data): $($wf.Name)" -ForegroundColor Yellow
        }
    }
    Write-Host "  Prime processed : $primeProcessed  |  Skipped (no workflow data): $primeSkipped" -ForegroundColor Green
}

Write-Host ""
$totalProcessed = $processed + $pngProcessed

# ---------------------------------------------------------------------------
# 5. Usage summary per model
# ---------------------------------------------------------------------------
$usageSummary = @($mapRows |
    Where-Object { $_.on_disk -eq "YES" } |
    Group-Object model_filename |
    ForEach-Object {
        $grp    = $_
        $first  = $grp.Group[0]
        $wfList = @($grp.Group | Select-Object -ExpandProperty workflow_file -Unique | Sort-Object)
        [PSCustomObject]@{
            model_filename = $grp.Name
            model_category = $first.model_category
            model_size_gb  = $first.model_size_gb
            workflow_count = $wfList.Count
            workflows      = $wfList -join " | "
        }
    } | Sort-Object -Property workflow_count -Descending)

# ---------------------------------------------------------------------------
# 6. Unused models
# ---------------------------------------------------------------------------
$unusedModels = @($modelInventory.Values | Where-Object {
    $fn = $_.filename.ToLower()
    -not ($allModelRefs | Where-Object { $_ -like "*$fn" })
} | Sort-Object category, filename)

# ---------------------------------------------------------------------------
# 7. Missing models
# ---------------------------------------------------------------------------
$missingModels = @($mapRows |
    Where-Object { $_.on_disk -eq "NO" } |
    Select-Object model_ref, workflow_file, node_label -Unique |
    Sort-Object model_ref)

# ---------------------------------------------------------------------------
# 8. Console output
# ---------------------------------------------------------------------------
Write-Host "--- Model Usage Summary (top 20) ---" -ForegroundColor Cyan
$usageSummary | Select-Object -First 20 |
    Format-Table model_filename, model_category, model_size_gb, workflow_count -AutoSize

if ($missingModels.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Missing Models (referenced but NOT on disk): $($missingModels.Count) ---" -ForegroundColor Red
    $missingModels | Select-Object -First 10 | Format-Table model_ref, workflow_file -AutoSize
}

Write-Host ""
Write-Host "--- Unused Models (on disk but NEVER referenced): $($unusedModels.Count) ---" -ForegroundColor Yellow
$unusedModels | Select-Object -First 10 | Format-Table filename, category, size_gb -AutoSize

# ---------------------------------------------------------------------------
# 9. Save output files
# ---------------------------------------------------------------------------
if (!$NoFile) {
    if (!(Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    $prefix = Join-Path $OutputDir "$hostName-WorkflowMap-$timeStamp"

    $mapRows       | Export-Csv "$prefix-full_map.csv"       -NoTypeInformation -Encoding UTF8
    $usageSummary  | Export-Csv "$prefix-model_usage.csv"    -NoTypeInformation -Encoding UTF8
    $unusedModels  | Export-Csv "$prefix-unused_models.csv"  -NoTypeInformation -Encoding UTF8
    $missingModels | Export-Csv "$prefix-missing_models.csv" -NoTypeInformation -Encoding UTF8

    $div1 = "============================================================"
    $div2 = "------------------------------------------------------------"

    $invCount     = $modelInventory.Count
    $refsCount    = $allModelRefs.Count
    $usedCount    = $usageSummary.Count
    $unusedCount  = $unusedModels.Count
    $missingCount = $missingModels.Count

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("ComfyUI Workflow -> Model Map Summary")
    $out.Add("Host    : $hostName")
    $out.Add("Date    : $timeStamp")
    $out.Add($div1)
    $out.Add("")
    $out.Add("MODELS ON DISK       : $invCount")
    $out.Add("JSON WORKFLOWS       : $processed processed  |  $skipped skipped")
    $out.Add("PNG FILES            : $pngProcessed processed  |  $pngSkipped skipped (no embedded workflow)")
    $out.Add("TOTAL PROCESSED      : $totalProcessed")
    $out.Add("UNIQUE MODEL REFS    : $refsCount")
    $out.Add("MODELS USED          : $usedCount")
    $out.Add("MODELS UNUSED        : $unusedCount")
    $out.Add("MISSING (not on disk): $missingCount")
    $out.Add("")
    $out.Add($div1)
    $out.Add("TOP MODELS BY WORKFLOW COUNT")
    $out.Add($div2)

    foreach ($row in ($usageSummary | Select-Object -First 30)) {
        $line = "  [{0,2} workflows]  {1}  ({2})  {3} GB" -f `
            $row.workflow_count, $row.model_filename, $row.model_category, $row.model_size_gb
        $out.Add($line)
    }

    if ($unusedCount -gt 0) {
        $unusedGB = [math]::Round(($unusedModels | Measure-Object size_gb -Sum).Sum, 2)
        $out.Add("")
        $out.Add($div1)
        $out.Add("UNUSED MODELS  ($unusedCount files  |  $unusedGB GB wasted)")
        $out.Add($div2)
        foreach ($m in $unusedModels) {
            $line = "  {0,-55} {1} GB  [{2}]" -f $m.filename, $m.size_gb, $m.category
            $out.Add($line)
        }
    }

    if ($missingCount -gt 0) {
        $out.Add("")
        $out.Add($div1)
        $out.Add("MISSING MODELS (referenced in workflows but not on disk)")
        $out.Add($div2)
        foreach ($m in ($missingModels | Select-Object model_ref -Unique)) {
            $out.Add("  $($m.model_ref)")
        }
    }

    $out | Out-File "$prefix-summary.txt" -Encoding UTF8

    Write-Host ""
    Write-Host "Output files:" -ForegroundColor Yellow
    Write-Host "  $prefix-full_map.csv"
    Write-Host "  $prefix-model_usage.csv"
    Write-Host "  $prefix-unused_models.csv"
    Write-Host "  $prefix-missing_models.csv"
    Write-Host "  $prefix-summary.txt"
    Write-Host ""
    Write-Host "Done!" -ForegroundColor Green
}
