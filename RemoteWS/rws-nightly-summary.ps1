# RemoteWS\rws-nightly-summary.ps1
# 2026-08-31 UTC -- created, modeled on TravelBeast/tb-nightly-summary.ps1. Runs once
# nightly via Task Scheduler. Sends one email with a TLDR block + supporting detail.
#
# rws has no Fleet Checker task -- not a Fleet Status Checker instance (those are
# amsdt + cwh only), so no server_status_all.json section here, same as tb/ib.
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).
# Check/warning marks built from character codes so the SOURCE stays ASCII while still
# emitting real glyphs at runtime.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Send-FleetMail.ps1"

$Check = [char]::ConvertFromUtf32(0x2705)
$Warn  = [char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F

$HostName = "remotews"
$MonitorStateFile = Join-Path $env:TEMP "$HostName-monitor-state.tmp"
$FleetMonitorDir = "C:\fleet_monitor"
$WatchdogLog = Join-Path $FleetMonitorDir "watchdog_$HostName.log"
$JcWatchdogLog = Join-Path $FleetMonitorDir "jumpconnect_watchdog_$HostName.log"
$TsWatchdogLog = Join-Path $FleetMonitorDir "tailscale_watchdog_$HostName.log"
$PowerHbDir = Join-Path $FleetMonitorDir "power_heartbeat_remotews"

function Format-Age($ts) {
    $secs = (New-TimeSpan -Start $ts -End (Get-Date)).TotalSeconds
    if ($secs -lt 3600) { return "$([int]($secs / 60))m" }
    elseif ($secs -lt 172800) { return "$([int]($secs / 3600))h" }
    else { return "$([int]($secs / 86400))d" }
}

$Reason = "all healthy"
$Tldr = "============================= TLDR ===============================`r`n"
$Body = ""

# --- Core services: JumpConnect (this box's whole purpose), Syncthing, Plex ---
try {
    $jc = Get-Service -Name "JumpConnect" -ErrorAction Stop
    if ($jc.Status -eq "Running") {
        $Tldr += "  JumpConnect: Running $Check`r`n"
    } else {
        $Tldr += "$Warn  JumpConnect: $($jc.Status) (should be Running)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "JumpConnect not running" }
    }
} catch {
    $Tldr += "$Warn  JumpConnect: service not found`r`n"
    if ($Reason -eq "all healthy") { $Reason = "JumpConnect service missing" }
}
$sync = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "syncthing\.exe.*--no-browser" }
if ($sync) { $Tldr += "  Syncthing: running $Check`r`n" } else {
    $Tldr += "$Warn  Syncthing: not running`r`n"
    if ($Reason -eq "all healthy") { $Reason = "Syncthing not running" }
}
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:32400/identity" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    $Tldr += "  Plex: responding $Check`r`n"
} catch {
    $Tldr += "$Warn  Plex: not responding on :32400`r`n"
    if ($Reason -eq "all healthy") { $Reason = "Plex not responding" }
}

