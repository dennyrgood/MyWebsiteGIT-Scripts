# AmsterdamDesktop\amsdt-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on ChatWorkhorseUnix/cwhu-nightly-summary.sh,
# ported to PowerShell. Runs once nightly via Task Scheduler. Sends one email with a
# TLDR block + supporting detail; subject is a single-glance PASS/FAIL summary.
#
# Paths confirmed on-box 2026-08-31 (NOT guessed -- Get-ChildItem'd directly):
#   Fleet Metrics Server / HeartbeatWriter files: C:\fleet_monitor\*_amsterdamdesktop.*
#     (flat, full COMPUTERNAME)
#   Fleet Checker (checker.py) output:            C:\fleet_monitor\amsterdamdeskto\
#     (subdirectory -- CHECKER_HOST in config.py is the NetBIOS-truncated 15-char
#     hostname "amsterdamdeskto", not the full "amsterdamdesktop". Same truncation
#     FleetMetricsWatchdog.ps1's $hostnameMap works around for the flat files -- this
#     script needs the truncated form directly since it's a real directory name here,
#     not just a lookup key.)
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# The check/warning marks below are built from character codes rather than typed as
# literal emoji, so the .ps1 SOURCE stays pure ASCII while still emitting the real
# glyphs (matching the Mac/Ubuntu scripts' subjects) at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)               # (check mark button)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F # (warning sign, emoji style)

$HostName = "amsterdamdesktop"
$CheckerHost = "amsterdamdeskto"   # NetBIOS-truncated -- see header note
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$AllStatusFile = Join-Path (Join-Path $FleetMonitorDir $CheckerHost) "server_status_all.json"

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

        $downMachines = @($status.machines | Where-Object { $_.host.status -ne "up" })
        $downServices = @()
        foreach ($m in $status.machines) {
            foreach ($svc in $m.services) {
                $tsDown = $svc.tailscale_check.status -ne "up"
                $pubDown = $svc.public_check -and $svc.public_check.status -ne "up"
                if ($tsDown -or $pubDown) {
                    $tsStatus = $svc.tailscale_check.status
                    $pubStatus = if ($svc.public_check) { $svc.public_check.status } else { "n/a" }
                    $detailMsg = if ($tsDown) { $svc.tailscale_check.detail } else { $svc.public_check.detail }
                    $downServices += [PSCustomObject]@{
                        Name   = "$($m.machine.display_name)/$($svc.name)"
                        Detail = "$($m.machine.display_name)/$($svc.name): tailscale=$tsStatus public=$pubStatus detail=$detailMsg"
                    }
                }
            }
        }

        $line = "  fleet-checker: [$ageStr ago] machines $($s.machines_up)/$($s.machines_total) up, services $($s.services_up)/$($s.services_total) up, public $($s.public_endpoints_up)/$($s.public_endpoints_total) up"
        if ($s.machines_down -gt 0 -or $s.services_down -gt 0 -or $s.public_endpoints_down -gt 0) {
            $Tldr += "$Warn$line`r`n"
            if ($Reason -eq "all healthy") {
                $namedDown = @($downMachines | ForEach-Object { $_.machine.display_name }) + @($downServices | ForEach-Object { $_.Name })
                if ($namedDown.Count -gt 0 -and $namedDown.Count -le 4) {
                    $Reason = "down: $($namedDown -join ', ')"
                } else {
                    $Reason = "fleet checker sees $($s.machines_down) machine(s)/$($s.services_down) service(s) down"
                }
            }
        } else {
            $Tldr += "$line $Check`r`n"
        }
        $Body += "=== FLEET CHECKER SUMMARY (this box's instance) ===`r`n"
        $Body += "$($status.meta | ConvertTo-Json -Compress)`r`n$($s | ConvertTo-Json -Compress)`r`n`r`n"
        if ($downMachines.Count -gt 0) {
            $Body += "Machines not up: $(($downMachines | ForEach-Object { $_.machine.display_name }) -join ', ')`r`n`r`n"
        }
        if ($downServices.Count -gt 0) {
            $Body += "Services not up:`r`n$(($downServices | ForEach-Object { $_.Detail }) -join "`r`n")`r`n`r`n"
        }
    } catch {
        $Tldr += "$Warn  fleet-checker: [$ageStr ago] could not parse server_status_all.json: $_`r`n"
        if ($Reason -eq "all healthy") { $Reason = "fleet checker output unparseable" }
    }
    # Staleness -- checker polls every 30s per config; 10 min stale is a large margin.
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

# --- Health monitor state (amsdt-health-monitor.ps1's own watchdog-on-the-watchdog) ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 10) {
        $Tldr += "$Warn  amsdt-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 10m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  amsdt-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  amsdt-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  amsdt-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  amsdt-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji AmsterdamDesktop nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body -Cc "dennis.mathes@icloud.com" | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
