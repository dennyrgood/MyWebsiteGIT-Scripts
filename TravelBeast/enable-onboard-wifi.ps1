<#
.SYNOPSIS
  Re-enables TravelBeast's onboard Wi-Fi adapter (Realtek RTL8852BE).

.PURPOSE
  Companion to disable-onboard-wifi.ps1. The onboard radio was disabled
  2026-08-31 after installing an external USB Wi-Fi dongle (Realtek
  8832CU, "Wi-Fi 2") to work around persistent onboard Wi-Fi flakiness
  (see power-heartbeat.ps1's header for the full investigation history).
  Having both adapters enabled and connected to the same AP at once
  creates two independent DHCP leases with tied routing metrics, which
  is ambiguous and undesirable - so these two scripts exist to cleanly
  toggle between "dongle only" (onboard disabled) and "onboard only"
  (for when the dongle isn't attached, e.g. travel) rather than running
  both simultaneously.

  Desktop shortcuts point at this file and disable-onboard-wifi.ps1 so
  the toggle is a double-click + one UAC prompt, not a remembered
  PowerShell one-liner.

.NOTES
  Enable-NetAdapter requires elevation; this script self-elevates via
  Start-Process -Verb RunAs so the desktop shortcut itself doesn't need
  "Run as administrator" set - it just triggers one UAC prompt each use.
#>

Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile',
    '-Command',
    'Enable-NetAdapter -Name "Wi-Fi" -Confirm:$false; Write-Host "Onboard Wi-Fi enabled."; Start-Sleep -Seconds 3'
)
