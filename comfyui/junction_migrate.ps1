$comfyRoot = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI"
$embedded  = "$comfyRoot\models"
$external  = "C:\ComfyUI_Models\models"
$yaml      = "$comfyRoot\extra_model_paths.yaml"

Write-Host "=== Removing embedded models directory ==="
Remove-Item -Path $embedded -Recurse -Force
Write-Host "Removed: $embedded"

Write-Host ""
Write-Host "=== Creating junction ==="
New-Item -ItemType Junction -Path $embedded -Target $external | Out-Null
Write-Host "Junction created: $embedded -> $external"

Write-Host ""
Write-Host "=== Renaming extra_model_paths.yaml (disabled, not deleted) ==="
if (Test-Path $yaml) {
    Rename-Item -Path $yaml -NewName "extra_model_paths.yaml.disabled"
    Write-Host "Renamed to: extra_model_paths.yaml.disabled"
} else {
    Write-Host "yaml not found at expected path (already handled?): $yaml"
}

Write-Host ""
Write-Host "=== Verification ==="
$item = Get-Item $embedded
Write-Host "models dir LinkType: $($item.LinkType)"
Write-Host "models dir Target:   $($item.Target)"
$count = (Get-ChildItem -Recurse -File $embedded -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "Files visible through junction: $count"