# --- Watchdog logs (FleetMetrics, JumpConnect, Tailscale) ---
# JumpConnect Watchdog and Tailscale Watchdog each have their OWN per-component log
# file, but confirmed 2026-08-31 those can sit 3+ days stale even while genuinely
# healthy -- both watchdogs ALSO write tagged "[JumpConnect]"/"[Tailscale]" lines into
# the SHARED watchdog_remotews.log (the same file FleetMetricsWatchdog's untagged
# lines go into), and that shared log updates daily and is the more reliable signal
# (same file rws-health-monitor.ps1 would ideally use too, but it uses the .alive
# marker files instead, which is equally valid and doesn't need this tag-parsing).
if (Test-Path $WatchdogLog) {
    $age = Format-Age (Get-Item $WatchdogLog).LastWriteTime
    $Tldr += "  watchdog log: [$age ago] $(Get-Content $WatchdogLog -Tail 1)`r`n"
    $Body += "=== watchdog log (last 10 lines) ===`r`n"
    $Body += (Get-Content $WatchdogLog -Tail 10 | Out-String)
    $Body += "`r`n"

    $lastJc = Get-Content $WatchdogLog | Where-Object { $_ -match "^\S+ \[JumpConnect\]" } | Select-Object -Last 1
    if ($lastJc -and $lastJc -match '^(\S+)') {
        $jcAge = Format-Age ([datetime]$Matches[1])
        $Tldr += "  jumpconnect watchdog: [$jcAge ago, via shared log] $lastJc`r`n"
    } else {
        $Tldr += "$Warn  jumpconnect watchdog: no tagged line found in shared watchdog log`r`n"
        if ($Reason -eq "all healthy") { $Reason = "jumpconnect watchdog silent" }
    }
    $lastTs = Get-Content $WatchdogLog | Where-Object { $_ -match "^\S+ \[Tailscale\]" } | Select-Object -Last 1
    if ($lastTs -and $lastTs -match '^(\S+)') {
        $tsAge = Format-Age ([datetime]$Matches[1])
        $Tldr += "  tailscale watchdog: [$tsAge ago, via shared log] $lastTs`r`n"
    } else {
        $Tldr += "$Warn  tailscale watchdog: no tagged line found in shared watchdog log`r`n"
        if ($Reason -eq "all healthy") { $Reason = "tailscale watchdog silent" }
    }
} else {
    $Tldr += "$Warn  watchdog log: not found at $WatchdogLog`r`n"
    if ($Reason -eq "all healthy") { $Reason = "watchdog log missing" }
}
# Per-component log files still dumped in the body for reference (restart/incident
# detail lives there, e.g. the wedged-connection restart sequence), just not used to
# judge staleness in the TLDR.
foreach ($pair in @(
    @{ Label = "jumpconnect watchdog log (own file)"; Path = $JcWatchdogLog },
    @{ Label = "tailscale watchdog log (own file)";   Path = $TsWatchdogLog }
)) {
    if (Test-Path $pair.Path) {
        $Body += "=== $($pair.Label), last 10 lines ===`r`n"
        $Body += (Get-Content $pair.Path -Tail 10 | Out-String)
        $Body += "`r`n"
    }
}

# --- power-heartbeat: most recent CSV, row count ---
$latestCsv = Get-ChildItem $PowerHbDir -Filter "power_heartbeat_v4_*.csv" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestCsv) {
    $age = Format-Age $latestCsv.LastWriteTime
    $rows = (Import-Csv $latestCsv.FullName | Measure-Object).Count
    $Tldr += "  power-heartbeat: [$age ago] $($latestCsv.Name), $rows sample(s) $Check`r`n"
} else {
    $Tldr += "$Warn  power-heartbeat: no CSV found in $PowerHbDir`r`n"
    if ($Reason -eq "all healthy") { $Reason = "power-heartbeat log missing" }
}

# --- Health monitor state ---
if (Test-Path $MonitorStateFile) {
    $stateAge = (New-TimeSpan -Start (Get-Item $MonitorStateFile).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($stateAge -gt 12) {
        # 12, not 10 -- the health-monitor runs every 5 min, so a nightly-summary run
        # that happens to land 10-11 min after the last tick is a normal timing
        # coincidence, not staleness (confirmed 2026-08-31: a real false-positive at
        # 11m). 12 gives slack without hiding a genuinely stalled monitor (which would
        # show 15m, 20m, etc., not just barely over a 2x-interval boundary).
        $Tldr += "$Warn  rws-health-monitor: stale (last-run $([int]$stateAge)m ago; threshold 12m)`r`n"
        if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
    } else {
        $Tldr += "  rws-health-monitor: last-run $([int]$stateAge)m ago $Check`r`n"
    }
    $stateLines = Get-Content $MonitorStateFile
    $active = $stateLines | Where-Object { $_ -match "_ACTIVE=1$" }
    if ($active) {
        $Tldr += "$Warn  rws-health-monitor: ACTIVE ALERTS`r`n"
        if ($Reason -eq "all healthy") { $Reason = "active health alerts" }
    } else {
        $Tldr += "  rws-health-monitor: no active alerts $Check`r`n"
    }
    $Body += "=== HEALTH MONITOR STATE ===`r`n"
    if ($active) { $Body += "ACTIVE ALERTS:`r`n$($active -join "`r`n")`r`n`r`n" } else { $Body += "No active alerts.`r`n`r`n" }
    $Body += ($stateLines | Out-String)
    $Body += "`r`n"
} else {
    $Tldr += "$Warn  rws-health-monitor: state file not found -- has not run`r`n"
    if ($Reason -eq "all healthy") { $Reason = "health monitor stale/missing" }
}

$Tldr += "===================================================================`r`n`r`n"
$Body = $Tldr + $Body

if ($Reason -eq "all healthy") { $Emoji = "$Check" } else { $Emoji = "$Warn" }
$Subject = "$Emoji RemoteWS nightly $(Get-Date -Format 'yyyy-MM-dd') -- $Reason"

Send-FleetMail -Subject $Subject -Body $Body | Out-Null
Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') nightly summary sent -- $Reason"
