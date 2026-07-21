# travelbeast-snapshot-fleet-configs.ps1
# Created: 2026-07-21 — Re-exports this box's curated fleet Task Scheduler tasks
# into the fleet-configs repo snapshot. Manual-run; review `git diff` and commit.
#
# Task set = existing TaskSched/ XMLs + FleetMetricsServer + any task whose action
# references the fleet writer/metrics paths. TravelBeast also runs wifi_watchdog.ps1,
# which already lives in the scripts repo (scripts/TravelBeast/), so it is not copied.

$ErrorActionPreference = "Stop"
$Machine = "TravelBeast"        # fleet-configs folder name for this box

$repoRoot = @("D:\repos", "C:\repos", "$env:USERPROFILE\repos") |
            Where-Object { Test-Path "$_\fleet-configs" } | Select-Object -First 1
if (-not $repoRoot) { throw "fleet-configs repo not found under D:\repos, C:\repos, or ~\repos" }

$dest = Join-Path $repoRoot "fleet-configs\$Machine\TaskSched"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$tasks = @()
$tasks += Get-ChildItem $dest -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
$tasks += "FleetMetricsServer"
$tasks += Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet_metrics_server|fleet_monitor|run_hidden|heartbeat_writer'
} | ForEach-Object { $_.TaskName }
$tasks = $tasks | Select-Object -Unique

foreach ($t in $tasks) {
    $out = Join-Path $dest "$t.xml"
    $xml = schtasks /Query /TN "\$t" /XML 2>$null
    if ($LASTEXITCODE -eq 0 -and $xml) {
        $xml | Out-File -FilePath $out -Encoding Unicode
        Write-Host "exported: $t"
    } else {
        Write-Warning "task not found (skipped): $t"
    }
}

Write-Host "`nSnapshot complete. Review: cd $repoRoot\fleet-configs ; git status"
