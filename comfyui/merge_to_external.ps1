$embedded = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\models"
$external = "C:\ComfyUI_Models\models"

$items = @(
    "SEEDVR2\seedvr2_ema_7b_sharp-Q4_K_M.gguf",
    "loras\bfs_head_v1_flux-klein_9b_step3500_rank128.safetensors",
    "SEEDVR2\ema_vae_fp16.safetensors",
    "background_removal\birefnet.safetensors",
    "loras\bfs_head_v1_flux-klein_4b.safetensors",
    "rembg\u2net.onnx",
    "loras\refcontrol_v2_poses.safetensors",
    "SEEDVR2\.validation_cache.json"
)

foreach ($rel in $items) {
    $src = Join-Path $embedded $rel
    $dst = Join-Path $external $rel
    if (-not (Test-Path $src)) {
        Write-Host "SOURCE MISSING: $src"
        continue
    }
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "COPIED  $rel"
}
