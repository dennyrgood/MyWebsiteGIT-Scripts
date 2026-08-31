# RemoteWS\rws-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on TravelBeast/tb-nightly-summary.ps1. Runs once
# nightly via Task Scheduler. Sends one email with a TLDR block + supporting detail.
#
# rws has no Fleet Checker task -- not a Fleet Status Checker instance (those are
# amsdt + cwh only), so no server_status_all.json section here, same as tb/ib.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "remotews"
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$JcWatchdogLog = Join-Path $FleetMonitorDir "jumpconnect_watchdog_$HostName.log"
$TsWatchdogLog = Join-Path $FleetMonitorDir "tailscale_watchdog_$HostName.log"
$PowerHbDir = Join-Path $FleetMonitorDir "power_heartbeat_remotews"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- Core services: JumpConnect (this box's whole purpose), Syncthing, Plex ---
try {
    $jc = Get-Service -Name "JumpConnect" -ErrorAction Stop
    if ($jc.Status -eq "Running") {
        $Tldr += "  JumpConnect: Running $Check`r`n"
    } else {
        $Tldr += "$Warn  JumpConnect: $($jc.Status) (should be Running)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "JumpConnect not running" }
    }
} catch {
    $Tldr += "$Warn  JumpConnect: service not found`r`n"
    if ($Reason -eq "all healthy") { $Reason = "JumpConnect service missing" }
}
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

# --- Watchdog logs (FleetMetrics, JumpConnect, Tailscale) ---
foreach ($pair in @(
    @{ Label = "watchdog log";           Path = $WatchdogLog },
    @{ Label = "jumpconnect watchdog log"; Path = $JcWatchdogLog },
    @{ Label = "tailscale watchdog log";   Path = $TsWatchdogLog }
)) {
    if (Test-Path $pair.Path) {
        $age = Format-Age (Get-Item $pair.Path).LastWriteTime
        $Tldr += "  $($pair.Label): [$age ago] $(Get-Content $pair.Path -Tail 1)`r`n"
        $Body += "=== $($pair.Label) (last 10 lines) ===`r`n"
        $Body += (Get-Content $pair.Path -Tail 10 | Out-String)
        $Body += "`r`n"
    } else {
        $Tldr += "$Warn  $($pair.Label): not found at $($pair.Path)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "$($pair.Label) missing" }
    }
}

# --- power-heartbeat: most recent CSV, row count ---
$latestCsv = Get-ChildItem $PowerHbDir -Filter "power_heartbeat_v4_*.csv" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestCsv) {
    $age = Format-Age $latestCsv.LastWriteTime
    $rows = (Import-Csv $latestCsv.FullName | Measure-Object).Count
    $Tldr += "  power-heartbeat: [$age ago] $($latestCsv.Name), $rows sample(s) $Check`r`n"
} else {
    $Tldr += "$Warn  power-heartbeat: no CSV found in $PowerHbDir`r`n"
    if ($Reason -eq "all healthy") { $Reason = "power-heartbeat log missing" }
}

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 10) {
        $Tldr += "$Warn  rws-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 10m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  rws-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  rws-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  rws-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  rws-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji RemoteWS nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
