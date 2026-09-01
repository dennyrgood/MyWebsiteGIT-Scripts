# ChatWorkHorse\cwh-health-monitor.ps1
# 2026-08-31 UTC -- created, modeled on AmsterdamDesktop/amsdt-health-monitor.ps1
# (which was itself modeled on Denniss2ndMacBookAir/mb2-health-monitor.sh). Same
# shape: missing/down per service, streak-based anti-flap, alert on first detection +
# every 30 min while active, all-clear on resolution, silent when healthy.
#
# Services checked here are cwh's REAL scheduled tasks/processes, confirmed 2026-08-31
# via Get-ScheduledTask + Get-NetTCPConnection + Win32_Process CommandLine (not assumed
# -- amsdt taught us Flask ports especially are not to be guessed):
#   Fleet Checker      -> checker.py                    (no HTTP endpoint)
#   Fleet Status        -> fleet_api.py                  :5010
#   OpenWebUI            -> run_openwebui_cw.bat -> open-webui.exe serve :8080
#   ComfyUI              -> ComfyUI\main.py (python_embeded) :8188
#   Ollama                -> ollama.exe serve             :11434
#   Cloudflared Tunnel    -> cloudflared tunnel run imageTunnel   (no local HTTP)
#
# NOT re-checked here (deliberately -- each already has its own auto-healing or
# logging elsewhere; this script's job is to alert when THAT mechanism is failing,
# not duplicate it):
#   Fleet Metrics Server (:9100) / Hearbeat Writer OneDrive -- self-healed every 5 min
#     by Status\FleetMetricsWatchdog.ps1, which never emails. Checked below via its
#     own last-task-result + staleness only.
#   ups-watch-task-fixed -- polls the NUT server on WorkBenchUnix and shuts this box
#     (and the CWHU VM) down after a sustained outage; only logs to ups-watch.log,
#     never emails. Checked below via its own last-task-result + a log tail for
#     recent WARN lines, same "watch the watchdog" pattern as FleetMetricsWatchdog.
#   ChatWorkhorseUnix VM -- this box hosts the CWHU VirtualBox VM (see cwhu-is-a-vm.md).
#     "Start CWHU VM" only fires at boot; if the VM dies mid-session nothing restarts
#     it and nothing alerts. Checked below via VBoxManage list runningvms.
#
# Requires this task to run with highest privileges (Win32_Process's CommandLine
# comes back blank for other-session processes otherwise).
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$HostName = "chatworkhorse"
$StateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$Now = [int][double]::Parse((Get-Date -UFormat %s))
$AlertIntervalSec = 30 * 60
$FailThreshold = 2   # consecutive 5-min samples before alerting (anti-flap on restarts)
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

