# RemoteWS\rws-health-monitor.ps1
# 2026-08-31 UTC -- created, modeled on TravelBeast/tb-health-monitor.ps1. Same shape:
# missing/down per service, streak-based anti-flap, alert on first detection + every
# 30 min while active, all-clear on resolution, silent when healthy.
#
# Services checked here are rws's REAL scheduled tasks/processes/Windows services,
# confirmed 2026-08-31 via Get-ScheduledTask + Get-Service + Get-NetTCPConnection +
# Win32_Process CommandLine:
#   JumpConnect (Win32_Service "JumpConnect") -- rws's whole purpose is remote access
#     via Jump Desktop; this is the actual remote-desktop service, not a task.
#   Syncthing   -> syncthing.exe --no-browser (launched by "Start Syncthing at logon")
#   Plex Media Server -> HTTP :32400/identity (200 = healthy; confirmed reachable
#     2026-08-31 -- Plex runs as a normal background app here, NOT a Windows service,
#     only PlexUpdateService is registered as a service)
#
# NOT re-checked here (deliberately -- each already has its own auto-healing or
# logging elsewhere; this script's job is to alert when THAT mechanism is failing,
# not duplicate it). Unlike FleetMetricsWatchdog (runs once every 5 min and exits),
# these three are long-lived LOOP tasks (State stays "Running" continuously, and
# Get-ScheduledTaskInfo's LastTaskResult is meaningless while a loop task is still
# running -- it only updates when the loop itself exits). So the check here is: is the
# task still in State=Running, AND has its own log advanced recently (it self-pings
# roughly daily, same convention as FleetMetricsWatchdog.ps1's "ping the log once a
# day so a healthy-and-silent run is still visible" design)?
#   Fleet Metrics Server (:9100) / Heartbeat Writer -- self-healed every 5 min by
#     Status\FleetMetricsWatchdog.ps1 (run-once-and-exit style), never emails.
#   JumpConnect Watchdog -- RemoteWS\jumpconnect-watchdog.ps1, restarts the JumpConnect
#     service if it's running but has no established outbound connection ("wedged
#     after a network blip"). Loop-style task, logs to
#     C:\fleet_monitor\jumpconnect_watchdog_remotews.log, never emails.
#   Tailscale Watchdog -- RemoteWS\tailscale-watchdog.ps1, same loop-style pattern,
#     logs to C:\fleet_monitor\tailscale_watchdog_remotews.log, never emails.
#   Power Heartbeat Logger -- rws's own WiFi/power diagnostic (RemoteWS\
#     power-heartbeat.ps1), same loop-style pattern as TravelBeast's equivalent, logs
#     to C:\fleet_monitor\power_heartbeat_remotews\, never emails.
#
# Requires this task to run with highest privileges (Win32_Process's CommandLine
# comes back blank for other-session processes otherwise).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "remotews"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60
$FailThreshold = 2   # consecutive 5-min samples before alerting (anti-flap on restarts)

$Services = @(
    @{ Name = "Syncthing";        Pattern = "syncthing\.exe.*--no-browser"; Url = $null },
    @{ Name = "PlexMediaServer";  Pattern = $null; ServiceCheck = $false;   Url = "http://127.0.0.1:32400/identity" }
)

# --- Load state ---
$State = @{}
foreach ($svc in $Services) {
    $State["MISSING_$($svc.Name)_LAST_ALERT"] = 0
    $State["MISSING_$($svc.Name)_ACTIVE"] = 0
    $State["MISSING_$($svc.Name)_STREAK"] = 0
    $State["DOWN_$($svc.Name)_LAST_ALERT"] = 0
    $State["DOWN_$($svc.Name)_ACTIVE"] = 0
    $State["DOWN_$($svc.Name)_STREAK"] = 0
}
$State["MISSING_JumpConnect_LAST_ALERT"] = 0
$State["MISSING_JumpConnect_ACTIVE"] = 0
$State["MISSING_JumpConnect_STREAK"] = 0
foreach ($k in @("WATCHDOG", "JCWATCHDOG", "TSWATCHDOG", "POWERHB")) {
    $State["${k}_LAST_ALERT"] = 0
    $State["${k}_ACTIVE"] = 0
}

