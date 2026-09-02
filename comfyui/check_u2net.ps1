$root = "C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\custom_nodes"
$pyFiles = Get-ChildItem -Path $root -Filter "*.py" -Recurse -File -ErrorAction SilentlyContinue
foreach ($f in $pyFiles) {
    $matches = Select-String -Path $f.FullName -Pattern 'u2net|rembg' -ErrorAction SilentlyContinue
    if ($matches) {
        Write-Host "--- $($f.FullName) ---"
        $matches | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
    }
}
