# ChatWorkHorse\cwh-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on AmsterdamDesktop/amsdt-nightly-summary.ps1.
# Runs once nightly via Task Scheduler. Sends one email with a TLDR block + detail.
#
# cwh's CHECKER_HOST is NOT truncated (13 chars, under the 15-char NetBIOS limit that
# bit amsterdamdesktop) -- confirmed 2026-08-31 via Get-ChildItem: C:\fleet_monitor\
# chatworkhorse\ is the checker's own subdirectory, same as $HostName.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime (see AmsterdamDesktop's version -- Send-MailMessage
# needs -Encoding UTF8 too, already set in this folder's Send-FleetMail.ps1).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "chatworkhorse"
$CheckerHost = "chatworkhorse"   # not truncated on this box -- see header note
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$UpsWatchLog = Join-Path $env:ProgramData "ups-watch\ups-watch.log"   # confirmed via ups-watch.ps1's own $StateDir/$LogFile, not guessed
$AllStatusFile = Join-Path (Join-Path $FleetMonitorDir $CheckerHost) "server_status_all.json"
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- Fleet Checker: fleet-wide view from THIS box's checker.py instance ---
if (Test-Path $AllStatusFile) {
    $ageStr = Format-Age (Get-Item $AllStatusFile).LastWriteTime
    try {
        $status = Get-Content $AllStatusFile -Raw | ConvertFrom-Json
        $s = $status.summary
        $line = "  fleet-checker: [$ageStr ago] machines $($s.machines_up)/$($s.machines_total) up, services $($s.services_up)/$($s.services_total) up, public $($s.public_endpoints_up)/$($s.public_endpoints_total) up"
        if ($s.machines_down -gt 0 -or $s.services_down -gt 0 -or $s.public_endpoints_down -gt 0) {
            $Tldr += "$Warn$line`r`n"
            if ($Reason -eq "all healthy") { $Reason = "fleet checker sees $($s.machines_down) machine(s)/$($s.services_down) service(s) down" }
        } else {
            $Tldr += "$line $Check`r`n"
        }
        $Body += "=== FLEET CHECKER SUMMARY (this box's instance) ===`r`n"
        $Body += "$($status.meta | ConvertTo-Json -Compress)`r`n$($s | ConvertTo-Json -Compress)`r`n`r`n"
        if ($s.machines_down -gt 0 -or $s.services_down -gt 0) {
            $downMachines = $status.machines | Where-Object { $_.host.status -ne "up" }
            $Body += "Machines not up: $(($downMachines | ForEach-Object { $_.machine.display_name }) -join ', ')`r`n`r`n"
        }
    } catch {
        $Tldr += "$Warn  fleet-checker: [$ageStr ago] could not parse server_status_all.json: $_`r`n"
        if ($Reason -eq "all healthy") { $Reason = "fleet checker output unparseable" }
    }
    if ((New-TimeSpan -Start (Get-Item $AllStatusFile).LastWriteTime -End (Get-Date)).TotalMinutes -gt 10) {
        if ($Reason -eq "all healthy") { $Reason = "fleet checker output stale ($ageStr)" }
    }
} else {
    $Tldr += "$Warn  fleet-checker: server_status_all.json not found at $AllStatusFile`r`n"
    if ($Reason -eq "all healthy") { $Reason = "fleet checker output missing" }
}

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

# --- ChatWorkhorseUnix VM ---
try {
    $running = & $VBoxManage list runningvms 2>$null
    if ($running -match "ChatWorkhorseUnix") {
        $Tldr += "  ChatWorkhorseUnix VM: running $Check`r`n"
    } else {
        $Tldr += "$Warn  ChatWorkhorseUnix VM: NOT running`r`n"
        if ($Reason -eq "all healthy") { $Reason = "ChatWorkhorseUnix VM not running" }
    }
} catch {
    $Tldr += "$Warn  ChatWorkhorseUnix VM: could not query VBoxManage: $_`r`n"
    if ($Reason -eq "all healthy") { $Reason = "VBoxManage query failed" }
}

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 10) {
        $Tldr += "$Warn  cwh-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 10m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  cwh-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  cwh-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  cwh-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  cwh-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji ChatWorkhorse nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