if (Test-Path $StateFile) {
    Get-Content $StateFile | ForEach-Object {
        if ($_ -match "^([A-Za-z0-9_]+)=(.*)$") {
            $State[$Matches[1]] = [int]$Matches[2]
        }
    }
}

$AllProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
$MissingTriggered = @{}
$DownTriggered = @{}

# --- Syncthing: process presence only ---
$sync = $AllProcs | Where-Object { $_.CommandLine -match "syncthing\.exe.*--no-browser" }
$MissingTriggered["Syncthing"] = if ($sync) { 0 } else { 1 }
$DownTriggered["Syncthing"] = 0

# --- Plex Media Server: HTTP only (background app, not a task/service to pattern-match) ---
try {
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:32400/identity" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    $MissingTriggered["PlexMediaServer"] = 0
    $DownTriggered["PlexMediaServer"] = if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { 0 } else { 1 }
} catch {
    # No response at all -- treat as missing (Plex isn't running / isn't listening),
    # same "missing" semantics as a process-pattern miss elsewhere.
    $MissingTriggered["PlexMediaServer"] = 1
    $DownTriggered["PlexMediaServer"] = 0
}

# --- JumpConnect: Windows service, not a process-pattern match (its own watchdog
# already tracks connectivity -- this is just "is the service itself even running") ---
try {
    $jcSvc = Get-Service -Name "JumpConnect" -ErrorAction Stop
    $MissingTriggered["JumpConnect"] = if ($jcSvc.Status -eq "Running") { 0 } else { 1 }
} catch {
    $MissingTriggered["JumpConnect"] = 1
}

