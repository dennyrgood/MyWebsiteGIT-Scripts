$base = 'C:\ComfyUI_easy\ComfyUI-Easy-Install\ComfyUI\models\'
Get-ChildItem -Recurse -File $base | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length)
    "$rel|$($_.Length)"
}
