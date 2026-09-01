# Surface3GC\s3g-health-monitor.ps1
# 2026-08-31 UTC -- created, modeled on RemoteWS/rws-health-monitor.ps1. Same shape:
# missing/down per service, streak-based anti-flap, alert on first detection + every
# 30 min while active, all-clear on resolution, silent when healthy.
#
# Services checked here are s3g's REAL scheduled tasks/processes, confirmed 2026-08-31
# via Get-ScheduledTask + Get-NetTCPConnection + Win32_Process CommandLine:
#   Syncthing         -> syncthing.exe --no-browser (launched by "Start Syncthing at logon")
#   Plex Media Server -> HTTP :32400/identity (200 = healthy; runs as a background app
#     here too, not a Windows service -- only PlexUpdateService is a real service)
#
# s3g has no JumpConnect/Tailscale watchdog, no ComfyUI/Ollama/OpenWebUI -- confirmed
# via Get-ScheduledTask + process listing, not assumed from rws/ib/cwh.
#
# NOT re-checked here (deliberately -- each already has its own logging elsewhere;
# this script's job is to alert when THAT mechanism is failing, not duplicate it):
#   Fleet Metrics Server (:9100) / Heartbeat Write OneDrive -- self-healed every 5 min
#     by Status\FleetMetricsWatchdog.ps1, never emails. Checked below via its own
#     last-task-result + staleness only.
#   Restic Offsite Integrity Check -- Surface3GC\verify-restic-integrity-scheduled.ps1,
#     runs on an irregular multi-week cadence (confirmed: last run 08/28, next
#     scheduled 09/16 -- roughly every ~19 days, verifying one rotating "bucket" of
#     the offsite restic repo each time), writes a JSON status file (NOT a log, no
#     mail) to C:\fleet_monitor\watchdog_restic-offsite_surface3-gc.json with an "ok"
#     boolean + mismatch/unreadable counts. Checked below via that JSON's "ok" field;
#     staleness uses a generous 30-day window given the irregular cadence (checking
#     against a fixed short interval would either miss a real stall or false-alarm
#     between normal runs -- there's no fixed "every N days" guarantee to check against
#     precisely, so this errs toward not nagging over normal schedule variance).
#
# Requires this task to run with highest privileges (Win32_Process's CommandLine
# comes back blank for other-session processes otherwise).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "surface3-gc"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60
$FailThreshold = 2   # consecutive 5-min samples before alerting (anti-flap on restarts)

# --- Load state ---
$State = @{}
foreach ($n in @("Syncthing", "PlexMediaServer")) {
    $State["MISSING_${n}_LAST_ALERT"] = 0
    $State["MISSING_${n}_ACTIVE"] = 0
    $State["MISSING_${n}_STREAK"] = 0
}
foreach ($k in @("WATCHDOG", "RESTIC")) {
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

# --- Syncthing: process presence only ---
$sync = $AllProcs | Where-Object { $_.CommandLine -match "syncthing\.exe.*--no-browser" }
$MissingTriggered["Syncthing"] = if ($sync) { 0 } else { 1 }

# --- Plex Media Server: HTTP only (background app, not a task/service to pattern-match) ---
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:32400/identity" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    $MissingTriggered["PlexMediaServer"] = 0
} catch {
    $MissingTriggered["PlexMediaServer"] = 1
}

# --- Check: FleetMetricsWatchdog itself (last-run result + staleness), read-only ---
$WatchdogTriggered = 0
$WatchdogDetail = ""
try {
    $wdInfo = Get-ScheduledTaskInfo -TaskName "Fleet Metrics Watchdog" -ErrorAction Stop
    if ($wdInfo.LastTaskResult -ne 0 -and $wdInfo.LastTaskResult -ne 267009 -and $wdInfo.LastTaskResult -ne 2147946720) {
        # 267009 (SCHED_S_TASK_RUNNING) seen alongside State=Running on this box's
        # sample -- treat as "currently executing", not a failure, same exception
        # tb/rws's loop-task checks use.
        # 2147946720 (0x800710E0) is the same overlap race's flip side -- Task
        # Scheduler refusing to start the next trigger while the prior run was
        # still going. See sgc-health-monitor.ps1 for the full writeup.
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

# --- Check: Restic Offsite Integrity Check's own JSON status, read-only ---
$ResticTriggered = 0
$ResticDetail = ""
$ResticJsonPath = "C:\fleet_monitor\watchdog_restic-offsite_surface3-gc.json"
if (Test-Path $ResticJsonPath) {
    try {
        $rj = Get-Content $ResticJsonPath -Raw | ConvertFrom-Json
        if (-not $rj.ok) {
            $ResticTriggered = 1
            $ResticDetail = "ok=false. $($rj.note) (mismatches=$($rj.mismatches), unreadable=$($rj.unreadable), bucket=$($rj.bucket))"
        }
        $ageDays = (New-TimeSpan -Start ([datetime]$rj.finished_utc) -End (Get-Date).ToUniversalTime()).TotalDays
        if ($ageDays -gt 30) {
            $ResticTriggered = 1
            $ResticDetail += " Last successful check was $([int]$ageDays)d ago (expected roughly every ~19 days)."
        }
    } catch {
        $ResticTriggered = 1
        $ResticDetail = "Could not parse $ResticJsonPath : $_"
    }
} else {
    $ResticTriggered = 1
    $ResticDetail = "No status file found at $ResticJsonPath -- integrity check may have never run."
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

foreach ($n in @("Syncthing", "PlexMediaServer")) {
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
Test-StickyAlert $ResticTriggered "RESTIC" $ResticDetail "RESTIC OFFSITE INTEGRITY CHECK TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

SYNCTHING / PLEXMEDIASERVER MISSING:
Process/HTTP endpoint not detected for $FailThreshold consecutive checks
(~$($FailThreshold * 5) min).

What to do:
  1. Syncthing: check "Start Syncthing at logon (DrDen@SURFACE3-GC)" task, or
     relaunch C:\Users\DrDen\AppData\Local\Programs\Syncthing\stctl.exe --start
  2. Plex: relaunch Plex Media Server from the Start Menu

FLEET METRICS WATCHDOG TROUBLE:
Status\FleetMetricsWatchdog.ps1 self-heals Fleet Metrics Server and Heartbeat
Write OneDrive every 5 min but never emails -- this alert means its own
restart attempts failed, or it hasn't run recently.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_$HostName.log -Tail 50
  2. schtasks /Query /TN "Fleet Metrics Watchdog" /V /FO LIST

RESTIC OFFSITE INTEGRITY CHECK TROUBLE:
The offsite backup verification found mismatched/unreadable files, or hasn't
completed a successful check in a long time.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_restic-offsite_surface3-gc.json
  2. schtasks /Query /TN "Restic Offsite Integreity Check" /V /FO LIST
  3. schtasks /Run /TN "Restic Offsite Integreity Check"  (note the fleet's
     own typo'd task name -- "Integreity", not "Integrity")
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
