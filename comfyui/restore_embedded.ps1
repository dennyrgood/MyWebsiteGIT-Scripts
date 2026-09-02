$external = "C:\ComfyUI_Models\models"
$embedded = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\models"

$restores = @(
    @{ src = "$external\LLM\llama-joycaption-beta-one"; dst = "$embedded\LLM\llama-joycaption-beta-one" },
    @{ src = "$external\LLM\llama-joycaption-alpha-two"; dst = "$embedded\LLM\llama-joycaption-alpha-two" },
    @{ src = "$external\LLM\GGUF"; dst = "$embedded\LLM\GGUF" },
    @{ src = "$external\RMBG\RMBG-2.0"; dst = "$embedded\RMBG\RMBG-2.0" },
    @{ src = "$external\insightface\models\buffalo_l"; dst = "$embedded\insightface\models\buffalo_l" },
    @{ src = "$external\insightface\models\buffalo_l.zip"; dst = "$embedded\insightface\models\buffalo_l.zip" }
)

foreach ($r in $restores) {
    if (-not (Test-Path $r.src)) {
        Write-Host "SOURCE MISSING (cannot restore): $($r.src)"
        continue
    }
    $parent = Split-Path $r.dst -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if ((Get-Item $r.src).PSIsContainer) {
        Copy-Item -Path $r.src -Destination $r.dst -Recurse -Force
    } else {
        Copy-Item -Path $r.src -Destination $r.dst -Force
    }
    Write-Host "RESTORED  $($r.dst)"
}
