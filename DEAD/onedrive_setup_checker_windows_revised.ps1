# setup_checker_windows.ps1
# Run this ONCE on each Windows client machine to register the checker.
# Right-click > Run with PowerShell  (no admin needed)

# ── EDIT THESE ────────────────────────────────────────────────────────────────
$scriptPath = "$env:USERPROFILE\scripts\heartbeat_checker_windows.pyw"
# ─────────────────────────────────────────────────────────────────────────────

$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pythonw) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\pythonw.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\pythonw.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\pythonw.exe"
    )
    $pythonw = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $pythonw) {
    Write-Error "pythonw.exe not found. Make sure Python is installed."
    exit 1
}

$action  = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$scriptPath`""

# Run every 5 minutes for 20 years (Task Scheduler doesn't accept MaxValue)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
             -RepetitionInterval (New-TimeSpan -Minutes 5) `
             -RepetitionDuration (New-TimeSpan -Days 7300)

# Also run at logon so it kicks in right away after reboot
$trigger2 = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

# IMPORTANT: Must run as the interactive logged-on user so desktop
# notifications are visible. "Run whether logged on or not" silently
# swallows all alerts.
$principal = New-ScheduledTaskPrincipal `
    -UserId    $env:USERNAME `
    -LogonType Interactive `
    -RunLevel  Limited

Register-ScheduledTask `
    -TaskName    "OneDriveHeartbeatChecker" `
    -Action      $action `
    -Trigger     @($trigger, $trigger2) `
    -Settings    $settings `
    -Principal   $principal `
    -Description "Checks OneDrive server heartbeat every 5 minutes" `
    -Force

Write-Host ""
Write-Host "Scheduled task registered successfully."
Write-Host "   Runs every 5 minutes + at logon, in your interactive session."
Write-Host ""
Write-Host "   Test now:  Start-ScheduledTask -TaskName 'OneDriveHeartbeatChecker'"
Write-Host "   Remove:    Unregister-ScheduledTask -TaskName 'OneDriveHeartbeatChecker' -Confirm:`$false"
