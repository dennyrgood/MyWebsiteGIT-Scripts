# remotews-snapshot-fleet-configs.ps1
# Created 2026-07-21; hardened 2026-07-21.
# remotews (Plex Server Bekah) is a NO-REPO box. It STAGES its bespoke fleet files +
# Task Scheduler exports into OneDrive\ForFleetConfigs\remotews\, for a repo machine
# (this Mac) to collect with collect-fleet-configs-from-onedrive.sh.
#
# Everything fleet-related lives in C:\Misc: Bekah_onedrive_heartbeat_writer_server.ps1,
# Bekah_run_hidden.vbs, fleet_metrics_server.py, and the Python313 install.
#
# Hardened like the repo-Windows scripts: tasks found by ACTION (display name doesn't
# matter), and a stale/protected task is skipped with a warning, not fatal. Do NOT set
# $ErrorActionPreference='Stop'.
#
# Delivery: lives in the scripts repo (scripts/RemoteWS/); pushed to OneDrive by
# push-snapshots-to-onedrive.sh. Run manually.

$Box = "remotews"
$src = "C:\Misc"

$od = if ($env:OneDrive) { $env:OneDrive } elseif ($env:OneDriveConsumer) { $env:OneDriveConsumer } else { Join-Path $env:USERPROFILE "OneDrive" }
if (-not (Test-Path $od)) { Write-Error "OneDrive path not found: $od"; return }

$dest   = Join-Path $od "ForFleetConfigs\$Box"
$xmlDir = Join-Path $dest "TaskSched"
New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null

# 1) bespoke fleet scripts (writer .ps1, launcher .vbs, metrics server .py)
Get-ChildItem -Path "$src\*" -Include *.ps1, *.vbs, *.py -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'heartbeat|fleet_metrics_server|run_hidden|Bekah|GC_' } |
    ForEach-Object { Copy-Item $_.FullName $dest -Force; Write-Host "copied: $($_.Name)" }

# 2) fleet Task Scheduler tasks (found by action) -> UTF-16 XML
$wanted = @(Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet[-_ ]?metrics[-_ ]?server|fleet[-_ ]?monitor|heartbeat|run[-_ ]?hidden|bekah|gc_'
} | ForEach-Object { $_.TaskName } | Select-Object -Unique)

Write-Host "Tasks to export:"; $wanted | ForEach-Object { Write-Host "  [$_]" }; Write-Host ""

foreach ($t in $wanted) {
    $out = Join-Path $xmlDir "$t.xml"
    try {
        $xml = & schtasks /Query /TN "\$t" /XML 2>$null
        if ($LASTEXITCODE -eq 0 -and $xml) { $xml | Out-File -FilePath $out -Encoding Unicode; Write-Host "exported: $t" }
        else { Write-Warning "skipped '$t' (protected or inaccessible — exit $LASTEXITCODE)" }
    } catch { Write-Warning "skipped '$t' ($($_.Exception.Message))" }
}

Write-Host "`nStaged to $dest"
Write-Host "Collect it from your Mac: scripts/collect-fleet-configs-from-onedrive.sh"
