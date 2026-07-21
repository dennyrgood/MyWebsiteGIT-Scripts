# remotews-snapshot-fleet-configs.ps1
# Created: 2026-07-21
# remotews (Plex Server Bekah) is a NO-REPO box. It STAGES its bespoke fleet files +
# Task Scheduler exports into OneDrive\ForFleetConfigs\remotews\, for a repo machine
# (this Mac) to collect with collect-fleet-configs-from-onedrive.sh.
#
# Everything fleet-related lives in C:\Misc on this box: Bekah_onedrive_heartbeat_writer_server.ps1,
# Bekah_run_hidden.vbs, fleet_metrics_server.py, and the Python313 install.
#
# Delivery: this script lives in the scripts repo (scripts/RemoteWS/) as source of truth;
# copy it into OneDrive so this box can run it. Run manually.

$ErrorActionPreference = "Stop"
$Box = "remotews"
$src = "C:\Misc"

$od = if ($env:OneDrive) { $env:OneDrive } elseif ($env:OneDriveConsumer) { $env:OneDriveConsumer } else { Join-Path $env:USERPROFILE "OneDrive" }
if (-not (Test-Path $od)) { throw "OneDrive path not found: $od" }

$dest   = Join-Path $od "ForFleetConfigs\$Box"
$xmlDir = Join-Path $dest "TaskSched"
New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null

# 1) bespoke fleet scripts (writer .ps1, launcher .vbs, metrics server .py)
Get-ChildItem -Path "$src\*" -Include *.ps1, *.vbs, *.py -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'heartbeat|fleet_metrics_server|run_hidden|Bekah|GC_' } |
    ForEach-Object { Copy-Item $_.FullName $dest -Force; Write-Host "copied: $($_.Name)" }

# 2) fleet Task Scheduler tasks -> UTF-16 XML
$tasks = Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet_metrics_server|fleet_monitor|run_hidden|heartbeat|Bekah|GC_'
} | ForEach-Object { $_.TaskName }
$tasks = @($tasks) + @("FleetMetricsServer") | Select-Object -Unique
foreach ($t in $tasks) {
    $xml = schtasks /Query /TN "\$t" /XML 2>$null
    if ($LASTEXITCODE -eq 0 -and $xml) {
        $xml | Out-File -FilePath (Join-Path $xmlDir "$t.xml") -Encoding Unicode
        Write-Host "exported: $t"
    }
}

Write-Host "`nStaged to $dest"
Write-Host "Collect it from your Mac: scripts/collect-fleet-configs-from-onedrive.sh"
