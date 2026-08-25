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
# Run on a recurring Task Scheduler trigger (e.g. every 5 min), as SYSTEM
# (Restart-Service on another session's service needs admin rights - see
# "Power Heartbeat Logger" task for the same SYSTEM-at-startup pattern this
# reuses, just on a timer instead of at-startup). Safe to run when healthy -
# does nothing in that case beyond the once-a-day alive ping.
#
# ASCII only - PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII.

$ErrorActionPreference = "Stop"

$ServiceName = "JumpConnect"
$LogDir = "C:\fleet_monitor"
$LogFile = Join-Path $LogDir "jumpconnect_watchdog_remotews.log"
$AliveMarkerFile = Join-Path $LogDir ".jumpconnect_watchdog_remotews.alive"
$PostActionWaitSeconds = 8

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Log($msg) {
    $line = "$(Get-Date -Format o) $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

# Same "healthy run logs nothing, except once a day" convention as
# FleetMetricsWatchdog.ps1 - "no issues today" stays visible without waiting
# for a failure, but a 5-min cadence doesn't spam a line every run.
$today = (Get-Date).ToString("yyyy-MM-dd")
$lastAliveDate = if (Test-Path $AliveMarkerFile) { (Get-Content $AliveMarkerFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
if ($lastAliveDate -ne $today) {
    Log "watchdog alive, checking..."
    Set-Content -Path $AliveMarkerFile -Value $today
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

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Log "service '$ServiceName' not found on this box - nothing to watch, exiting"
    exit 1
}

if ($svc.Status -ne 'Running') {
    Log "service is $($svc.Status), starting it"
    try { Start-Service -Name $ServiceName } catch { Log "Start-Service failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds $PostActionWaitSeconds
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc.Status -ne 'Running') {
        Log "SERVICE START FAILED - still $($svc.Status) after Start-Service"
        exit 1
    }
    Log "service started, now Running"
}

$processId = Get-JumpConnectProcessId
if (Test-HasEstablishedConnection $processId) {
    # Healthy - nothing to do beyond the daily alive ping above.
    exit 0
}

Log "service is Running (PID $processId) but has no established outbound connection - likely wedged after a network blip, restarting"
try {
    Restart-Service -Name $ServiceName -Force
} catch {
    Log "Restart-Service failed: $($_.Exception.Message)"
    exit 1
}

Start-Sleep -Seconds $PostActionWaitSeconds
$newProcessId = Get-JumpConnectProcessId
if (Test-HasEstablishedConnection $newProcessId) {
    Log "restart succeeded, PID $newProcessId now has an established outbound connection"
    exit 0
} else {
    Log "RESTART DID NOT RESTORE CONNECTIVITY (or too soon to tell) - PID $newProcessId"
    exit 1
}
