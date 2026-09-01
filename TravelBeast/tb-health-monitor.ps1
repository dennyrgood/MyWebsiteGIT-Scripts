# TravelBeast\tb-health-monitor.ps1
# 2026-08-31 UTC -- created, modeled on ImageBeast/ib-health-monitor.ps1. Same shape:
# missing/down per service, streak-based anti-flap, alert on first detection + every
# 30 min while active, all-clear on resolution, silent when healthy.
#
# Services checked here are tb's REAL scheduled tasks/processes, confirmed 2026-08-31
# via Get-ScheduledTask + Get-NetTCPConnection + Win32_Process CommandLine:
#   Ollama -> ollama.exe serve   :11434
#
# tb has NO ComfyUI process/task running as of this check (unlike ib/cwh) -- per
# Status/readme.md, tb's ComfyUI has "no public URLs" and this is a travel laptop
# (role: Mobile/Travel), so ComfyUI is evidently started manually/occasionally rather
# than always-on. Deliberately NOT monitored here: alerting on an intentionally-absent
# service would just be noise. If ComfyUI is ever made always-on here, add it the same
# way ib's health-monitor does.
#
# NOT re-checked here (deliberately -- each already has its own auto-healing or
# logging elsewhere; this script's job is to alert when THAT mechanism is failing,
# not duplicate it):
#   Fleet Metrics Server (:9100) / Heartbeat Writer -- self-healed every 5 min by
#     Status\FleetMetricsWatchdog.ps1, which never emails. Checked below via its own
#     last-task-result + staleness only.
#   Power Heartbeat Logger -- TravelBeast's own WiFi-flap diagnostic
#     (TravelBeast\power-heartbeat.ps1), logs signal/reconnect events to its own log
#     file, never emails. Checked the same "watch the watchdog" way: last-task-result
#     + staleness, since losing this diagnostic silently would blind any future
#     WiFi-flap investigation the same way a dead heartbeat writer blinds the fleet
#     dashboard.
#
# tb has no Fleet Checker / Fleet Status API / OpenWebUI / Cloudflared Tunnel tasks and
# no UPS-watch task (confirmed via Get-ScheduledTask, not assumed from other boxes).
#
# Requires this task to run with highest privileges (Win32_Process's CommandLine
# comes back blank for other-session processes otherwise).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "travelbeast"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60
$FailThreshold = 2   # consecutive 5-min samples before alerting (anti-flap on restarts)

