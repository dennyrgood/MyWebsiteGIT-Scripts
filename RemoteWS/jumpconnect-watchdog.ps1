# jumpconnect-watchdog.ps1
#
# RemoteWS is a remote-access box - Jump Desktop (via the JumpConnect service,
# Phase Five Systems) is the primary remote-desktop path, SSH is the fallback.
#
# Confirmed 2026-08-22: after a WiFi/network outage, JumpConnect can come back
# "Running" but wedged - its outbound connection to Jump's relay went stale
# during the blip and it never reconnects on its own. Windows' own service
# recovery config (3x auto-restart on failure) does NOT help here, because the
# process never actually crashes/exits - it just sits there alive and useless.
# SSH (a fresh TCP connection each time) kept working the whole time, which is
# how this got noticed; fixed manually with `Restart-Service JumpConnect`.
#
# This watchdog automates that manual fix: JumpConnect "Running" is not enough
# to call it healthy - also require at least one ESTABLISHED outbound TCP
# connection on its process (confirmed healthy pattern: PID holds a :443
# connection to Jump's relay). No such connection => treat as wedged and force
# a service restart, the same fix that worked by hand.
#
# 2026-08-29: rewritten from a one-shot script fired by a Task Scheduler
# "Daily, repeat every 5 min, for a duration of Indefinitely" trigger to a
# single long-running process with its own internal loop, triggered "At
# system startup" - exactly Power Heartbeat Logger's pattern. The repeating-
# trigger version silently stopped being re-invoked after about 3 days with
# no error (LastTaskResult 0, NextRunTime just went blank) - a known Windows
# Task Scheduler quirk where "repeat indefinitely" doesn't actually mean
# indefinitely. Power Heartbeat Logger never had this problem because it was
# never relying on that repetition mechanism in the first place. This changes
# to match: no Task Scheduler repetition setting to silently expire, just one
# process that loops forever until the box reboots (at which point "At
# startup" + SYSTEM brings it right back, no logon required - see Power
# Heartbeat Logger's own notes on why that matters here).
#
# Deployed via Scheduled Task "JumpConnect Watchdog" (At system startup, runs
# as SYSTEM - Restart-Service on another session's service needs admin
# rights, and SYSTEM doesn't need an interactive RDP logon to start).
#
# 2026-08-28: logs into the SAME shared watchdog_remotews.log that
# FleetMetricsWatchdog.ps1 already writes to (not a separate file) - the
# fleet dashboard's existing "WATCHDOG" button/badges already fetch and
# parse that exact file via fleet_api.py's /api/watchdog/<host> endpoint
# (see Status/Web/ST/tiles.html), and "remotews" is already in its host
# list. Piggybacking on it means this shows up on the dashboard with no
# server or dashboard changes - just prefix every line with "[JumpConnect]"
# so it stays distinguishable from FleetMetricsWatchdog's own lines. The
# dashboard's parser treats any line containing "fail" (case-insensitive)
# as an issue and anything else recent as reassuring activity - the prefix
# doesn't interfere with either check, both are substring matches.
#
# ASCII only - PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII.

$ErrorActionPreference = "Continue"

$ServiceName = "JumpConnect"
$LogTag = "[JumpConnect]"
$LogDir = "C:\fleet_monitor"
$LogFile = Join-Path $LogDir "watchdog_remotews.log"
$AliveMarkerFile = Join-Path $LogDir ".jumpconnect_watchdog_remotews.alive"
$PostActionWaitSeconds = 8
$IntervalSeconds = 300   # 5 min, matching the original Task Scheduler repeat cadence

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Log($msg) {
    $line = "$(Get-Date -Format o) $LogTag $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

function Get-JumpConnectProcessId {
    try {
        $cimSvc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($cimSvc -and $cimSvc.ProcessId -gt 0) { return $cimSvc.ProcessId }
    } catch {}
    return $null
}

function Test-HasEstablishedConnection($processId) {
    if (-not $processId) { return $false }
    try {
        $conns = Get-NetTCPConnection -OwningProcess $processId -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -notin @('127.0.0.1', '::1') }
        return (@($conns).Count -gt 0)
    } catch {
        return $false
    }
}

function Invoke-HealthCheck {
    # Same "healthy run logs nothing, except once a day" convention as
    # FleetMetricsWatchdog.ps1 - "no issues today" stays visible without
    # waiting for a failure, but a 5-min cadence doesn't spam a line every run.
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $lastAliveDate = if (Test-Path $AliveMarkerFile) { (Get-Content $AliveMarkerFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
    if ($lastAliveDate -ne $today) {
        Log "watchdog alive, checking..."
        Set-Content -Path $AliveMarkerFile -Value $today
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log "service '$ServiceName' not found on this box - nothing to watch this cycle"
        return
    }

    if ($svc.Status -ne 'Running') {
        Log "service is $($svc.Status), starting it"
        try { Start-Service -Name $ServiceName } catch { Log "Start-Service failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds $PostActionWaitSeconds
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc.Status -ne 'Running') {
            Log "SERVICE START FAILED - still $($svc.Status) after Start-Service"
            return
        }
        Log "service started, now Running"
    }

    $processId = Get-JumpConnectProcessId
    if (Test-HasEstablishedConnection $processId) {
        # Healthy - nothing to do beyond the daily alive ping above.
        return
    }

    Log "service is Running (PID $processId) but has no established outbound connection - likely wedged after a network blip, restarting"
    try {
        Restart-Service -Name $ServiceName -Force
    } catch {
        Log "Restart-Service failed: $($_.Exception.Message)"
        return
    }

    Start-Sleep -Seconds $PostActionWaitSeconds
    $newProcessId = Get-JumpConnectProcessId
    if (Test-HasEstablishedConnection $newProcessId) {
        Log "restart succeeded, PID $newProcessId now has an established outbound connection"
    } else {
        Log "RESTART DID NOT RESTORE CONNECTIVITY (or too soon to tell) - PID $newProcessId"
    }
}

while ($true) {
    try {
        Invoke-HealthCheck
    } catch {
        # Never let a transient WMI/CIM/IO hiccup kill the loop - that would
        # silently turn this back into the exact "stopped and nobody noticed"
        # failure mode this rewrite exists to fix.
        try { Log "unexpected error in health check: $($_.Exception.Message)" } catch {}
    }
    Start-Sleep -Seconds $IntervalSeconds
}
