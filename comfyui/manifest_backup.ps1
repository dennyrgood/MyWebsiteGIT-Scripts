$base = 'C:\ComfyUI_easy\ComfyUI-Easy-Install - BACKUP - 2026-09-01\ComfyUI\models\'
Get-ChildItem -Recurse -File $base -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length)
    "$rel|$($_.Length)"
}
