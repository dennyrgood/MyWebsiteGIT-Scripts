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
# apart (i.e. not actually counting up / not actively retrying). Fixed
# manually with `Restart-Service Tailscale -Force`, confirmed by an actual
# successful `tailscale ping` (not just the absence of a warning).
#
# 2026-08-29 (v1 of this watchdog, same day it was deployed): the automated
# restart fired correctly on schedule, but landed Tailscale in a WORSE state
# - BackendState "NoState", "You are logged out. The last login error was:
# fetch control key: ... context canceled/deadline exceeded", unable to
# reach the control plane at all. It took several more minutes (WAN
# genuinely recovering, plus a manual `tailscale up` attempt) before it
# came back on its own. Root cause: the watchdog restarted the service
# without checking whether the control plane was actually reachable at that
# moment - if it wasn't, forcing a re-auth handshake right then just traded
# "wedged but still logged in" for "logged out and can't log back in
# either." This version hardens against exactly that:
#
#   1. Before restarting for the "wedged" case (Running + non-empty Health),
#      first checks TCP reachability to controlplane.tailscale.com:443.
#      If unreachable, defers the restart and just keeps waiting - restarting
#      into a known-unreachable control plane is what caused the regression.
#   2. Separately detects and handles the "logged out" case (BackendState
#      != "Running") - Restart-Service isn't the right tool here, since the
#      Windows service itself is up; what's broken is Tailscale's internal
#      IPN/auth state. Once the control plane is reachable, this runs
#      `tailscale up` (bounded to a timeout via Start-Process/WaitForExit,
#      since `tailscale up` was observed to hang past 120s when the control
#      plane connection was still unstable - an unbounded call here would
#      block this watchdog's entire loop, silently reopening the exact
#      "isn't actually checking anymore" failure mode the 2026-08-29
#      Task-Scheduler-trigger rewrite (see below) already fixed once).
#
# A single unhealthy reading (either kind) is NOT enough to act on - real
# transient blips recovering on their own are normal, and acting on every
# one would fight that AND (per the incident above) risks making things
# worse. Each failure mode gets its own grace period before any action.
#
# 2026-08-29 (same day, earlier): rewritten from a one-shot script fired by
# a Task Scheduler "Daily, repeat every 5 min, for a duration of
# Indefinitely" trigger to a single long-running process with its own
# internal loop, triggered "At system startup" - Power Heartbeat Logger's
# pattern. The repeating-trigger version was actually configured as a plain
# "At startup" trigger (matching Power Heartbeat Logger) with no
# repetition at all, and the script was one-shot - so it correctly ran once
# per boot/manual-trigger and then had nothing telling it to run again. Not
# a Task Scheduler bug, just a trigger/script mismatch: "At startup" needs
# a script that loops forever on its own. The grace-period timers are plain
# in-memory variables now (not marker files) since the process is
# continuous - they reset on a script/service restart, same tradeoff
# power-heartbeat.ps1's reconnect counters accept.
#
# Deployed via Scheduled Task "Tailscale Watchdog" (At system startup, runs
# as SYSTEM - Restart-Service on another session's service needs admin
# rights, and SYSTEM doesn't need an interactive RDP logon to start).
#
# Logs into the SAME shared watchdog_remotews.log that FleetMetricsWatchdog.
# ps1 (and JumpConnect Watchdog) already write to, not a separate file - the
# fleet dashboard's existing "WATCHDOG" button/badges already fetch and
# parse that exact file via fleet_api.py's /api/watchdog/<host> endpoint
# (see Status/Web/ST/tiles.html), and "remotews" is already in its host
# list. Piggybacking on it means this shows up on the dashboard with no
# server or dashboard changes - just prefix every line with "[Tailscale]"
# so it stays distinguishable from the other watchdogs' lines. The
# dashboard's parser treats any line containing "fail" (case-insensitive)
# as an issue and anything else recent as reassuring activity - the prefix
# doesn't interfere with either check, both are substring matches.
#
# ASCII only - PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII.

$ErrorActionPreference = "Continue"

$ServiceName = "Tailscale"
$TailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$LogTag = "[Tailscale]"
$IntervalSeconds = 300   # 5 min, matching the original Task Scheduler repeat cadence

