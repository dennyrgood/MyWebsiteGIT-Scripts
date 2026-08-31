# AmsterdamDesktop\amsdt-health-monitor.ps1
# 2026-08-31 UTC -- created, modeled on Denniss2ndMacBookAir/mb2-health-monitor.sh
# (itself modeled on DennissMacBookAir/mb-health-monitor.sh / MathesMacMini's), ported
# to PowerShell for the Windows fleet. Same shape: missing/down per service, streak-based
# anti-flap, alert on first detection + every 30 min while active, all-clear on
# resolution, silent when healthy. Mail via Send-FleetMail.ps1 (iCloud SMTP) instead of
# msmtp.
#
# Services checked here are amsdt's REAL scheduled tasks/processes, confirmed 2026-08-31
# via Get-ScheduledTask + Get-NetTCPConnection + reading each Flask app's app.run() call
# directly (not assumed):
#   Flask Excel Backend       -> excel_backend.py            :5000
#   Flask Full Edit Backend   -> excel_backend_full_edit.py  :5001
#   Flask Weather Proxy       -> weather_backend.py          :5005
#   Fleet status (Fleet API)  -> fleet_api.py                :5010
#   OpenWebUI                 -> run_openwebui_ams.bat       :8080
#   Fleet Checker             -> checker.py                  (no HTTP endpoint -- polls
#                                 the rest of the fleet and writes a status file; only a
#                                 process-presence check is possible here)
#   Cloudflared Tunnel        -> cloudflared.exe tunnel run weather-flask-proxy
#                                 (no local HTTP endpoint -- process-presence only)
#
# Fleet Metrics Server (:9100) and HeartbeatWriter are DELIBERATELY NOT re-checked here:
# Status\FleetMetricsWatchdog.ps1 already monitors + auto-heals both every 5 min via its
# own Task Scheduler trigger. What FleetMetricsWatchdog does NOT do is notify -- it only
# logs and exits 1 on a failed restart. So this script's job for that pair is narrower:
# alert if the watchdog itself is failing to fix things (last task result != 0) or has
# gone stale (hasn't run recently), not re-implement its checks.
#
# Requires this task to run with highest privileges (Get-CimInstance Win32_Process's
# CommandLine comes back blank for other-session processes otherwise -- same gotcha
# documented in FleetMetricsWatchdog.ps1).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "amsterdamdesktop"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60
$FailThreshold = 2   # consecutive 5-min samples before alerting (anti-flap on restarts)

$Services = @(
    @{ Name = "FlaskExcelBackend";     Pattern = "excel_backend\.py";            Url = "http://127.0.0.1:5000/" },
    @{ Name = "FlaskFullEditBackend";  Pattern = "excel_backend_full_edit\.py";  Url = "http://127.0.0.1:5001/" },
    @{ Name = "FlaskWeatherProxy";     Pattern = "weather_backend\.py";          Url = "http://127.0.0.1:5005/" },
    @{ Name = "FleetStatusAPI";        Pattern = "fleet_api\.py";                Url = "http://127.0.0.1:5010/" },
    @{ Name = "OpenWebUI";             Pattern = "run_openwebui_ams\.bat|open-webui|openwebui"; Url = "http://127.0.0.1:8080/" },
    @{ Name = "FleetChecker";          Pattern = "checker\.py";                  Url = $null },
    @{ Name = "CloudflaredTunnel";     Pattern = "cloudflared\.exe.*weather-flask-proxy"; Url = $null }
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
$State["WATCHDOG_LAST_ALERT"] = 0
$State["WATCHDOG_ACTIVE"] = 0

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
        # No HTTP endpoint for this one (FleetChecker, CloudflaredTunnel) -- process
        # presence is all we can check.
        $DownTriggered[$svc.Name] = 0
        continue
    }
    try {
        $resp = Invoke-WebRequest -Uri $svc.Url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $DownTriggered[$svc.Name] = if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { 0 } else { 1 }
    } catch {
        # Flask's default 404/405 on "/" for an app with no root route still proves the
        # server answered -- only a connection failure/timeout means "down".
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $DownTriggered[$svc.Name] = 0
        } else {
            $DownTriggered[$svc.Name] = 1
        }
    }
}

