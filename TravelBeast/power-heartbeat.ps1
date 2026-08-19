<#
.SYNOPSIS
  Standalone WiFi-flap diagnostic heartbeat for TravelBeast.

.PURPOSE
  TravelBeast's onboard WiFi (Realtek RTL8852BE, 5GHz, oLiFaNt_5G) has been
  intermittently flaky since at least 2026-07-27: amsterdamdesktop's and
  chatworkhorse's fleet checkers see repeated ping-timeout/high-latency
  cycles while this box's own uptime is unaffected - i.e. reachability
  drops, the machine itself doesn't.

  Manual investigation on 2026-07-27/28 (see chat history) found:
    - Signal/RSSI/BSSID/channel rock-stable throughout (87-89%, -56dBm,
      BSSID 28:ee:52:...:07:86, channel 48) even during multi-second
      latency spikes - so it isn't a weak-signal or roaming/AP-hopping
      problem in the usual sense.
    - Standard NDIS device power management ("allow the computer to turn
      off this device") is Unsupported on this driver - ruled out.
    - Leisure Power Save (Realtek chip-level radio doze) set Auto->Low:
      no measurable improvement.
    - Multi-Channel Concurrent set Enabled->Disabled: no measurable
      improvement.
    - Switching 5GHz->2.4GHz: no difference (rules out band/channel
      congestion).
    - Other devices (Mac/Win11) on the same AP at the same time: clean -
      rules out the router/environment, confirms TravelBeast-specific.
    - Uninstalling/reinstalling the Wi-Fi device in Device Manager (which
      resets per-instance driver parameters to default) produced a large,
      sustained improvement: pre-reinstall pings routinely hit 400ms-3.9s
      with ~25% loss; post-reinstall settled to a steady 1-10ms baseline
      with only isolated single-packet timeouts remaining, initially on a
      suspiciously tight ~40-45s cadence (suggestive of periodic
      background roam-scanning).
    - Roaming Sensitivity Level set Middle->Low: the ~40-45s periodic
      timeout cadence broke up into irregular, infrequent single losses
      (multi-minute clean stretches became common) - no more severe
      multi-second spikes observed since.
    - WLAN-AutoConfig/Dhcp-Client/Ndis System-log events were empty
      throughout every bad stretch captured - the OS never logged a real
      disconnect or DHCP renewal, meaning the flakiness happens below the
      level Windows' own connectivity logging notices. Event 11010
      ("Wireless security started", fired on every WLAN reconnect/re-auth)
      from the WLAN-AutoConfig/Operational log is a finer-grained signal
      than System log and is what this script tracks going forward, per
      the same approach used on RemoteWS (see
      ..\RemoteWS\power-heartbeat.ps1) for its own unrelated WiFi-flap
      investigation.

  As of this writing the working theory is stale/corrupted per-device
  driver state (fixed by the reinstall) plus overly-aggressive roam
  scanning (mitigated by Roaming Sensitivity=Low), but the isolated
  single-packet losses haven't been fully eliminated and the fix hasn't
  been observed across a full multi-day cycle yet. This script exists so
  the next occurrence has a local trend line (signal/RSSI/reconnect
  events) to correlate against the fleet checker's own outage log,
  instead of requiring another manual multi-hour diagnostic session.

  2026-08-19 blind spot found and closed (v2 schema): oLiFaNt_5G died
  sometime that afternoon while this log showed nothing wrong at all -
  uninterrupted "connected" state, stable BSSID/signal/RSSI, zero
  reconnect events, right up until the user's own manual
  disconnect/reconnect attempts started showing up in the WLAN-AutoConfig
  event log. The v1 schema only records what Windows *reports* about the
  link (signal/state/reconnect-count), which looks identical whether the
  link is healthy or "connected but not actually passing traffic" - the
  same silent-death signature as the original problem this script was
  built to catch. v2 adds an actual reachability probe (ping to the
  current default gateway, re-detected every tick since this is a travel
  laptop and the gateway changes across networks) so a repeat of this
  exact failure mode leaves a real trace instead of a healthy-looking
  gap.

  This script appends one line every 15s to a local, append-only, per-day
  log file, synchronously flushed on every tick so a crash/reboot can't
  lose a buffered-but-unwritten line. It is intentionally independent of
  the existing Fleet Metrics Server / Watchdog tasks (see
  Status/readme.md) so a problem with those doesn't also take this out.

.NOTES
  Deploy via Scheduled Task "Power Heartbeat Logger" (At system startup,
  runs as SYSTEM so it doesn't need an interactive logon to start - see
  the "Fleet Metrics Server" task, which only starts once someone logs
  in).
  Logs to C:\fleet_monitor\power_heartbeat_travelbeast\ alongside the
  existing fleet_monitor heartbeat/metrics files for this host.

  Schema note: 2026-08-19 added the gw_ping_ms/gw_ping_status columns
  (v2). The v1 day-file from before that date only has the original 12
  columns - don't concatenate it with v2 files without accounting for the
  header change, hence the separate "power_heartbeat_v2_*" filename
  prefix going forward (same convention as RemoteWS's copy of this
  script). Editing this file does NOT affect an already-running instance
  - PowerShell loads the whole script into memory at start, so the
  running "Power Heartbeat Logger" task must be stopped and restarted
  (Task Scheduler -> right-click -> End, then Run) to pick up changes.
#>

$ErrorActionPreference = 'Continue'

$LogDir = 'C:\fleet_monitor\power_heartbeat_travelbeast'
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
    # Best-effort only - many boards don't expose ACPI thermal zones via
    # this WMI class. NA is an expected result, not a script bug.
    try {
        $zone = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($zone) {
            return [math]::Round((($zone.CurrentTemperature / 10) - 273.15), 1)
        }
    } catch {}
    return 'NA'
}