# --- Check: FleetMetricsWatchdog itself (run-once-and-exit style: last-run result +
# staleness), read-only ---
$WatchdogTriggered = 0
$WatchdogDetail = ""
try {
    $wdInfo = Get-ScheduledTaskInfo -TaskName "Fleet Metrics Watchdog" -ErrorAction Stop
    if ($wdInfo.LastTaskResult -ne 0 -and $wdInfo.LastTaskResult -ne 267009) {
        # 267009 (SCHED_S_TASK_RUNNING) means this health-monitor's own poll happened to
        # land while the watchdog was still mid-execution -- transient, not a failure
        # (confirmed 2026-08-31 on sgc: a real false alert from this exact race).
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

# --- Check: loop-style watchdog tasks (JumpConnect Watchdog, Tailscale Watchdog) --
# State must be Running, and their own DAILY MARKER FILE (".<name>_watchdog_remotews
# .alive", same pattern FleetMetricsWatchdog.ps1 uses) must have advanced within the
# last ~26h. NOT the main .log file -- confirmed 2026-08-31 that the main log can go
# 3+ days without a new line even while the marker updates daily and the task is
# genuinely healthy (the "watchdog alive, checking..." line only gets appended on
# some code path that doesn't always fire the same run the marker gets touched, or
# the log simply has nothing to report and the marker is the more reliable signal
# either way) -- using the log's mtime here produced an immediate false alert on
# first run despite both tasks being confirmed healthy.
function Test-LoopTaskHealthy($taskName, $markerPath) {
    $trig = 0
    $detail = ""
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if ($t.State -ne "Running") {
            $trig = 1
            $detail = "Task state is '$($t.State)', expected 'Running' (this is a continuous loop task)."
        }
    } catch {
        $trig = 1
        $detail = "Task '$taskName' not found or not queryable: $_"
    }
    if ($trig -eq 0) {
        if (Test-Path $markerPath) {
            $age = (New-TimeSpan -Start (Get-Item $markerPath).LastWriteTime -End (Get-Date)).TotalHours
            if ($age -gt 26) {
                $trig = 1
                $detail = "Daily alive-marker hasn't advanced in $([int]$age)h. Marker: $markerPath"
            }
        } else {
            $trig = 1
            $detail = "Alive-marker not found at $markerPath"
        }
    }
    return @($trig, $detail)
}
$r = Test-LoopTaskHealthy "JumpConnect Watchdog" "C:\fleet_monitor\.jumpconnect_watchdog_remotews.alive"
$JcWatchdogTriggered = $r[0]; $JcWatchdogDetail = $r[1]
$r = Test-LoopTaskHealthy "Tailscale Watchdog" "C:\fleet_monitor\.tailscale_watchdog_remotews.alive"
$TsWatchdogTriggered = $r[0]; $TsWatchdogDetail = $r[1]

# Power Heartbeat Logger writes samples every ~16s while active, BUT unlike
# TravelBeast's equivalent, rws's own history (checked 2026-08-31 -- 18 days of CSVs)
# shows a consistent ~17h nightly gap (files stop ~8pm, resume next afternoon) -- this
# box is evidently not kept awake/online round the clock. A tight staleness window
# would false-alarm every night, so this uses a generous ~22h threshold instead
# (catches a genuine multi-day stall, tolerates the box's normal overnight gap).
# Filename pattern also confirmed directly, NOT assumed from TravelBeast's script --
# rws is on "power_heartbeat_v4_<date>.csv" with no hostname suffix (TravelBeast's is
# "_v3_travelbeast_<date>.csv"); each box's power-heartbeat.ps1 has its own $LogDir/
# filename evolution, don't copy-paste the pattern across boxes.
$PowerHbTriggered = 0
$PowerHbDetail = ""
try {
    $phTask = Get-ScheduledTask -TaskName "Power Heartbeat Logger" -ErrorAction Stop
    if ($phTask.State -ne "Running") {
        $PowerHbTriggered = 1
        $PowerHbDetail = "Task state is '$($phTask.State)', expected 'Running' (this is a continuous loop task)."
    } else {
        $phDir = "C:\fleet_monitor\power_heartbeat_remotews"
        $latestCsv = Get-ChildItem $phDir -Filter "power_heartbeat_v4_*.csv" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestCsv) {
            $csvAgeHours = (New-TimeSpan -Start $latestCsv.LastWriteTime -End (Get-Date)).TotalHours
            if ($csvAgeHours -gt 22) {
                $PowerHbTriggered = 1
                $PowerHbDetail = "Most recent CSV ($($latestCsv.Name)) hasn't been written to in $([int]$csvAgeHours)h (threshold accounts for this box's normal overnight idle gap)."
            }
        } else {
            $PowerHbTriggered = 1
            $PowerHbDetail = "No power_heartbeat_v4_*.csv found in $phDir"
        }
    }
} catch {
    $PowerHbTriggered = 1
    $PowerHbDetail = "Task 'Power Heartbeat Logger' not found or not queryable: $_"
}

# --- Evaluate: streak-aware alert/suppress/clear/ok ---
function Get-Verdict($triggered, $lastAlert, $wasActive, $streak, $threshold) {
    if ($triggered -eq 1) {
        $streak = $streak + 1
        if ($streak -ge $threshold) {
            if ($wasActive -eq 0 -or ($Now - $lastAlert) -ge $AlertIntervalSec) {
                return @("alert", $streak)
            } else {
                return @("suppress", $streak)
            }
        } else {
            return @("wait", $streak)
        }
    } elseif ($wasActive -eq 1) {
        return @("clear", 0)
    } else {
        return @("ok", 0)
    }
}

$AlertBody = ""
$ClearBody = ""

