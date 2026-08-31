# ImageBeast\ib-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on ChatWorkHorse/cwh-nightly-summary.ps1. Runs once
# nightly via Task Scheduler. Sends one email with a TLDR block + supporting detail.
#
# ib has no Fleet Checker task (confirmed via Get-ScheduledTask 2026-08-31) -- it isn't
# one of the two Fleet Status Checker instances (those are amsdt + cwh only), so unlike
# amsdt/cwh's nightly-summary there is no server_status_all.json section here.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "imagebeast"
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$UpsWatchLog = Join-Path $env:ProgramData "ups-watch\ups-watch.log"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- FleetMetricsWatchdog log tail ---
if (Test-Path $WatchdogLog) {
    $wdAge = Format-Age (Get-Item $WatchdogLog).LastWriteTime
    $Tldr += "  watchdog log: [$wdAge ago last write] $(Get-Content $WatchdogLog -Tail 1)`r`n"
    $Body += "=== FleetMetricsWatchdog log (last 10 lines) ===`r`n"
    $Body += (Get-Content $WatchdogLog -Tail 10 | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  watchdog log: not found at $WatchdogLog`r`n"
    if ($Reason -eq "all healthy") { $Reason = "watchdog log missing" }
}

# --- ups-watch.log tail ---
if (Test-Path $UpsWatchLog) {
    $uwAge = Format-Age (Get-Item $UpsWatchLog).LastWriteTime
    $onBattN = (Get-Content $UpsWatchLog -Tail 500 | Select-String "TRIGGER:" | Measure-Object).Count
    $Tldr += "  ups-watch log: [$uwAge ago last write] on-battery-triggers-in-log-tail=$onBattN`r`n"
    $Body += "=== ups-watch.log (last 10 lines) ===`r`n"
    $Body += (Get-Content $UpsWatchLog -Tail 10 | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  ups-watch log: not found at $UpsWatchLog`r`n"
    if ($Reason -eq "all healthy") { $Reason = "ups-watch log missing" }
}

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 10) {
        $Tldr += "$Warn  ib-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 10m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  ib-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  ib-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  ib-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  ib-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji ImageBeast nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body -Cc "dennis.mathes@icloud.com" | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