$GracePeriodMinutesWedged = 3     # Running but Health non-empty (stale network map etc.)
$GracePeriodMinutesLoggedOut = 2  # BackendState != Running (logged out / needs re-auth)
$PostRestartWaitSeconds = 10
$TailscaleUpTimeoutSeconds = 30
$ControlPlaneHost = "controlplane.tailscale.com"
$ControlPlanePort = 443
$ControlPlaneCheckTimeoutMs = 5000

$LogDir = "C:\fleet_monitor"
$LogFile = Join-Path $LogDir "watchdog_remotews.log"
$AliveMarkerFile = Join-Path $LogDir ".tailscale_watchdog_remotews.alive"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Log($msg) {
    $line = "$(Get-Date -Format o) $LogTag $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

# Returns an object with BackendState (string) and Health (array, empty when
# fully healthy) from `tailscale status --json`. Distinguishing the two
# matters: "Running" + non-empty Health is the "wedged" case a service
# restart fixes; any other BackendState ("NoState", "NeedsLogin", etc.) is
# the "logged out" case a restart does NOT fix (see incident notes above).
function Get-TailscaleStatusInfo {
    try {
        $json = & $TailscaleExe status --json 2>$null
        if (-not $json) {
            return [pscustomobject]@{ BackendState = "Unknown"; Health = @("tailscale status --json returned no output") }
        }
        $parsed = $json | ConvertFrom-Json
        $health = if ($parsed.Health -and $parsed.Health.Count -gt 0) { @($parsed.Health) } else { @() }
        return [pscustomobject]@{ BackendState = $parsed.BackendState; Health = $health }
    } catch {
        return [pscustomobject]@{ BackendState = "Unknown"; Health = @("tailscale status --json failed: $($_.Exception.Message)") }
    }
}

# Plain TCP connect test, not Test-Connection/Test-NetConnection - those can
# be slow (ICMP-based defaults, ping-then-port sequencing) and this needs to
# be quick and specifically about "can we even reach the control plane",
# not general host reachability.
function Test-ControlPlaneReachable {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connectTask = $client.ConnectAsync($ControlPlaneHost, $ControlPlanePort)
        $completed = $connectTask.Wait($ControlPlaneCheckTimeoutMs)
        $ok = $completed -and $client.Connected
        $client.Close()
        return [bool]$ok
    } catch {
        return $false
    }
}

# Runs `tailscale up` with a hard timeout via Start-Process/WaitForExit
# rather than the `&` call operator, which blocks indefinitely - observed
# 2026-08-29 taking over 120s when the control plane connection was still
# settling. Returns $null on success (exit 0), or an error description.
function Invoke-TailscaleUpBounded {
    param([int]$TimeoutSeconds)
    $outFile = Join-Path $env:TEMP "tailscale_up_stdout.txt"
    $errFile = Join-Path $env:TEMP "tailscale_up_stderr.txt"
    try {
        $proc = Start-Process -FilePath $TailscaleExe -ArgumentList "up" -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { $proc.Kill() } catch {}
            return "timed out after ${TimeoutSeconds}s waiting for 'tailscale up'"
        }
        if ($proc.ExitCode -ne 0) {
            $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            return "'tailscale up' exited $($proc.ExitCode): $errText"
        }
        return $null
    } catch {
        return "failed to launch 'tailscale up': $($_.Exception.Message)"
    }
}

# In-memory grace-period state per failure mode - persists across loop
# iterations within this one continuous process, resets on a process/service
# restart (see rewrite note above).
$script:UnhealthySince = $null   # "wedged" case (Running + Health non-empty)
$script:LoggedOutSince = $null   # "logged out" case (BackendState != Running)

