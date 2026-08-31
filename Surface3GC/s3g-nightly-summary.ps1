# Surface3GC\s3g-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on RemoteWS/rws-nightly-summary.ps1. Runs once
# nightly via Task Scheduler. Sends one email with a TLDR block + supporting detail.
#
# s3g has no Fleet Checker task -- not a Fleet Status Checker instance (those are
# amsdt + cwh only), so no server_status_all.json section here, same as ib/tb/rws.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "surface3-gc"
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$ResticJsonPath = Join-Path $FleetMonitorDir "watchdog_restic-offsite_surface3-gc.json"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- Core services: Syncthing, Plex ---
$sync = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "syncthing\.exe.*--no-browser" }
if ($sync) { $Tldr += "  Syncthing: running $Check`r`n" } else {
    $Tldr += "$Warn  Syncthing: not running`r`n"
    if ($Reason -eq "all healthy") { $Reason = "Syncthing not running" }
}
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:32400/identity" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    $Tldr += "  Plex: responding $Check`r`n"
} catch {
    $Tldr += "$Warn  Plex: not responding on :32400`r`n"
    if ($Reason -eq "all healthy") { $Reason = "Plex not responding" }
}

# --- FleetMetricsWatchdog log tail ---
if (Test-Path $WatchdogLog) {
    $age = Format-Age (Get-Item $WatchdogLog).LastWriteTime
    $Tldr += "  watchdog log: [$age ago] $(Get-Content $WatchdogLog -Tail 1)`r`n"
    $Body += "=== FleetMetricsWatchdog log (last 10 lines) ===`r`n"
    $Body += (Get-Content $WatchdogLog -Tail 10 | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  watchdog log: not found at $WatchdogLog`r`n"
    if ($Reason -eq "all healthy") { $Reason = "watchdog log missing" }
}

# --- Restic offsite integrity: last status JSON ---
if (Test-Path $ResticJsonPath) {
    try {
        $rj = Get-Content $ResticJsonPath -Raw | ConvertFrom-Json
        $age = Format-Age ([datetime]$rj.finished_utc)
        $status = if ($rj.ok) { $Check } else { $Warn }
        $Tldr += "  restic-offsite: [$age ago, bucket $($rj.bucket)] $($rj.files_checked) checked, $($rj.mismatches) mismatch(es) $status`r`n"
        if (-not $rj.ok -and $Reason -eq "all healthy") { $Reason = "restic offsite integrity check failed" }
        $Body += "=== Restic offsite integrity (last run) ===`r`n"
        $Body += ($rj | ConvertTo-Json | Out-String)
        $Body += "`r`n"
    } catch {
        $Tldr += "$Warn  restic-offsite: could not parse status JSON: $_`r`n"
        if ($Reason -eq "all healthy") { $Reason = "restic offsite status unparseable" }
    }
} else {
    $Tldr += "$Warn  restic-offsite: no status file found`r`n"
    if ($Reason -eq "all healthy") { $Reason = "restic offsite status missing" }
}

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 12) {
        # 12, not 10 -- see RemoteWS/rws-nightly-summary.ps1 for why (a nightly-summary
        # run landing 10-11 min after the last 5-min tick is normal timing, not staleness).
        $Tldr += "$Warn  s3g-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 12m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  s3g-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  s3g-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  s3g-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  s3g-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji Surface3GC nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
