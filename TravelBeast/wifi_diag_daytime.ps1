$logFile = "$env:USERPROFILE\wifi_diag_daytime.csv"
"Timestamp,PingMs,PingStatus,BSSID,SignalPercent,Channel" | Out-File $logFile
$lastBssid = ""; $lastSignal = ""; $lastChannel = ""
1..5760 | ForEach-Object {
    $ts = Get-Date -Format "HH:mm:ss.fff"
    $p = Test-Connection -ComputerName 192.168.178.1 -Count 1 -ErrorAction SilentlyContinue
    $pingMs = if ($p) { $p.ResponseTime } else { "" }
    $pingStatus = if ($p) { "OK" } else { "TIMEOUT" }
    if ($_ % 12 -eq 1) {
        $wlan = netsh wlan show interfaces
        $lastBssid = (($wlan | Select-String "AP BSSID") -replace ".*:\s*", "").Trim()
        $lastSignal = (($wlan | Select-String "^\s*Signal\s*:") -replace ".*:\s*", "").Trim()
        $lastChannel = (($wlan | Select-String "^\s*Channel\s*:") -replace ".*:\s*", "").Trim()
    }
    "$ts,$pingMs,$pingStatus,$lastBssid,$lastSignal,$lastChannel" | Out-File $logFile -Append
    Start-Sleep -Seconds 5
}
Write-Output "Done: $logFile"
