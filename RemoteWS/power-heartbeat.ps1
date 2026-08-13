<#
.SYNOPSIS
  Standalone power-loss diagnostic heartbeat for RemoteWS.

.PURPOSE
  RemoteWS has been hard-freezing (Kernel-Power Event 41, BugcheckCode=0, no
  minidump) roughly every 2-15 days since 2026-07-17. The Windows System event
  log goes completely silent when this happens, so after a crash-reboot the
  only evidence is "it died sometime in a multi-hour gap" - not useful for
  correlating against anything (thermal, update timing, load, etc).

  This script appends one line every 15s to a local, append-only, per-day log
  file. Because it's written and flushed synchronously on every tick, the last
  line in the file after an unexpected reboot pins the time of death to within
  ~15 seconds instead of hours. It is intentionally independent of the
  existing Fleet Metrics Server / Watchdog tasks (see Status/readme.md) so a
  problem with those doesn't also take this out.

.NOTES
  Deployed via Scheduled Task "Power Heartbeat Logger" (At system startup, runs
  as SYSTEM so it doesn't need an interactive RDP logon to start - see the
  "Fleet Metrics Server" task, which only starts once someone logs in, which is
  why FleetMetricsWatchdog.ps1 has to nudge it after every crash-reboot).
  Logs to C:\fleet_monitor\power_heartbeat_remotews\ alongside the existing
  fleet_monitor heartbeat/metrics files for that host.
#>

$ErrorActionPreference = 'Continue'

$LogDir = 'C:\fleet_monitor\power_heartbeat_remotews'
$RetentionDays = 30
$IntervalSeconds = 15

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Prune log files older than retention window - runs once per script start
# (i.e. once per boot, since this is an "at startup" task), cheap enough.
Get-ChildItem -Path $LogDir -Filter 'power_heartbeat_*.csv' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$RetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

function Get-ThermalCelsius {
    # Best-effort only - many OEM boards (this GMKtec included, so far) don't
    # expose ACPI thermal zones via this WMI class. NA is an expected result,
    # not a script bug.
    try {
        $zone = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($zone) {
            return [math]::Round((($zone.CurrentTemperature / 10) - 273.15), 1)
        }
    } catch {}
    return 'NA'
}

# Write header once per new day-file
function Ensure-Header($path) {
    if (-not (Test-Path $path)) {
        [System.IO.File]::AppendAllText($path, "timestamp_utc,uptime_sec,cpu_pct,free_mem_mb,thermal_c`r`n")
    }
}

while ($true) {
    try {
        $now = (Get-Date).ToUniversalTime()
        $dayFile = Join-Path $LogDir ("power_heartbeat_{0:yyyy-MM-dd}.csv" -f $now)
        Ensure-Header $dayFile

        $uptimeSec = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
        $cpuPct = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $freeMemMb = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
        $thermal = Get-ThermalCelsius

        $line = "{0:yyyy-MM-ddTHH:mm:ss.fffZ},{1},{2},{3},{4}" -f $now, $uptimeSec, $cpuPct, $freeMemMb, $thermal

        # AppendAllText opens, writes, flushes, and closes the handle on every
        # call - deliberately not keeping a stream open, so a hard freeze
        # can't lose a buffered-but-unwritten line.
        [System.IO.File]::AppendAllText($dayFile, $line + "`r`n")
    } catch {
        # Never let a transient WMI/IO hiccup kill the loop - that would
        # silently reopen the exact multi-hour blind spot this exists to close.
        try {
            $errFile = Join-Path $LogDir 'power_heartbeat_errors.log'
            [System.IO.File]::AppendAllText($errFile, "$((Get-Date).ToUniversalTime().ToString('o')) $($_.Exception.Message)`r`n")
        } catch {}
    }

    Start-Sleep -Seconds $IntervalSeconds
}
