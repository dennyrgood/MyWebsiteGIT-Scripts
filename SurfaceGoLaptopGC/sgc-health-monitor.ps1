# SurfaceGoLaptopGC\sgc-health-monitor.ps1
# 2026-08-31 UTC -- created. sgc is a NEW box being brought into the fleet (may
# eventually replace surface3-gc) -- as of this writing it has no ComfyUI/Ollama/
# Syncthing/Plex/etc., just the base Fleet Metrics pipeline that was set up alongside
# this script (Fleet Metrics Server, Heartbeat Write OneDrive, Fleet Metrics Watchdog
# tasks -- see fleet-configs/SurfaceGoLaptopGC/TaskSched/ and
# Status/README_MOVE_AWAY_ONEDRIVE.md's "Adding / redoing a box" section).
#
# Deliberately minimal by design (per user: "minimal / mail is fine for now") -- this
# is a placeholder shaped like the rest of the fleet's health-monitors, easy to extend
# with real service checks (Syncthing/Plex/etc. -- see RemoteWS or Surface3GC's
# versions for the pattern) once sgc actually runs something worth monitoring.
#
# Same shape as every other box's health-monitor: streak-based anti-flap, alert on
# first detection + every 30 min while active, all-clear on resolution, silent when
# healthy.
#
# NOT re-checked here (deliberately -- self-heals every 5 min via
# Status\FleetMetricsWatchdog.ps1, which never emails; this script's job is to alert
# when THAT mechanism is failing, not duplicate it):
#   Fleet Metrics Server (:9100) / Heartbeat Write OneDrive
#
# sgc's hostname truncates at the Windows 15-char NetBIOS limit (SURFACEGOLAPTOPGC ->
# SURFACEGOLAPTOP), same class of issue amsdt hit -- Status\FleetMetricsWatchdog.ps1
# and onedrive_heartbeat_writer_server.ps1 both got a $hostnameMap entry added for
# this ("surfacegolaptop" -> "surfacegolaptopgc") when this box was set up 2026-08-31.
#
# Requires this task to run with highest privileges (matches the rest of the fleet's
# health-monitors, even though this one doesn't currently need Win32_Process access --
# keeping it consistent so adding a process-based check later doesn't also require
# re-elevating the task).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "surfacegolaptopgc"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60

# --- Load state ---
$State = @{}
$State["WATCHDOG_LAST_ALERT"] = 0
$State["WATCHDOG_ACTIVE"] = 0

if (Test-Path $StateFile) {
    Get-Content $StateFile | ForEach-Object {
        if ($_ -match "^([A-Za-z0-9_]+)=(.*)$") {
            $State[$Matches[1]] = [int]$Matches[2]
        }
    }
}

# --- Check: FleetMetricsWatchdog itself (last-run result + staleness), read-only ---
$WatchdogTriggered = 0
$WatchdogDetail = ""
try {
    $wdInfo = Get-ScheduledTaskInfo -TaskName "Fleet Metrics Watchdog" -ErrorAction Stop
    if ($wdInfo.LastTaskResult -ne 0) {
        $WatchdogTriggered = 1
        $WatchdogDetail = "Last result: $($wdInfo.LastTaskResult) (nonzero = a restart attempt failed). Last run: $($wdInfo.LastRunTime)."
    } elseif (((Get-Date) - $wdInfo.LastRunTime).TotalMinutes -gt 15) {
        $WatchdogTriggered = 1
        $WatchdogDetail = "Task has not run in $([int]((Get-Date) - $wdInfo.LastRunTime).TotalMinutes) min (expected every 5 min). Last run: $($wdInfo.LastRunTime)."
    }
} catch {
    $WatchdogTriggered = 1
    $WatchdogDetail = "Task 'Fleet Metrics Watchdog' not found or not queryable: $_"
}

$AlertBody = ""
$ClearBody = ""

if ($WatchdogTriggered -eq 1) {
    if ($State["WATCHDOG_ACTIVE"] -eq 0 -or ($Now - $State["WATCHDOG_LAST_ALERT"]) -ge $AlertIntervalSec) {
        $State["WATCHDOG_LAST_ALERT"] = $Now; $State["WATCHDOG_ACTIVE"] = 1
        $AlertBody += "=== FLEET METRICS WATCHDOG TROUBLE ===`r`n$WatchdogDetail`r`n`r`n"
    } else {
        $State["WATCHDOG_ACTIVE"] = 1
    }
} elseif ($State["WATCHDOG_ACTIVE"] -eq 1) {
    $State["WATCHDOG_ACTIVE"] = 0
    $ClearBody += "  - FLEET METRICS WATCHDOG TROUBLE resolved`r`n"
}

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

FLEET METRICS WATCHDOG TROUBLE:
Status\FleetMetricsWatchdog.ps1 self-heals Fleet Metrics Server and Heartbeat
Write OneDrive every 5 min but never emails -- this alert means its own
restart attempts failed, or it hasn't run recently.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_$HostName.log -Tail 50
  2. schtasks /Query /TN "Fleet Metrics Watchdog" /V /FO LIST
------------------------------------------------------------------------
"@

# --- Save state ---
$lines = $State.Keys | Sort-Object | ForEach-Object { "$_=$($State[$_])" }
Set-Content -Path $StateFile -Value $lines

if ($AlertBody -ne "") {
    Send-FleetMail -Subject "[$HostName] HEALTH ALERT -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body "$AlertBody`r`n$Footer" | Out-Null
}
if ($ClearBody -ne "") {
    Send-FleetMail -Subject "[$HostName] ALL CLEAR -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body "The following conditions have resolved:`r`n`r`n$ClearBody" | Out-Null
}

$activeCount = ($State.Keys | Where-Object { $_ -match "_ACTIVE$" -and $State[$_] -eq 1 }).Count
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') check complete -- $activeCount active alert(s)"
