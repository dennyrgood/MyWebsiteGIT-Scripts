$targets = @(
    "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\custom_nodes\ComfyUI-JoyCaption",
    "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\custom_nodes\comfyui-rmbg",
    "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\custom_nodes\comfyui_ipadapter_plus"
)
foreach ($dir in $targets) {
    Write-Host "=========================================="
    Write-Host $dir
    Write-Host "=========================================="
    $pyFiles = Get-ChildItem -Path $dir -Filter "*.py" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $pyFiles) {
        $matches = Select-String -Path $f.FullName -Pattern "folder_paths\.|models_dir|LLM|RMBG|insightface" -SimpleMatch:$false -ErrorAction SilentlyContinue
        if ($matches) {
            Write-Host "--- $($f.Name) ---"
            $matches | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
        }
    }
}
