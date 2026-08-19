<#
.SYNOPSIS
  Standalone power-loss + WiFi-flap diagnostic heartbeat for RemoteWS.

.PURPOSE
  Two separate problems this has caught so far:

  1) RemoteWS hard-froze (Kernel-Power Event 41, BugcheckCode=0, no minidump)
     roughly every 2-15 days from 2026-07-17 through 2026-08-13. Believed fixed
     by disabling PCIe ASPM (2026-08-13) - no recurrence as of this writing.
     The uptime_sec/cpu_pct/free_mem_mb/thermal_c columns exist for this: if it
     ever hard-freezes again, the last line written pins time-of-death to
     within ~15s instead of the multi-hour blind spot the Windows System event
     log leaves (it goes completely silent during a freeze).

  2) RemoteWS's onboard WiFi (Realtek 8852BE, 2.4GHz) intermittently flaps -
     amsterdamdesktop's fleet checker sees repeated ping-timeout/recovery
     cycles (see status_transitions.jsonl on that host) while this box's own
     System event log shows no crash and this script's own heartbeat never
     gaps - i.e. the machine stays up, only reachability drops. Confirmed
     2026-08-17/18: 24 WLAN reconnects (Microsoft-Windows-WLAN-AutoConfig
     Event 11010) in ~13 hours, some seconds apart. 5GHz tested worse than
     2.4GHz; driver is already current. Root cause suspected to be the mini
     PC's cramped internal antennas - plan is an external-antenna USB WiFi
     adapter, but that may be months out (no physical access to the box in
     the meantime), and the user expects the flapping to recur. The
     wifi_signal_pct/wifi_rssi_dbm/wifi_reconnects_* columns exist so the next
     occurrence has a local trend line to correlate against the checker's
     transitions log, instead of requiring another manual event-log dig.

     2026-08-18 (later): wifi_state/signal alone are association-layer only -
     the adapter can say "connected" with fine signal while traffic still
     isn't passing (this fits the 8/18 12:52-17:11 outage the checker saw,
     which had no matching WLAN reconnect events - i.e. it stayed
     "associated" throughout while apparently not passing traffic). Added
     actual reachability checks: a ping to the current default gateway (LAN/
     AP-side reachability) and a ping to a fixed public IP (WAN-side), so a
     future outage can be told apart as AP/local-network vs. upstream/ISP.

  This script appends one line every 15s to a local, append-only, per-day log
  file, synchronously flushed on every tick so a hard freeze can't lose a
  buffered-but-unwritten line. It is intentionally independent of the existing
  Fleet Metrics Server / Watchdog tasks (see Status/readme.md) so a problem
  with those doesn't also take this out.

.NOTES
  Deployed via Scheduled Task "Power Heartbeat Logger" (At system startup,
  runs as SYSTEM so it doesn't need an interactive RDP logon to start - see
  the "Fleet Metrics Server" task, which only starts once someone logs in,
  which is why FleetMetricsWatchdog.ps1 has to nudge it after every
  crash-reboot).
  Logs to C:\fleet_monitor\power_heartbeat_remotews\ alongside the existing
  fleet_monitor heartbeat/metrics files for that host.

  Schema note: 2026-08-18 added the wifi_* columns (v2), then later the same
  day added gateway_*/wan_* reachability columns (v3). Older day-files only
  have the earlier column sets - don't concatenate across versions without
  accounting for the header change, hence the versioned
  "power_heartbeat_v{2,3}_*" filename prefixes.
#>

$ErrorActionPreference = 'Continue'

$LogDir = 'C:\fleet_monitor\power_heartbeat_remotews'
$RetentionDays = 30
$IntervalSeconds = 15
$WanPingTarget = '1.1.1.1'   # fixed public IP, not DNS-dependent - WAN-side reachability check

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