# --- Check: FleetMetricsWatchdog itself (last-run result + staleness) ---
# Read-only -- this script never touches the watchdog's own restart logic.
$WatchdogTriggered = 0
$WatchdogDetail = ""
try {
    $wdTask = Get-ScheduledTask -TaskName "Fleet Metrics Watchdog" -ErrorAction Stop
    $wdInfo = Get-ScheduledTaskInfo -TaskName "Fleet Metrics Watchdog" -ErrorAction Stop
    if ($wdInfo.LastTaskResult -ne 0 -and $wdInfo.LastTaskResult -ne 267009) {
        # 267009 (SCHED_S_TASK_RUNNING) means this health-monitor's own poll happened to
        # land while the watchdog was still mid-execution -- transient, not a failure
        # (confirmed 2026-08-31 on sgc: a real false alert from this exact race). Same
        # exception s3g/tb's equivalent checks already use.
        $WatchdogTriggered = 1
        $WatchdogDetail = "Last result: $($wdInfo.LastTaskResult) (nonzero = a restart attempt failed -- see watchdog_$HostName.log under fleet_monitor). Last run: $($wdInfo.LastRunTime)."
    } else {
        $ageMin = ((Get-Date) - $wdInfo.LastRunTime).TotalMinutes
        if ($ageMin -gt 15) {
            # Should fire every 5 min -- 3x margin before treating it as stalled/unscheduled.
            $WatchdogTriggered = 1
            $WatchdogDetail = "Task has not run in $([int]$ageMin) min (expected every 5 min). Last run: $($wdInfo.LastRunTime)."
        }
    }
} catch {
    $WatchdogTriggered = 1
    $WatchdogDetail = "Task 'Fleet Metrics Watchdog' not found or not queryable: $_"
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

    # Missing
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

    # Down (process present, HTTP check failing)
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

# Watchdog (no streak -- it already only fires after its own restart attempts fail, so
# one bad sample is meaningful; same "sticky fault" reasoning as WBU's UPS replace-battery
# check).
if ($WatchdogTriggered -eq 1) {
    if ($State["WATCHDOG_ACTIVE"] -eq 0 -or ($Now - $State["WATCHDOG_LAST_ALERT"]) -ge $AlertIntervalSec) {
        $State["WATCHDOG_LAST_ALERT"] = $Now; $State["WATCHDOG_ACTIVE"] = 1
        $AlertBody += "=== FLEET METRICS WATCHDOG TROUBLE ===`r`n$WatchdogDetail`r`n`r`nThis means Fleet Metrics Server and/or HeartbeatWriter may be down and the watchdog`r`ncouldn't fix it -- amsdt may be invisible to the fleet dashboard.`r`n`r`n"
    } else {
        $State["WATCHDOG_ACTIVE"] = 1
    }
} elseif ($State["WATCHDOG_ACTIVE"] -eq 1) {
    $State["WATCHDOG_ACTIVE"] = 0
    $ClearBody += "  - Fleet Metrics Watchdog is healthy again`r`n"
}

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

<SVC> MISSING:
No process with a matching command line was found -- it quit, crashed, or the
Task Scheduler task isn't running. Requires $FailThreshold consecutive checks
(~$($FailThreshold * 5) min) before alerting, to ride out a normal restart.

What to do:
  1. Get-ScheduledTask | Where-Object TaskName -match '<task name>'
  2. schtasks /Run /TN "<task name>"
  3. Check for a console/log window if the task runs visibly, or the app's own log file.

<SVC> NOT RESPONDING:
The process is running but its own HTTP endpoint isn't answering -- likely hung.

What to do:
  1. Invoke-WebRequest <url> -UseBasicParsing
  2. schtasks /End /TN "<task name>"; schtasks /Run /TN "<task name>"

FLEET METRICS WATCHDOG TROUBLE:
Status\FleetMetricsWatchdog.ps1 runs every 5 min and self-heals Fleet Metrics
Server (:9100) and HeartbeatWriter, but it only logs and exits 1 on failure --
it never sends mail itself. This alert means its own restart attempts failed,
or it hasn't run at all recently.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_$HostName.log -Tail 50
  2. schtasks /Query /TN "Fleet Metrics Watchdog" /V /FO LIST
  3. schtasks /Run /TN "Fleet Metrics Watchdog"
------------------------------------------------------------------------
"@

# --- Save state ---
$lines = $State.Keys | Sort-Object | ForEach-Object { "$_=$($State[$_])" }
Set-Content -Path $StateFile -Value $lines

# --- Send alert email ---
if ($AlertBody -ne "") {
    Send-FleetMail -Subject "[$HostName] HEALTH ALERT -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body "$AlertBody`r`n$Footer" | Out-Null
}

# --- Send all-clear email ---
if ($ClearBody -ne "") {
    Send-FleetMail -Subject "[$HostName] ALL CLEAR -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body "The following conditions have resolved:`r`n`r`n$ClearBody" | Out-Null
}

# --- Heartbeat: one line to stdout every run, so Task Scheduler's log/History gives
# positive proof this ran vs. silently broke (mirrors mb/mb2's rationale). ---
$activeCount = ($State.Keys | Where-Object { $_ -match "_ACTIVE$" -and $State[$_] -eq 1 }).Count
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') check complete -- $activeCount active alert(s)"
