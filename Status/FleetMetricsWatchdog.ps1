# FleetMetricsWatchdog.ps1
#
# Hardens both halves of the fleet-metrics pipeline on this box:
#   1. Fleet Metrics Server (serves fleet_monitor/ over HTTP on port 9100)
#   2. Heartbeat Writer     (writes heartbeat_/machine_info_/metrics_history_ files)
#
# A server that's down/hung fails the HTTP check outright. A writer that's died
# (process gone, but server still up) looks like a normal 200 OK with a heartbeat
# timestamp that stops advancing - so the two need separate detection and separate
# fixes: restarting the server does nothing for a dead writer, and vice versa.
#
# Task DISPLAY NAMES drift across the fleet and are not trustworthy - confirmed
# 2026-07-27: "Heartbeat Writer" (travelbeast, ImageBeast), "HeartbeatWriter"
# (AmsterdamDesktop, no space), "Hearbeat Writer OneDrive" (ChatWorkHorse, typo'd
# "Hearbeat" + OneDrive suffix left over from the old transport), "Heartbeat Write
# OneDrive" (Surface3GC, typo'd "Write" not "Writer"). Task names are discovered
# by ACTION (the script path each task actually runs), same trick the fleet-configs
# snapshot scripts use, so display-name drift/typos never matter. Several boxes
# (travelbeast, ImageBeast, ChatWorkHorse, AmsterdamDesktop) launch via a generic
# "wscript.exe run_hidden*.vbs" wrapper whose OWN action never mentions the real
# script - only the .vbs file's contents do - so discovery reads the .vbs too when
# an action points at one, not just the task's Execute/Arguments fields.
#
# Run on a recurring Task Scheduler trigger (e.g. every 5 min). Safe to run
# even when everything is healthy - does nothing in that case.
#
# ASCII only - PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII.

$ErrorActionPreference = "Stop"

$serverPort = 9100
$staleThresholdMinutes = 10   # writer updates heartbeat every ~150s; 10 min = 4x margin

# Same hostname resolution as onedrive_heartbeat_writer_server.ps1 - keep in sync
$hostnameMap = @{
    "amsterdamdeskto" = "amsterdamdesktop"
    "surfacegolaptop" = "surfacegolaptopgc"
}
$rawHost = $env:COMPUTERNAME.ToLower()
$checkerHost = if ($hostnameMap.ContainsKey($rawHost)) { $hostnameMap[$rawHost] } else { $rawHost }

# fleet_monitor is fleet_metrics_server.py's served dir - "watchdog_<host>.log" matches
# its _ALLOWED filename pattern, so this log is fetchable over 9100 like the other files.
$fleetMonitorDir = if ($env:FLEET_METRICS_DIR) { $env:FLEET_METRICS_DIR } else { "C:\fleet_monitor" }
$logFile = Join-Path $fleetMonitorDir "watchdog_$checkerHost.log"
$aliveMarkerFile = Join-Path $fleetMonitorDir ".watchdog_$checkerHost.alive"

$checkUrl = "http://127.0.0.1:9100/heartbeat_$checkerHost.txt"
$timeoutSec = 5

function Log($msg) {
    $line = "$(Get-Date -Format o) $msg"
    Write-Output $line
    Add-Content -Path $logFile -Value $line
}