$Services = @(
    @{ Name = "FleetChecker";      Pattern = "checker\.py";                       Url = $null },
    @{ Name = "FleetStatusAPI";    Pattern = "fleet_api\.py";                     Url = "http://127.0.0.1:5010/" },
    @{ Name = "OpenWebUI";         Pattern = "open-webui\.exe|run_openwebui_cw";  Url = "http://127.0.0.1:8080/" },
    @{ Name = "ComfyUI";           Pattern = "ComfyUI\\main\.py";                 Url = "http://127.0.0.1:8188/system_stats" },
    @{ Name = "Ollama";            Pattern = "ollama\.exe serve";                 Url = "http://127.0.0.1:11434/api/tags" },
    @{ Name = "CloudflaredTunnel"; Pattern = "cloudflared.*imageTunnel";          Url = $null }
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
foreach ($k in @("WATCHDOG", "UPSWATCH", "CWHUVM")) {
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
    if ($wdInfo.LastTaskResult -ne 0 -and $wdInfo.LastTaskResult -ne 267009 -and $wdInfo.LastTaskResult -ne 2147946720) {
        # 267009 (SCHED_S_TASK_RUNNING) means this health-monitor's own poll happened to
        # land while the watchdog was still mid-execution -- transient, not a failure
        # (confirmed 2026-08-31 on sgc: a real false alert from this exact race).
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

# --- Check: ups-watch-task-fixed itself (last-run result + recent WARN lines), read-only ---
$UpsWatchTriggered = 0
$UpsWatchDetail = ""
try {
    $uwInfo = Get-ScheduledTaskInfo -TaskName "ups-watch-task-fixed" -ErrorAction Stop
    if ($uwInfo.LastTaskResult -ne 0 -and $uwInfo.LastTaskResult -ne 267009 -and $uwInfo.LastTaskResult -ne 2147946720) {
        # 267009 (SCHED_S_TASK_RUNNING) -- same transient-race exception as the watchdog
        # check above, not a real failure.
        # 2147946720 (0x800710E0) is the same overlap race's flip side -- Task
        # Scheduler refusing to start the next trigger while the prior run was
        # still going. See sgc-health-monitor.ps1 for the full writeup.
        $UpsWatchTriggered = 1
        $UpsWatchDetail = "Last result: $($uwInfo.LastTaskResult). Last run: $($uwInfo.LastRunTime)."
    } elseif (((Get-Date) - $uwInfo.LastRunTime).TotalMinutes -gt 15) {
        $UpsWatchTriggered = 1
        $UpsWatchDetail = "Task has not run in $([int]((Get-Date) - $uwInfo.LastRunTime).TotalMinutes) min (expected every few min). Last run: $($uwInfo.LastRunTime)."
    }
} catch {
    $UpsWatchTriggered = 1
    $UpsWatchDetail = "Task 'ups-watch-task-fixed' not found or not queryable: $_"
}
$UpsLogPath = Join-Path $env:ProgramData "ups-watch\ups-watch.log"   # confirmed via ups-watch.ps1's own $StateDir/$LogFile, not guessed
if (Test-Path $UpsLogPath) {
    # Filter by actual timestamp, not just "last N lines" -- on a quiet box, tailing
    # a fixed line count can surface a WARN from days ago that never ages out because
    # too few lines have been appended since (caught 2026-08-31 on ib's equivalent
    # check). Only count WARNs from within this check's own recent window.
    $cutoff = (Get-Date).AddMinutes(-15)
    $recentWarn = Get-Content $UpsLogPath -Tail 100 | Where-Object {
        $_ -match "WARN:" -and $_ -notmatch "not armed" -and
        $_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})Z' -and
        [datetime]::Parse($Matches[1]) -gt $cutoff
    }
    if ($recentWarn) {
        $UpsWatchTriggered = 1
        $UpsWatchDetail += " Recent WARN lines: $(($recentWarn | Select-Object -Last 3) -join ' | ')"
    }
}

# --- Check: ChatWorkhorseUnix VM actually running ---
$CwhuVmTriggered = 0
try {
    $running = & $VBoxManage list runningvms 2>$null
    if (-not ($running -match "ChatWorkhorseUnix")) {
        $CwhuVmTriggered = 1
    }
} catch {
    $CwhuVmTriggered = 1
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

# Watchdog / ups-watch / VM checks -- no streak, sticky-fault reasoning (same as WBU's
# UPS replace-battery and amsdt's watchdog check): one bad sample is meaningful.
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
Test-StickyAlert $UpsWatchTriggered "UPSWATCH" $UpsWatchDetail "UPS WATCH TASK TROUBLE" ([ref]$AlertBody) ([ref]$ClearBody)
Test-StickyAlert $CwhuVmTriggered "CWHUVM" "VBoxManage list runningvms does not include ChatWorkhorseUnix -- the VM is stopped/crashed. Its own health-monitor/nightly-summary and any service inside it are unreachable." "CHATWORKHORSEUNIX VM NOT RUNNING" ([ref]$AlertBody) ([ref]$ClearBody)

# --- Educational footer ---
$Footer = @"
------------------------------------------------------------------------
WHAT THESE ALERTS MEAN AND WHAT TO DO
------------------------------------------------------------------------

<SVC> MISSING / NOT RESPONDING:
Same pattern as amsdt-health-monitor.ps1 -- process gone, or running but its
HTTP endpoint isn't answering. Requires $FailThreshold consecutive checks
(~$($FailThreshold * 5) min) before alerting.

What to do:
  1. Get-ScheduledTask | Where-Object TaskName -match '<task name>'
  2. schtasks /Run /TN "<task name>"

FLEET METRICS WATCHDOG TROUBLE / UPS WATCH TASK TROUBLE:
Both of these are self-healing/self-acting scripts on their own 5-min Task
Scheduler trigger that never send mail themselves -- this alert means their
own last run failed, went stale, or (ups-watch) logged a WARN it couldn't
resolve.

What to do:
  1. Get-Content C:\fleet_monitor\watchdog_$HostName.log -Tail 50
  2. Get-Content C:\repos\scripts\ups-watch.log -Tail 50
  3. schtasks /Query /TN "Fleet Metrics Watchdog" /V /FO LIST
  4. schtasks /Query /TN "ups-watch-task-fixed" /V /FO LIST

CHATWORKHORSEUNIX VM NOT RUNNING:
This box hosts the ChatWorkhorseUnix VirtualBox VM. "Start CWHU VM" only
fires at boot -- nothing restarts the VM if it dies mid-session.

What to do:
  1. & "$VBoxManage" list runningvms
  2. & "$VBoxManage" startvm "ChatWorkhorseUnix" --type headless
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