function Invoke-HealthCheck {
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
        Start-Sleep -Seconds $PostRestartWaitSeconds
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc.Status -ne 'Running') {
            Log "SERVICE START FAILED - still $($svc.Status) after Start-Service"
            return
        }
        Log "service started, now Running - will re-check health next cycle"
        $script:UnhealthySince = $null
        $script:LoggedOutSince = $null
        return
    }

    $info = Get-TailscaleStatusInfo

    # Fully healthy.
    if ($info.BackendState -eq 'Running' -and $info.Health.Count -eq 0) {
        if ($script:UnhealthySince) {
            Log "healthy again (was 'wedged' since $($script:UnhealthySince.ToString('o'))) - recovered, no restart needed"
            $script:UnhealthySince = $null
        }
        if ($script:LoggedOutSince) {
            Log "healthy again (was logged-out since $($script:LoggedOutSince.ToString('o'))) - recovered, no action needed"
            $script:LoggedOutSince = $null
        }
        return
    }

    # Logged-out / backend-down case: a service restart does not fix this
    # (confirmed 2026-08-29 - it's what CAUSED it once already). Needs
    # `tailscale up`, and only once the control plane is actually reachable.
    if ($info.BackendState -ne 'Running') {
        $script:UnhealthySince = $null  # different failure mode, not the "wedged" one

        if (-not $script:LoggedOutSince) {
            $script:LoggedOutSince = Get-Date
            Log "backend state is '$($info.BackendState)' (logged out / needs re-auth), starting grace period ($GracePeriodMinutesLoggedOut min): $($info.Health -join ' | ')"
            return
        }

        $mins = (New-TimeSpan -Start $script:LoggedOutSince -End (Get-Date)).TotalMinutes
        if ($mins -lt $GracePeriodMinutesLoggedOut) { return }

        if (-not (Test-ControlPlaneReachable)) {
            Log "still logged out after ${mins} min, but control plane ($ControlPlaneHost`:$ControlPlanePort) unreachable right now - deferring 'tailscale up', will retry next cycle"
            return
        }

        Log "still logged out after ${mins} min, control plane reachable - attempting 'tailscale up'"
        $upError = Invoke-TailscaleUpBounded -TimeoutSeconds $TailscaleUpTimeoutSeconds
        Start-Sleep -Seconds 5
        $recheck = Get-TailscaleStatusInfo
        if ($recheck.BackendState -eq 'Running' -and $recheck.Health.Count -eq 0) {
            Log "'tailscale up' succeeded, fully healthy again"
        } elseif ($upError) {
            Log "'tailscale up' FAILED ($upError) - state is now '$($recheck.BackendState)': $($recheck.Health -join ' | ')"
        } else {
            Log "'tailscale up' completed but not fully healthy yet (state='$($recheck.BackendState)'): $($recheck.Health -join ' | ') - may need another cycle"
        }
        $script:LoggedOutSince = $null  # fresh grace period next cycle if still broken
        return
    }

    # Wedged case: Running, but Health reports a problem (e.g. stale network
    # map). Restart-Service is the right tool here - but only once the
    # control plane is reachable, per the 2026-08-29 incident.
    $script:LoggedOutSince = $null  # different failure mode, not the "logged out" one

    if (-not $script:UnhealthySince) {
        $script:UnhealthySince = Get-Date
        Log "unhealthy detected (Running, but Health non-empty), starting grace period ($GracePeriodMinutesWedged min): $($info.Health -join ' | ')"
        return
    }

    $mins = (New-TimeSpan -Start $script:UnhealthySince -End (Get-Date)).TotalMinutes
    if ($mins -lt $GracePeriodMinutesWedged) { return }

    if (-not (Test-ControlPlaneReachable)) {
        Log "still unhealthy after ${mins} min, but control plane ($ControlPlaneHost`:$ControlPlanePort) unreachable right now - deferring restart (restarting into an unreachable control plane caused a worse logged-out state on 2026-08-29), will retry next cycle"
        return
    }

    Log "still unhealthy after ${mins} min, control plane reachable - restarting service"
    try {
        Restart-Service -Name $ServiceName -Force
    } catch {
        Log "Restart-Service failed: $($_.Exception.Message)"
        return
    }

    Start-Sleep -Seconds $PostRestartWaitSeconds
    $recheck = Get-TailscaleStatusInfo
    if ($recheck.BackendState -eq 'Running' -and $recheck.Health.Count -eq 0) {
        Log "restart succeeded, healthy again"
    } else {
        Log "restart completed but not fully healthy yet (state='$($recheck.BackendState)'): $($recheck.Health -join ' | ') - may need another cycle"
    }
    $script:UnhealthySince = $null
}

while ($true) {
    try {
        Invoke-HealthCheck
    } catch {
        # Never let a transient WMI/CIM/IO hiccup kill the loop - that would
        # silently turn this back into the exact "stopped and nobody
        # noticed" failure mode the Task Scheduler rewrite exists to fix.
        try { Log "unexpected error in health check: $($_.Exception.Message)" } catch {}
    }
    Start-Sleep -Seconds $IntervalSeconds
}
