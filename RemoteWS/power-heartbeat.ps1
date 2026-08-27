<#
.SYNOPSIS
  Standalone power-loss + WiFi-flap diagnostic heartbeat for RemoteWS.

.PURPOSE
  Three separate problems this has caught/tracked so far:

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
     2026-08-17/18: 24 WLAN reconnects in ~13 hours, some seconds apart.
     Confirmed again 2026-08-20/22 in a different shape: association solid
     (no reconnects) but gateway+WAN pings failing together, jittery latency -
     added the gateway_*/wan_* reachability columns for that (see below).
     wifi_state/signal alone are association-layer only and can say
     "connected" while traffic still isn't passing.

  3) 2026-08-27: installed a Panda AXE3000 (MediaTek) USB WiFi adapter
     alongside the onboard Realtek as a hardware fix attempt, set as the
     preferred route (interface metric 10 vs onboard's 50, both
     AutomaticMetric Disabled so it doesn't drift). Both stay connected
     simultaneously (onboard as fallback, not disabled). This made the
     single-adapter wifi_*/gateway_* columns from the v2/v3 schema actively
     wrong: gateway/WAN pings were hardcoded to check via the "Wi-Fi" alias,
     which is no longer necessarily the adapter Windows is actually routing
     through. v4 fixes this by resolving the ACTIVE default-route interface
     fresh every tick (not hardcoded) for the gateway/WAN checks, tracks
     onboard and USB adapter state/signal/reconnects separately instead of
     blending whichever netsh listed first, and adds an active_adapter
     column + a switch counter so a future flap between the two adapters
     (not just within one) is directly visible instead of inferred.

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

  Schema note: v2 added wifi_* columns, v3 added gateway_*/wan_* reachability,
  v4 (2026-08-27) split wifi_* into onboard_/usb_ per-adapter columns, fixed
  the gateway/WAN check to follow the actual active route instead of a
  hardcoded interface alias, and added active_adapter/adapter_switches_*.
  Older day-files only have earlier column sets - don't concatenate across
  versions without accounting for the header change, hence the versioned
  "power_heartbeat_v{2,3,4}_*" filename prefixes.

  Adapter aliases are hardcoded ("Wi-Fi" = onboard Realtek, "Wi-Fi 2" = USB
  MediaTek) rather than discovered dynamically - acceptable for a
  single-box diagnostic script, but if either adapter is ever replaced/
  reinstalled and Windows assigns it a new alias (e.g. "Wi-Fi 3"), update
  $OnboardAlias/$UsbAlias below.
#>

$ErrorActionPreference = 'Continue'

$LogDir = 'C:\fleet_monitor\power_heartbeat_remotews'
$RetentionDays = 30
$IntervalSeconds = 15
$WanPingTarget = '1.1.1.1'   # fixed public IP, not DNS-dependent - WAN-side reachability check
$OnboardAlias = 'Wi-Fi'      # Realtek 8852BE (internal antennas, the original flapping culprit)
$UsbAlias = 'Wi-Fi 2'        # Panda AXE3000 / MediaTek (external antennas, added 2026-08-27, preferred route)

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

function Get-WifiInfoBlocks {
    # `netsh wlan show interfaces` prints one block per adapter, each starting
    # with a "Name : <alias>" line. With two WiFi adapters now, a single
    # ungrouped regex match (the pre-2026-08-27 approach) grabs whichever
    # adapter's block happens to come first - ambiguous and often wrong.
    # This parses block-by-block and returns a hashtable keyed by alias.
    $result = @{}
    try {
        $out = netsh wlan show interfaces 2>$null
        if (-not $out) { return $result }
        $currentAlias = $null
        $current = $null
        foreach ($line in $out) {
            if ($line -match '^\s*Name\s*:\s*(.+?)\s*$') {
                if ($currentAlias) { $result[$currentAlias] = $current }
                $currentAlias = $matches[1]
                $current = [pscustomobject]@{ State = 'NA'; SignalPct = 'NA'; RssiDbm = 'NA' }
                continue
            }
            if (-not $current) { continue }
            if ($line -match '^\s*State\s*:\s*(.+?)\s*$') { $current.State = $matches[1] }
            elseif ($line -match '^\s*Signal\s*:\s*(\d+)%') { $current.SignalPct = $matches[1] }
            elseif ($line -match '^\s*Rssi\s*:\s*(-?\d+)') { $current.RssiDbm = $matches[1] }
        }
        if ($currentAlias) { $result[$currentAlias] = $current }
    } catch {}
    return $result
}

function Get-ActiveRouteAlias {
    # Which adapter is Windows ACTUALLY routing through right now, i.e. the
    # 0.0.0.0/0 route with the lowest effective metric (route metric +
    # interface metric - what Windows itself uses to pick a route, not just
    # interface metric alone). Re-resolved every tick rather than assumed,
    # so a future metric change (accidental or automatic) shows up as a
    # genuine active_adapter change instead of silently going unnoticed.
    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop
        $best = $null
        $bestMetric = [int]::MaxValue
        foreach ($r in $routes) {
            $ifMetric = (Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($null -eq $ifMetric) { continue }
            $eff = $r.RouteMetric + $ifMetric
            if ($eff -lt $bestMetric) { $bestMetric = $eff; $best = $r }
        }
        if ($best) {
            return (Get-NetAdapter -InterfaceIndex $best.InterfaceIndex -ErrorAction SilentlyContinue).Name
        }
    } catch {}
    return 'NA'
}

function Get-DefaultGateway {
    # Follows whatever $InterfaceAlias is currently the active route (see
    # Get-ActiveRouteAlias) rather than a fixed alias - re-resolved every
    # tick since the gateway/lease has been observed to change (a fresh DHCP
    # lease landed mid-day on 2026-08-18 alongside a "New Internet
    # Connection Profile" event).
    param([string]$InterfaceAlias)
    if (-not $InterfaceAlias -or $InterfaceAlias -eq 'NA') { return $null }
    try {
        $cfg = Get-NetIPConfiguration -InterfaceAlias $InterfaceAlias -ErrorAction Stop
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

function Get-NewReconnectEvents {
    # Single Get-WinEvent call per tick for Microsoft-Windows-WLAN-AutoConfig
    # Event 11010 ("Wireless security started", fired on every reconnect/
    # re-auth) since $sinceLocal - callers then filter the returned events by
    # adapter name themselves (Get-ReconnectCountFor) rather than querying the
    # log twice per tick. Windows event log timestamps are local time, so this
    # stays in local time throughout rather than mixing with the UTC CSV
    # timestamp - StartTime is inclusive, so results are filtered to strictly
    # after $sinceLocal to avoid double-counting the boundary event.
    param([datetime]$sinceLocal)
    try {
        $evts = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; Id=11010; StartTime=$sinceLocal} -ErrorAction SilentlyContinue
        if ($evts) {
            return @($evts | Where-Object { $_.TimeCreated -gt $sinceLocal })
        }
    } catch {}
    return @()
}

function Get-ReconnectCountFor {
    # Event 11010's message body includes "Network Adapter: <friendly name>"
    # (e.g. "Realtek 8852BE Wireless LAN WiFi 6 PCI-E NIC" or "MediaTek Wi-Fi
    # 6/6E Wireless USB LAN Card") - match on that substring to attribute each
    # reconnect to the right physical adapter instead of a single blended total.
    param([array]$events, [string]$adapterNameMatch)
    if (-not $events -or $events.Count -eq 0) { return 0 }
    return @($events | Where-Object { $_.Message -match [regex]::Escape($adapterNameMatch) }).Count
}

# Write header once per new day-file
function Ensure-Header($path) {
    if (-not (Test-Path $path)) {
        [System.IO.File]::AppendAllText($path, "timestamp_utc,uptime_sec,cpu_pct,free_mem_mb,thermal_c,active_adapter,adapter_switches_new,adapter_switches_total,onboard_wifi_state,onboard_wifi_signal_pct,onboard_wifi_rssi_dbm,onboard_wifi_reconnects_new,onboard_wifi_reconnects_total,usb_wifi_state,usb_wifi_signal_pct,usb_wifi_rssi_dbm,usb_wifi_reconnects_new,usb_wifi_reconnects_total,gateway_ip,gateway_ping_ok,gateway_ping_ms,wan_ping_ok,wan_ping_ms`r`n")
    }
}

# Loop-persistent state. All start counting from script start (i.e. from now,
# or from last boot/task-restart) - not retroactive to older log history,
# since the point is a going-forward trend line.
$script:LastReconnectCheck = Get-Date
$script:OnboardReconnectTotal = 0
$script:UsbReconnectTotal = 0
$script:LastActiveAdapter = $null
$script:AdapterSwitchTotal = 0

while ($true) {
    try {
        $now = (Get-Date).ToUniversalTime()
        $nowLocal = Get-Date
        $dayFile = Join-Path $LogDir ("power_heartbeat_v4_{0:yyyy-MM-dd}.csv" -f $now)
        Ensure-Header $dayFile

        $uptimeSec = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
        $cpuPct = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $freeMemMb = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
        $thermal = Get-ThermalCelsius

        $wifiBlocks = Get-WifiInfoBlocks
        $onboardWifi = if ($wifiBlocks.ContainsKey($OnboardAlias)) { $wifiBlocks[$OnboardAlias] } else { [pscustomobject]@{ State = 'NA'; SignalPct = 'NA'; RssiDbm = 'NA' } }
        $usbWifi = if ($wifiBlocks.ContainsKey($UsbAlias)) { $wifiBlocks[$UsbAlias] } else { [pscustomobject]@{ State = 'NA'; SignalPct = 'NA'; RssiDbm = 'NA' } }

        $newEvents = Get-NewReconnectEvents -sinceLocal $script:LastReconnectCheck
        $onboardNewReconnects = Get-ReconnectCountFor -events $newEvents -adapterNameMatch 'Realtek 8852BE'
        $usbNewReconnects = Get-ReconnectCountFor -events $newEvents -adapterNameMatch 'MediaTek'
        $script:OnboardReconnectTotal += $onboardNewReconnects
        $script:UsbReconnectTotal += $usbNewReconnects
        $script:LastReconnectCheck = $nowLocal

        $activeAdapter = Get-ActiveRouteAlias
        $adapterSwitchedThisTick = 0
        if ($script:LastActiveAdapter -and $activeAdapter -ne 'NA' -and $activeAdapter -ne $script:LastActiveAdapter) {
            $adapterSwitchedThisTick = 1
            $script:AdapterSwitchTotal++
        }
        $script:LastActiveAdapter = $activeAdapter

        $gateway = Get-DefaultGateway -InterfaceAlias $activeAdapter
        $gwPing = Test-PingTarget -TargetIp $gateway
        $wanPing = Test-PingTarget -TargetIp $WanPingTarget

        $line = "{0:yyyy-MM-ddTHH:mm:ss.fffZ},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17},{18},{19},{20},{21},{22}" -f `
            $now, $uptimeSec, $cpuPct, $freeMemMb, $thermal, `
            $activeAdapter, $adapterSwitchedThisTick, $script:AdapterSwitchTotal, `
            $onboardWifi.State, $onboardWifi.SignalPct, $onboardWifi.RssiDbm, $onboardNewReconnects, $script:OnboardReconnectTotal, `
            $usbWifi.State, $usbWifi.SignalPct, $usbWifi.RssiDbm, $usbNewReconnects, $script:UsbReconnectTotal, `
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
