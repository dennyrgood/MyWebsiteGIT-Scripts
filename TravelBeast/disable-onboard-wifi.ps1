<#
.SYNOPSIS
  Disables TravelBeast's onboard Wi-Fi adapter (Realtek RTL8852BE).

.PURPOSE
  Companion to enable-onboard-wifi.ps1 - see that file's header for the
  full rationale. Use this when the external USB Wi-Fi dongle (Realtek
  8832CU, "Wi-Fi 2") is attached and should be the only active Wi-Fi
  adapter, to avoid two simultaneous connections to the same AP with
  tied routing metrics.

.NOTES
  Disable-NetAdapter requires elevation; this script self-elevates via
  Start-Process -Verb RunAs so the desktop shortcut itself doesn't need
  "Run as administrator" set - it just triggers one UAC prompt each use.
#>

Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile',
    '-Command',
    'Disable-NetAdapter -Name "Wi-Fi" -Confirm:$false; Write-Host "Onboard Wi-Fi disabled."; Start-Sleep -Seconds 3'
)