$Services = @(
    @{ Name = "Ollama"; Pattern = "ollama\.exe serve"; Url = "http://127.0.0.1:11434/api/tags" }
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
foreach ($k in @("WATCHDOG", "POWERHB")) {
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

# --- Check: all services (process presence via CommandLine match, then HTTP if present) ---
$AllProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
$MissingTriggered = @{}
$DownTriggered = @{}

foreach ($svc in $Services) {
    $match = $AllProcs | Where-Object { $_.CommandLine -match $svc.Pattern }
    if (-not $match) {
        $MissingTriggered[$svc.Name] = 1
        $DownTriggered[$svc.Name] = 0
        continue
    }
    $MissingTriggered[$svc.Name] = 0
    if (-not $svc.Url) {
        $DownTriggered[$svc.Name] = 0
        continue
    }
    try {
        $resp = Invoke-WebRequest -Uri $svc.Url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $DownTriggered[$svc.Name] = if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { 0 } else { 1 }
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $DownTriggered[$svc.Name] = 0
        } else {
            $DownTriggered[$svc.Name] = 1
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

# --- Check: Power Heartbeat Logger itself (task state + CSV freshness), read-only ---
# 2026-09-02 UTC -- fixed a false-positive: this task is a long-lived loop that's
# meant to just keep running for days without restarting, so "LastRunTime" (which
# only advances on an actual restart) is the WRONG signal for "is it still working" --
# confirmed on 2026-09-01/02 that a healthy, continuously-running instance (State
# still Running, CSV still getting fresh ~16s writes the whole time) tripped the old
# ">25h since last restart" check purely because uptime crossed 25h, firing real
# HEALTH ALERT emails every 30 min for hours over something that was never actually
# broken. Checking the CSV's own freshness (like RemoteWS's equivalent check) measures
# the thing that actually matters -- is data still being written -- not how long ago
# the task process happened to start.
$PowerHbTriggered = 0
$PowerHbDetail = ""
try {
    $phTask = Get-ScheduledTask -TaskName "Power Heartbeat Logger" -ErrorAction Stop
    if ($phTask.State -ne "Running") {
        $PowerHbTriggered = 1
        $PowerHbDetail = "Task state is '$($phTask.State)', expected 'Running' (this is a continuous loop task)."
    } else {
        $todayCsv = Join-Path "C:\fleet_monitor\power_heartbeat_travelbeast" ("power_heartbeat_v3_travelbeast_{0:yyyy-MM-dd}.csv" -f (Get-Date))
        if (Test-Path $todayCsv) {
            $csvAgeMin = (New-TimeSpan -Start (Get-Item $todayCsv).LastWriteTime -End (Get-Date)).TotalMinutes
            if ($csvAgeMin -gt 20) {
                $PowerHbTriggered = 1
                $PowerHbDetail = "Today's CSV hasn't been written to in $([int]$csvAgeMin) min (expected every ~16s). File: $todayCsv"
            }
        } else {
            $PowerHbTriggered = 1
            $PowerHbDetail = "No CSV for today found at $todayCsv"
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

foreach ($svc in $Services) {
    $n = $svc.Name

    $r = Get-Verdict $MissingTriggered[$n] $State["MISSING_${n}_LAST_ALERT"] $State["MISSING_${n}_ACTIVE"] $State["MISSING_${n}_STREAK"] $FailThreshold
    $State["MISSING_${n}_STREAK"] = $r[1]
    switch ($r[0]) {
        "alert" {
            $State["MISSING_${n}_LAST_ALERT"] = $Now; $State["MISSING_${n}_ACTIVE"] = 1
            $AlertBody += "=== $n MISSING ===`r`nNo process matching '$($svc.Pattern)' found for $($r[1]) consecutive checks (~$($r[1] * 5) min).`r`n`r`n"
        }
        "clear"   { $State["MISSING_${n}_ACTIVE"] = 0; $ClearBody += "  - $n process is back`r`n" }
        "suppress" { $State["MISSING_${n}_ACTIVE"] = 1 }
        default   { $State["MISSING_${n}_ACTIVE"] = 0 }
    }

    $r = Get-Verdict $DownTriggered[$n] $State["DOWN_${n}_LAST_ALERT"] $State["DOWN_${n}_ACTIVE"] $State["DOWN_${n}_STREAK"] $FailThreshold
    $State["DOWN_${n}_STREAK"] = $r[1]
    switch ($r[0]) {
        "alert" {
            $State["DOWN_${n}_LAST_ALERT"] = $Now; $State["DOWN_${n}_ACTIVE"] = 1
            $AlertBody += "=== $n NOT RESPONDING ===`r`nProcess is running but $($svc.Url) did not answer for $($r[1]) consecutive checks.`r`n`r`n"
        }
        "clear"   { $State["DOWN_${n}_ACTIVE"] = 0; $ClearBody += "  - $n is responding again`r`n" }
        "suppress" { $State["DOWN_${n}_ACTIVE"] = 1 }
        default   { $State["DOWN_${n}_ACTIVE"] = 0 }
    }
}

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
Test-StickyAlert $PowerHbTriggered "POWERHB" $PowerHbDetail "POWER HEARTBEAT LOGGER TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

<SVC> MISSING / NOT RESPONDING:
Process gone, or running but its HTTP endpoint isn't answering. Requires
$FailThreshold consecutive checks (~$($FailThreshold * 5) min) before alerting.

What to do:
  1. Get-ScheduledTask | Where-Object TaskName -match '<task name>'
  2. schtasks /Run /TN "<task name>"

FLEET METRICS WATCHDOG TROUBLE:
Status\FleetMetricsWatchdog.ps1 self-heals Fleet Metrics Server and Heartbeat
Writer every 5 min but never emails -- this alert means its own restart
attempts failed, or it hasn't run recently.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_$HostName.log -Tail 50
  2. schtasks /Query /TN "Fleet Metrics Watchdog" /V /FO LIST

POWER HEARTBEAT LOGGER TROUBLE:
TravelBeast\power-heartbeat.ps1 is this box's own WiFi-flap diagnostic --
losing it silently means a future WiFi investigation has no trend line to
correlate against, the same way a dead heartbeat writer blinds the fleet
dashboard. It's a long-running logging loop, not a run-once task, so this
only fires if it (re)started >25h ago or its last exit was a real error.

What to do:
  1. schtasks /Query /TN "Power Heartbeat Logger" /V /FO LIST
  2. schtasks /Run /TN "Power Heartbeat Logger"
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