function Get-WifiInfo {
    # Parses `netsh wlan show interfaces` - confirmed working manually on
    # this box's Realtek RTL8852BE. NA fields if WiFi is disconnected or
    # netsh fails (e.g. Location Services off blocks BSSID/channel but not
    # State/Signal/Rssi in practice - captured best-effort either way).
    $result = [pscustomobject]@{ State = 'NA'; SignalPct = 'NA'; RssiDbm = 'NA'; Bssid = 'NA'; Channel = 'NA' }
    try {
        $out = netsh wlan show interfaces 2>$null
        if ($out) {
            $m = $out | Select-String -Pattern '^\s*State\s*:\s*(.+?)\s*$'
            if ($m) { $result.State = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*Signal\s*:\s*(\d+)%'
            if ($m) { $result.SignalPct = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*Rssi\s*:\s*(-?\d+)'
            if ($m) { $result.RssiDbm = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*AP BSSID\s*:\s*(.+?)\s*$'
            if ($m) { $result.Bssid = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*Channel\s*:\s*(\d+)'
            if ($m) { $result.Channel = $m.Matches[0].Groups[1].Value }
        }
    } catch {}
    return $result
}

function Get-GatewayPing {
    # Re-detects the default gateway every call rather than hardcoding one,
    # since this is a travel laptop and the gateway changes across
    # networks (home oLiFaNt, hotel WiFi, phone hotspot, etc.). This is
    # the actual reachability probe v1 was missing - see the 2026-08-19
    # note above for why it exists.
    $result = [pscustomobject]@{ Ms = ''; Status = 'NA' }
    try {
        $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1 -ExpandProperty NextHop
        if ($gw) {
            $p = Test-Connection -ComputerName $gw -Count 1 -ErrorAction SilentlyContinue
            if ($p) {
                $result.Ms = $p.ResponseTime
                $result.Status = 'OK'
            } else {
                $result.Status = 'TIMEOUT'
            }
        }
    } catch {}
    return $result
}

function Get-NewReconnectCount {
    # Counts Microsoft-Windows-WLAN-AutoConfig Event 11010 ("Wireless
    # security started", fired on every reconnect/re-auth) since
    # $sinceLocal. Windows event log timestamps are local time, so this is
    # kept in local time throughout rather than mixed with the UTC
    # timestamp used for the CSV row - StartTime is inclusive, so results
    # are filtered to strictly after $sinceLocal to avoid double-counting
    # the boundary event across ticks.
    param([datetime]$sinceLocal)
    try {
        $evts = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; Id=11010; StartTime=$sinceLocal} -ErrorAction SilentlyContinue
        if ($evts) {
            return @($evts | Where-Object { $_.TimeCreated -gt $sinceLocal }).Count
        }
    } catch {}
    return 0
}

# Write header once per new day-file
function Ensure-Header($path) {
    if (-not (Test-Path $path)) {
        [System.IO.File]::AppendAllText($path, "timestamp_utc,uptime_sec,cpu_pct,free_mem_mb,thermal_c,wifi_signal_pct,wifi_rssi_dbm,wifi_state,wifi_bssid,wifi_channel,wifi_reconnects_new,wifi_reconnects_total,gw_ping_ms,gw_ping_status`r`n")
    }
}

# Loop-persistent reconnect-count state. Starts counting from script start
# (i.e. from now, or from last boot/task-restart) - not retroactive to
# older WLAN log history, since the point is a going-forward trend line.
$script:LastReconnectCheck = Get-Date
$script:ReconnectTotal = 0

while ($true) {
    try {
        $now = (Get-Date).ToUniversalTime()
        $nowLocal = Get-Date
        $dayFile = Join-Path $LogDir ("power_heartbeat_v2_travelbeast_{0:yyyy-MM-dd}.csv" -f $now)
        Ensure-Header $dayFile

        $uptimeSec = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
        $cpuPct = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $freeMemMb = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
        $thermal = Get-ThermalCelsius
        $wifi = Get-WifiInfo
        $gwPing = Get-GatewayPing

        $newReconnects = Get-NewReconnectCount -sinceLocal $script:LastReconnectCheck
        $script:ReconnectTotal += $newReconnects
        $script:LastReconnectCheck = $nowLocal

        $line = "{0:yyyy-MM-ddTHH:mm:ss.fffZ},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13}" -f `
            $now, $uptimeSec, $cpuPct, $freeMemMb, $thermal, `
            $wifi.SignalPct, $wifi.RssiDbm, $wifi.State, $wifi.Bssid, $wifi.Channel, $newReconnects, $script:ReconnectTotal, `
            $gwPing.Ms, $gwPing.Status

        # AppendAllText opens, writes, flushes, and closes the handle on
        # every call - deliberately not keeping a stream open, so a crash
        # can't lose a buffered-but-unwritten line.
        [System.IO.File]::AppendAllText($dayFile, $line + "`r`n")
    } catch {
        # Never let a transient WMI/IO/netsh hiccup kill the loop - that
        # would silently reopen the exact blind spot this exists to close.
        try {
            $errFile = Join-Path $LogDir 'power_heartbeat_errors.log'
            [System.IO.File]::AppendAllText($errFile, "$((Get-Date).ToUniversalTime().ToString('o')) $($_.Exception.Message)`r`n")
        } catch {}
    }

    Start-Sleep -Seconds $IntervalSeconds
}
