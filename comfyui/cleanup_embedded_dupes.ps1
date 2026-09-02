# cleanup_embedded_dupes.ps1
# Dedup: delete embedded copies confirmed byte-identical to C:\ComfyUI_Models
# (which stays canonical). facexlib deleted from BOTH locations -- confirmed
# zero usage anywhere (raw JSON + PNG content scan, 2026-09-01).

$embedded = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\models"
$external = "C:\ComfyUI_Models\models"

$dedupTargets = @(
    "$embedded\LLM\llama-joycaption-beta-one",
    "$embedded\LLM\llama-joycaption-alpha-two",
    "$embedded\LLM\GGUF",
    "$embedded\RMBG\RMBG-2.0",
    "$embedded\sams\sam_vit_b_01ec64.pth",
    "$embedded\insightface\models\buffalo_l",
    "$embedded\insightface\models\buffalo_l.zip"
)

$facexlibTargets = @(
    "$embedded\facexlib",
    "$external\facexlib"
)

function Remove-Target($path) {
    if (Test-Path $path) {
        $item = Get-Item $path
        if ($item.PSIsContainer) {
            $size = (Get-ChildItem $path -Recurse -File | Measure-Object -Property Length -Sum).Sum
        } else {
            $size = $item.Length
        }
        Remove-Item -Path $path -Recurse -Force
        Write-Host ("DELETED  {0,10:N1} MB  {1}" -f ($size/1MB), $path)
    } else {
        Write-Host "NOT FOUND (already gone): $path"
    }
}

Write-Host "=== Dedup deletes (embedded side; external C:\ComfyUI_Models copy stays) ==="
foreach ($t in $dedupTargets) { Remove-Target $t }

Write-Host ""
Write-Host "=== facexlib -- deleting BOTH copies (confirmed unused) ==="
foreach ($t in $facexlibTargets) { Remove-Target $t }
