# SurfaceGoLaptopGC\sgc-nightly-summary.ps1
# 2026-08-31 UTC -- created. Minimal by design, matching sgc-health-monitor.ps1 -- see
# that file's header for context (new box, may replace surface3-gc eventually, only
# real infra so far is the Fleet Metrics pipeline).
#
# sgc has no Fleet Checker task -- not a Fleet Status Checker instance (those are
# amsdt + cwh only), so no server_status_all.json section here, same as ib/tb/rws/s3g.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "surfacegolaptopgc"
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$HeartbeatFile = Join-Path $FleetMonitorDir "heartbeat_$HostName.txt"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- Heartbeat file freshness (proves the writer + metrics server pipeline works) ---
if (Test-Path $HeartbeatFile) {
    $age = Format-Age (Get-Item $HeartbeatFile).LastWriteTime
    $Tldr += "  heartbeat: [$age ago] $(Get-Content $HeartbeatFile) $Check`r`n"
} else {
    $Tldr += "$Warn  heartbeat: not found at $HeartbeatFile`r`n"
    if ($Reason -eq "all healthy") { $Reason = "heartbeat file missing" }
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

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 12) {
        $Tldr += "$Warn  sgc-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 12m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  sgc-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  sgc-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  sgc-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  sgc-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji SurfaceGoLaptopGC nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body -Cc "dennis.mathes@icloud.com" | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