# A healthy run logs nothing (by design - see below), which is indistinguishable
# from the watchdog not running at all. Ping the log once per calendar day (plus
# always on the very first run, i.e. no marker file yet - covers "just deployed"
# and "just rebooted") so "no issues today" is visible without waiting for a
# failure. Deliberately NOT every run - that'd be a line every 5 min, too noisy.
$today = (Get-Date).ToString("yyyy-MM-dd")
$lastAliveDate = if (Test-Path $aliveMarkerFile) { (Get-Content $aliveMarkerFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
if ($lastAliveDate -ne $today) {
    Log "watchdog alive, checking..."
    Set-Content -Path $aliveMarkerFile -Value $today
}

# Requires the watchdog task itself to "Run with highest privileges" - both
# Get-ScheduledTask's action/argument visibility and Win32_Process's CommandLine
# come back incomplete/blank for other-session processes otherwise (confirmed
# 2026-07-22 on remotews: a non-elevated check silently found nothing, letting
# duplicate writer processes pile up undetected).
function Get-TaskNameByAction($pattern, $fallback) {
    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        foreach ($t in $tasks) {
            foreach ($a in $t.Actions) {
                $haystack = "$($a.Execute) $($a.Arguments)"
                # Many boxes launch via a generic "wscript.exe run_hidden*.vbs" wrapper -
                # the task's own action never mentions the real script (heartbeat_writer,
                # fleet_metrics_server), only the .vbs file's CONTENTS do. Read it too, or
                # every VBS-wrapped box falls through to the fallback name (silently wrong
                # on any box whose task isn't literally named that fallback).
                if ($a.Execute -match "wscript" -and $a.Arguments -match "\.vbs") {
                    $vbsPath = $a.Arguments -replace '^"|"$', ''
                    if (Test-Path $vbsPath) {
                        try { $haystack += " " + (Get-Content $vbsPath -Raw) } catch {}
                    }
                }
                if ($haystack -match $pattern) { return $t.TaskName }
            }
        }
    } catch {}
    return $fallback
}

$serverTaskName = Get-TaskNameByAction "fleet_metrics_server" "Fleet Metrics Server"
$writerTaskName = Get-TaskNameByAction "heartbeat_writer|onedrive_heartbeat_writer" "Heartbeat Writer"

# Match patterns are per-role and must stay mutually exclusive - a shared/blanket
# pattern here previously killed the server while trying to restart the writer
# (both processes were visible in the same CIM query, and a loose OR matched both).
$rolePattern = @{
    "server" = "fleet_metrics_server"
    "writer" = "heartbeat_writer"
}

# Returns: $null if unreachable, otherwise the heartbeat's UTC timestamp.
function Get-HeartbeatTimestamp {
    try {
        $response = Invoke-WebRequest -Uri $checkUrl -TimeoutSec $timeoutSec -UseBasicParsing
        if ($response.StatusCode -ne 200) { return $null }
        return [DateTime]::Parse($response.Content.Trim()).ToUniversalTime()
    } catch {
        return $null
    }
}

function Restart-Task($taskName, $role) {
    # schtasks /End only kills processes Task Scheduler is actively tracking. These
    # are launched via a hidden VBS wrapper, so the real process is detached from
    # Scheduler's tracking and /End silently no-ops, leaving an old process (if any)
    # still running when /Run tries to start a new one. Kill by command line instead.
    $pattern = $rolePattern[$role]
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $pattern }
        foreach ($p in $procs) {
            Log "killing PID $($p.ProcessId) ($($p.CommandLine))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    try { schtasks /End /TN "$taskName" 2>$null } catch {}
    Start-Sleep -Seconds 2
    schtasks /Run /TN "$taskName" | Out-Null
}

# ── Duplicate check: are there multiple copies of the same process running? ──
# A dead/stuck restart attempt (schtasks /End not actually killing the detached
# process before /Run launches a new one) can pile up duplicates that all look
# individually healthy - e.g. two writer processes both happily updating the
# same heartbeat file. The staleness/reachability checks below wouldn't catch
# this since the file still gets fresh writes. Keep the newest, kill the rest.
foreach ($role in $rolePattern.Keys) {
    $pattern = $rolePattern[$role]
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $pattern })
    } catch {
        $procs = @()
    }
    if ($procs.Count -gt 1) {
        $sorted = $procs | Sort-Object CreationDate -Descending
        $keep = $sorted[0]
        Log "found $($procs.Count) duplicate processes for '$role', keeping newest PID $($keep.ProcessId), killing the rest"
        foreach ($p in ($sorted | Select-Object -Skip 1)) {
            Log "killing duplicate PID $($p.ProcessId) ($($p.CommandLine))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Server check: is fleet_metrics_server.py answering at all? ────────────
$serverConn = $null
try {
    $serverConn = Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue
} catch {}

$heartbeat = Get-HeartbeatTimestamp

if (-not $heartbeat -and -not $serverConn) {
    Log "server not responding (port $serverPort not listening / $checkUrl unreachable), restarting '$serverTaskName'"

    try {
        foreach ($c in (Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue)) {
            Log "killing PID $($c.OwningProcess) holding port $serverPort"
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try { schtasks /End /TN "$serverTaskName" 2>$null } catch {}
    Start-Sleep -Seconds 2

    $maxAttempts = 3
    $restarted = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Log "server restart attempt $attempt/$maxAttempts"
        schtasks /Run /TN "$serverTaskName" | Out-Null
        Start-Sleep -Seconds 5
        $heartbeat = Get-HeartbeatTimestamp
        if ($heartbeat) {
            Log "server restart attempt $attempt succeeded"
            $restarted = $true
            break
        }
        Log "server restart attempt $attempt failed"
    }

    if (-not $restarted) {
        $lastResult = (schtasks /Query /TN "$serverTaskName" /V /FO LIST | Select-String "Last Result")
        Log "SERVER RESTART FAILED after $maxAttempts attempts. Task status: $lastResult"
        exit 1
    }
}

# ── Writer check: is the heartbeat timestamp actually advancing? ──────────
# Only meaningful once we know the server itself is reachable (above).
if ($heartbeat) {
    $ageMinutes = (New-TimeSpan -Start $heartbeat -End (Get-Date).ToUniversalTime()).TotalMinutes
    if ($ageMinutes -gt $staleThresholdMinutes) {
        Log "heartbeat is stale (${ageMinutes} min old, threshold $staleThresholdMinutes), restarting '$writerTaskName'"
        Restart-Task $writerTaskName "writer"

        Start-Sleep -Seconds 10
        $newHeartbeat = Get-HeartbeatTimestamp
        $newAge = if ($newHeartbeat) { (New-TimeSpan -Start $newHeartbeat -End (Get-Date).ToUniversalTime()).TotalMinutes } else { $null }

        if ($newHeartbeat -and $newAge -lt $ageMinutes) {
            Log "writer restart succeeded, heartbeat now ${newAge} min old"
        } else {
            $lastResult = (schtasks /Query /TN "$writerTaskName" /V /FO LIST | Select-String "Last Result")
            Log "WRITER RESTART FAILED or not yet confirmed fresh. Task status: $lastResult"
            exit 1
        }
    }
}

exit 0
