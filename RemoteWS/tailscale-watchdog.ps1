# tailscale-watchdog.ps1
#
# RemoteWS is a remote-access box - Tailscale is the transport underneath
# almost everything else here (SSH, the fleet checker, JumpConnect's own
# reachability, this watchdog's own sibling watchdogs).
#
# Confirmed 2026-08-28: after a period of WAN flakiness, the Tailscale
# service can end up "Running" but internally wedged - `tailscale status`
# keeps reporting "hasn't received a network map from the coordination
# server in 2m9s" with that duration FROZEN across repeated checks minutes
# apart (confirmed by hand: same "2m9s" on checks several minutes apart,
# i.e. not actually counting up / not actively retrying). A full OS reboot
# only fixed it for a few minutes before it relapsed. `tailscale ping` to
# peers timed out in both directions the whole time. Fixed manually with
# `Restart-Service Tailscale -Force`, confirmed by an actual successful
# `tailscale ping` (not just the absence of a warning) on two checks a
# minute apart.
#
# This watchdog automates that: parses `tailscale status --json`'s Health
# array (empty when healthy) rather than scraping the text health-check
# block. A single unhealthy reading is NOT enough to act on - Tailscale
# recovering from a brief real blip on its own is normal and expected;
# restarting on every transient blip would fight that. Instead this
# requires the Health array to stay non-empty across a grace period
# (persisted via a marker file, since each Task Scheduler run is a fresh
# process with no memory of the last one) before concluding it's actually
# wedged, matching what was observed by hand: stuck for MINUTES, not
# seconds.
#
# Run on a recurring Task Scheduler trigger (e.g. every 5 min), as SYSTEM
# (Restart-Service on another session's service needs admin rights - same
# pattern as "Power Heartbeat Logger" / "JumpConnect Watchdog"). Safe to
# run when healthy - does nothing beyond the once-a-day alive ping.
#
# 2026-08-28: logs into the SAME shared watchdog_remotews.log that
# FleetMetricsWatchdog.ps1 (and JumpConnect Watchdog) already write to, not
# a separate file - the fleet dashboard's existing "WATCHDOG" button/badges
# already fetch and parse that exact file via fleet_api.py's
# /api/watchdog/<host> endpoint (see Status/Web/ST/tiles.html), and
# "remotews" is already in its host list. Piggybacking on it means this
# shows up on the dashboard with no server or dashboard changes - just
# prefix every line with "[Tailscale]" so it stays distinguishable from the
# other watchdogs' lines. The dashboard's parser treats any line containing
# "fail" (case-insensitive) as an issue and anything else recent as
# reassuring activity - the prefix doesn't interfere with either check,
# both are substring matches.
#
# ASCII only - PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII.

$ErrorActionPreference = "Stop"

$ServiceName = "Tailscale"
$TailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$GracePeriodMinutes = 3
$PostRestartWaitSeconds = 10
$LogTag = "[Tailscale]"

$LogDir = "C:\fleet_monitor"
$LogFile = Join-Path $LogDir "watchdog_remotews.log"
$AliveMarkerFile = Join-Path $LogDir ".tailscale_watchdog_remotews.alive"
$UnhealthySinceFile = Join-Path $LogDir ".tailscale_watchdog_remotews.unhealthy_since"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Log($msg) {
    $line = "$(Get-Date -Format o) $LogTag $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

# Same "healthy run logs nothing, except once a day" convention as the
# other watchdogs on this box - "no issues today" stays visible without
# waiting for a failure, but a 5-min cadence doesn't spam a line every run.
$today = (Get-Date).ToString("yyyy-MM-dd")
$lastAliveDate = if (Test-Path $AliveMarkerFile) { (Get-Content $AliveMarkerFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
if ($lastAliveDate -ne $today) {
    Log "watchdog alive, checking..."
    Set-Content -Path $AliveMarkerFile -Value $today
}

# Returns $null if healthy, or an array of health warning strings if not
# (including a synthetic one if the CLI call itself fails, e.g. service
# down or hung badly enough that even `status` doesn't respond).
function Get-TailscaleHealthWarnings {
    try {
        $json = & $TailscaleExe status --json 2>$null
        if (-not $json) { return @("tailscale status --json returned no output") }
        $parsed = $json | ConvertFrom-Json
        if ($parsed.Health -and $parsed.Health.Count -gt 0) { return @($parsed.Health) }
        return $null
    } catch {
        return @("tailscale status --json failed: $($_.Exception.Message)")
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
    Start-Sleep -Seconds $PostRestartWaitSeconds
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc.Status -ne 'Running') {
        Log "SERVICE START FAILED - still $($svc.Status) after Start-Service"
        exit 1
    }
    Log "service started, now Running - will re-check health next run"
    # Give it a full cycle before judging health, rather than immediately
    # flagging it unhealthy right after a cold start.
    exit 0
}

$warnings = Get-TailscaleHealthWarnings

if (-not $warnings) {
    # Healthy. If it had been flagged unhealthy before, this is a genuine
    # self-recovery - worth a log line so the trend is visible, then clear
    # the marker so a future problem starts its own fresh grace period.
    if (Test-Path $UnhealthySinceFile) {
        $since = Get-Content $UnhealthySinceFile -Raw -ErrorAction SilentlyContinue
        Log "healthy again (was unhealthy since $since) - recovered on its own, no restart needed"
        Remove-Item $UnhealthySinceFile -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# Unhealthy. First time seeing it this episode -> just note it and start
# the grace period; a brief real blip recovering on its own is normal and
# common, and restarting on every transient warning would fight that.
if (-not (Test-Path $UnhealthySinceFile)) {
    $nowIso = (Get-Date).ToString('o')
    Set-Content -Path $UnhealthySinceFile -Value $nowIso
    Log "unhealthy detected, starting grace period ($GracePeriodMinutes min): $($warnings -join ' | ')"
    exit 0
}

$since = [datetime]::Parse((Get-Content $UnhealthySinceFile -Raw))
$unhealthyMinutes = (New-TimeSpan -Start $since -End (Get-Date)).TotalMinutes

if ($unhealthyMinutes -lt $GracePeriodMinutes) {
    # Still within grace period - stay quiet, let it keep trying on its own.
    exit 0
}

Log "still unhealthy after ${unhealthyMinutes} min (>= $GracePeriodMinutes min grace period): $($warnings -join ' | ') - restarting service"
try {
    Restart-Service -Name $ServiceName -Force
} catch {
    Log "Restart-Service failed: $($_.Exception.Message)"
    exit 1
}

Start-Sleep -Seconds $PostRestartWaitSeconds
$newWarnings = Get-TailscaleHealthWarnings
if (-not $newWarnings) {
    Log "restart succeeded, healthy again"
} else {
    Log "restart completed but still reporting unhealthy (may need another cycle to settle): $($newWarnings -join ' | ')"
}
# Reset either way - if it's still unhealthy, the next run starts a fresh
# grace period rather than restart-looping every 5 minutes.
Remove-Item $UnhealthySinceFile -Force -ErrorAction SilentlyContinue
exit 0