function Get-WifiInfo {
    # Parses `netsh wlan show interfaces` rather than a WMI/netadapter cmdlet
    # since that's what was already confirmed working manually on this box's
    # Realtek 8852BE. NA fields if WiFi is disconnected or netsh fails.
    $result = [pscustomobject]@{ State = 'NA'; SignalPct = 'NA'; RssiDbm = 'NA' }
    try {
        $out = netsh wlan show interfaces 2>$null
        if ($out) {
            $m = $out | Select-String -Pattern '^\s*State\s*:\s*(.+?)\s*$'
            if ($m) { $result.State = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*Signal\s*:\s*(\d+)%'
            if ($m) { $result.SignalPct = $m.Matches[0].Groups[1].Value }
            $m = $out | Select-String -Pattern '^\s*Rssi\s*:\s*(-?\d+)'
            if ($m) { $result.RssiDbm = $m.Matches[0].Groups[1].Value }
        }
    } catch {}
    return $result
}

function Get-DefaultGateway {
    # Re-resolved every tick rather than cached, since the gateway/lease has
    # been observed to change (a fresh DHCP lease landed mid-day on 2026-08-18
    # alongside a "New Internet Connection Profile" event) - caching it could
    # silently start pinging a stale address after that kind of reset.
    try {
        $cfg = Get-NetIPConfiguration -InterfaceAlias 'Wi-Fi' -ErrorAction Stop
        return $cfg.IPv4DefaultGateway.NextHop
    } catch { return $null }
}

function Test-PingTarget {
    # -Count 1 keeps each check to a single echo request. On a timeout this
    # can still take a few seconds (legacy Test-Connection's default timeout),
    # which is fine here: it just stretches that tick's interval slightly,
    # and a timeout IS the interesting case we want captured, not skipped.
    param([string]$TargetIp)
    if (-not $TargetIp) { return [pscustomobject]@{ Ok = 'NA'; Ms = 'NA' } }
    try {
        $r = Test-Connection -ComputerName $TargetIp -Count 1 -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Ms = $r.ResponseTime }
    } catch {
        return [pscustomobject]@{ Ok = $false; Ms = 'timeout' }
    }
}

function Get-NewReconnectCount {
    # Counts Microsoft-Windows-WLAN-AutoConfig Event 11010 ("Wireless security
    # started", fired on every reconnect/re-auth) since $sinceLocal. Windows
    # event log timestamps are local time, so this is kept in local time
    # throughout rather than mixed with the UTC timestamp used for the CSV
    # row - StartTime is inclusive, so results are filtered to strictly after
    # $sinceLocal to avoid double-counting the boundary event across ticks.
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
        [System.IO.File]::AppendAllText($path, "timestamp_utc,uptime_sec,cpu_pct,free_mem_mb,thermal_c,wifi_signal_pct,wifi_rssi_dbm,wifi_state,wifi_reconnects_new,wifi_reconnects_total,gateway_ip,gateway_ping_ok,gateway_ping_ms,wan_ping_ok,wan_ping_ms`r`n")
    }
}

# Loop-persistent reconnect-count state. Starts counting from script start
# (i.e. from now, or from last boot/task-restart) - not retroactive to older
# WLAN log history, since the point is a going-forward trend line.
$script:LastReconnectCheck = Get-Date
$script:ReconnectTotal = 0

while ($true) {
    try {
        $now = (Get-Date).ToUniversalTime()
        $nowLocal = Get-Date
        $dayFile = Join-Path $LogDir ("power_heartbeat_v3_{0:yyyy-MM-dd}.csv" -f $now)
        Ensure-Header $dayFile

        $uptimeSec = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
        $cpuPct = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $freeMemMb = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
        $thermal = Get-ThermalCelsius
        $wifi = Get-WifiInfo

        $newReconnects = Get-NewReconnectCount -sinceLocal $script:LastReconnectCheck
        $script:ReconnectTotal += $newReconnects
        $script:LastReconnectCheck = $nowLocal

        $gateway = Get-DefaultGateway
        $gwPing = Test-PingTarget -TargetIp $gateway
        $wanPing = Test-PingTarget -TargetIp $WanPingTarget

        $line = "{0:yyyy-MM-ddTHH:mm:ss.fffZ},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14}" -f `
            $now, $uptimeSec, $cpuPct, $freeMemMb, $thermal, `
            $wifi.SignalPct, $wifi.RssiDbm, $wifi.State, $newReconnects, $script:ReconnectTotal, `
            $(if ($gateway) { $gateway } else { 'NA' }), $gwPing.Ok, $gwPing.Ms, $wanPing.Ok, $wanPing.Ms

        # AppendAllText opens, writes, flushes, and closes the handle on every
        # call - deliberately not keeping a stream open, so a hard freeze
        # can't lose a buffered-but-unwritten line.
        [System.IO.File]::AppendAllText($dayFile, $line + "`r`n")
    } catch {
        # Never let a transient WMI/IO/netsh hiccup kill the loop - that would
        # silently reopen the exact blind spot this exists to close.
        try {
            $errFile = Join-Path $LogDir 'power_heartbeat_errors.log'
            [System.IO.File]::AppendAllText($errFile, "$((Get-Date).ToUniversalTime().ToString('o')) $($_.Exception.Message)`r`n")
        } catch {}
    }

    Start-Sleep -Seconds $IntervalSeconds
}
