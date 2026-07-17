# wifi_watchdog.ps1
# C:\repos\scripts\TravelBeast\wifi_watchdog.ps1
# Created: 2026-07-14 12:00 UTC
# Monitors wifi connectivity and toggles adapter if dead.
# Logs a daily all-clear, and details on any fix event.
# 2026-07-14 12:30 UTC - Fixed adapter name to "Wi-Fi"; wrapped Test-Connection in try/catch
# 2026-07-14 13:00 UTC - Replaced Test-Connection with ping.exe; added two-stage recovery (toggle then reconnect)

$logFile = "C:\repos\scripts\TravelBeast\wifi_watchdog.log"
$adapterName = "Wi-Fi"
$pingTarget = "1.1.1.1"
$ssid = "oLiFaNt_5G"
$dailyFlagFile = "C:\repos\scripts\TravelBeast\.last_allclear"

function Write-Log($message) {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm UTC")
    Add-Content -Path $logFile -Value "[$timestamp] $message"
}

function Test-Ping {
    $result = ping -n 2 $pingTarget
    return ($result -match "Reply from")
}

# Check connectivity
if (Test-Ping) {
    $today = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $lastAllClear = if (Test-Path $dailyFlagFile) { Get-Content $dailyFlagFile } else { "" }
    if ($lastAllClear -ne $today) {
        Write-Log "ALL CLEAR"
        Set-Content -Path $dailyFlagFile -Value $today
    }
} else {
    Write-Log "Connectivity lost - toggling adapter"

    # Stage 1: disable/enable adapter
    netsh interface set inteface $adapterName disable
    Start-Sleep -Seconds 5
    netsh interface set interface $adapterName enable
    Start-Sleep -Seconds 10

    if (Test-Ping) {
        Write-Log "Restored after adapter toggle"
    } else {
        # Stage 2: explicitly reconnect to SSID
        Write-Log "Toggle did not restore - attempting reconnect to $ssid"
        netsh wlan connect ssid="$ssid" name="$ssid"
        Start-Sleep -Seconds 15

        if (Test-Ping) {
            Write-Log "Restored after reconnect to $ssid"
        } else {
            Write-Log "Recovery failed - manual intervention required"
        }
    }
}