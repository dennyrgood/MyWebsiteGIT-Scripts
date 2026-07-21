# surface3-gc-snapshot-fleet-configs.ps1
# Created: 2026-07-21
# surface3-gc is a NO-REPO box. It cannot commit to fleet-configs, so it STAGES its
# bespoke fleet files + Task Scheduler exports into OneDrive\ForFleetConfigs\surface3-gc\.
# A repo machine (this Mac) then collects them with collect-fleet-configs-from-onedrive.sh.
#
# Delivery: this script itself lives in the scripts repo (scripts/Surface3GC/) as the
# source of truth; copy it into OneDrive so this box can run it. Run manually.

$ErrorActionPreference = "Stop"
$Box = "surface3-gc"
$src = "C:\Misc"                 # where this box's bespoke writer / vbs / metrics server live

$od = if ($env:OneDrive) { $env:OneDrive } elseif ($env:OneDriveConsumer) { $env:OneDriveConsumer } else { Join-Path $env:USERPROFILE "OneDrive" }
if (-not (Test-Path $od)) { throw "OneDrive path not found: $od" }

$dest   = Join-Path $od "ForFleetConfigs\$Box"
$xmlDir = Join-Path $dest "TaskSched"
New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null

# 1) copy the bespoke script files the fleet actually uses (not in any repo on this box)
Get-ChildItem -Path "$src\*" -Include *.ps1, *.vbs, *.py -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'heartbeat|fleet_metrics_server|run_hidden|Bekah|GC_' } |
    ForEach-Object { Copy-Item $_.FullName $dest -Force; Write-Host "copied: $($_.Name)" }

# 2) export fleet-related Task Scheduler tasks (writer + metrics) as UTF-16 XML.
#    The XML captures the authoritative python/script paths even if they live elsewhere.
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
