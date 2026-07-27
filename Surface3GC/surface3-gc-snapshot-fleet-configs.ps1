# surface3-gc-snapshot-fleet-configs.ps1
# Created 2026-07-21; hardened 2026-07-21.
# surface3-gc is a NO-REPO box. It STAGES its bespoke fleet files + Task Scheduler
# exports into OneDrive\ForFleetConfigs\surface3-gc\, for a repo machine (this Mac) to
# collect with collect-fleet-configs-from-onedrive.sh.
#
# Hardened like the repo-Windows scripts: tasks are found by their ACTION (so the
# display name doesn't matter, e.g. "Fleet Metrics Server"), and one stale/protected
# task is skipped with a warning instead of aborting. Do NOT set
# $ErrorActionPreference='Stop' (it turns schtasks' stderr into a terminating error).
#
# Delivery: this script lives in the scripts repo (scripts/Surface3GC/) as source of
# truth; it's pushed to OneDrive by push-snapshots-to-onedrive.sh. Run manually.

$Box = "surface3-gc"
$src = "C:\Misc"                 # where this box's bespoke writer / vbs / metrics server live

$od = if ($env:OneDrive) { $env:OneDrive } elseif ($env:OneDriveConsumer) { $env:OneDriveConsumer } else { Join-Path $env:USERPROFILE "OneDrive" }
if (-not (Test-Path $od)) { Write-Error "OneDrive path not found: $od"; return }

$dest   = Join-Path $od "ForFleetConfigs\$Box"
$xmlDir = Join-Path $dest "TaskSched"
New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null

# 1) copy the bespoke script files the fleet actually uses (not in any repo on this box)
Get-ChildItem -Path "$src\*" -Include *.ps1, *.vbs, *.py -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'heartbeat|fleet_metrics_server|run_hidden|Bekah|GC_' } |
    ForEach-Object { Copy-Item $_.FullName $dest -Force; Write-Host "copied: $($_.Name)" }

# 2) export fleet-related Task Scheduler tasks (found by action) as UTF-16 XML
$wanted = @(Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet[-_ ]?metrics[-_ ]?server|fleet[-_ ]?monitor|heartbeat|run[-_ ]?hidden|watchdog|bekah|gc_'
} | ForEach-Object { $_.TaskName } | Select-Object -Unique)

Write-Host "Tasks to export:"; $wanted | ForEach-Object { Write-Host "  [$_]" }; Write-Host ""

foreach ($t in $wanted) {
    $out = Join-Path $xmlDir "$t.xml"
    try {
        $xml = & schtasks /Query /TN "\$t" /XML 2>$null
        if ($LASTEXITCODE -eq 0 -and $xml) { $xml | Out-File -FilePath $out -Encoding Unicode; Write-Host "exported: $t" }
        else { Write-Warning "skipped '$t' (protected or inaccessible -- exit $LASTEXITCODE)" }
    } catch { Write-Warning "skipped '$t' ($($_.Exception.Message))" }
}

Write-Host "`nStaged to $dest"
Write-Host "Collect it from your Mac: scripts/collect-fleet-configs-from-onedrive.sh"
