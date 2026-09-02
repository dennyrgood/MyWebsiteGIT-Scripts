$base = 'C:\ComfyUI_Models\models\'
Get-ChildItem -Recurse -File $base | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length)
    "$rel|$($_.Length)"
}