foreach ($n in @("Syncthing", "PlexMediaServer", "JumpConnect")) {
    $r = Get-Verdict $MissingTriggered[$n] $State["MISSING_${n}_LAST_ALERT"] $State["MISSING_${n}_ACTIVE"] $State["MISSING_${n}_STREAK"] $FailThreshold
    $State["MISSING_${n}_STREAK"] = $r[1]
    switch ($r[0]) {
        "alert" {
            $State["MISSING_${n}_LAST_ALERT"] = $Now; $State["MISSING_${n}_ACTIVE"] = 1
            $AlertBody += "=== $n MISSING ===`r`nNot detected for $($r[1]) consecutive checks (~$($r[1] * 5) min).`r`n`r`n"
        }
        "clear"   { $State["MISSING_${n}_ACTIVE"] = 0; $ClearBody += "  - $n is back`r`n" }
        "suppress" { $State["MISSING_${n}_ACTIVE"] = 1 }
        default   { $State["MISSING_${n}_ACTIVE"] = 0 }
    }
}
# PlexMediaServer's DOWN case (running but HTTP unhealthy) -- MISSING already covers
# "not responding at all", so DOWN here would only mean a non-2xx/4xx response, which
# is rare enough to fold into the same MISSING path above rather than duplicate it.

function Test-StickyAlert($triggered, $key, $detail, $header, [ref]$alertBody, [ref]$clearBody) {
    if ($triggered -eq 1) {
        if ($State["${key}_ACTIVE"] -eq 0 -or ($Now - $State["${key}_LAST_ALERT"]) -ge $AlertIntervalSec) {
            $State["${key}_LAST_ALERT"] = $Now; $State["${key}_ACTIVE"] = 1
            $alertBody.Value += "=== $header ===`r`n$detail`r`n`r`n"
        } else {
            $State["${key}_ACTIVE"] = 1
        }
    } elseif ($State["${key}_ACTIVE"] -eq 1) {
        $State["${key}_ACTIVE"] = 0
        $clearBody.Value += "  - $header resolved`r`n"
    }
}
Test-StickyAlert $WatchdogTriggered "WATCHDOG" $WatchdogDetail "FLEET METRICS WATCHDOG TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)
Test-StickyAlert $JcWatchdogTriggered "JCWATCHDOG" $JcWatchdogDetail "JUMPCONNECT WATCHDOG TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)
Test-StickyAlert $TsWatchdogTriggered "TSWATCHDOG" $TsWatchdogDetail "TAILSCALE WATCHDOG TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)
Test-StickyAlert $PowerHbTriggered "POWERHB" $PowerHbDetail "POWER HEARTBEAT LOGGER TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

JUMPCONNECT MISSING:
The JumpConnect Windows service isn't Running. Since rws's whole purpose is
remote access via Jump Desktop, this is the highest-priority alert on this box.

What to do:
  1. Get-Service JumpConnect
  2. Start-Service JumpConnect
  3. Get-Content C:\fleet_monitor\jumpconnect_watchdog_remotews.log -Tail 30

SYNCTHING / PLEXMEDIASERVER MISSING:
Process/HTTP endpoint not detected for $FailThreshold consecutive checks
(~$($FailThreshold * 5) min).

What to do:
  1. Syncthing: check "Start Syncthing at logon (drden@REMOTEWS)" task, or
     relaunch C:\Users\drden\AppData\Local\Programs\Syncthing\stctl.exe --start
  2. Plex: relaunch Plex Media Server from the Start Menu, or
     Get-Service PlexUpdateService (only the updater is a real service here)

FLEET METRICS WATCHDOG / JUMPCONNECT WATCHDOG / TAILSCALE WATCHDOG / POWER
HEARTBEAT LOGGER TROUBLE:
Each is a self-healing/self-logging script that never emails. This alert
means its task isn't in the expected state, or its own log has gone stale.

What to do:
  1. Get-ScheduledTask -TaskName "<name>" | Select State
  2. schtasks /Run /TN "<name>"
  3. Get-Content C:\fleet_monitor\<task-specific log> -Tail 30
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
