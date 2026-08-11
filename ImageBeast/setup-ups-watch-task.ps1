<#
.SYNOPSIS
    Registers the ups-watch.ps1 Scheduled Task on ImageBeast (Appendix A3 of
    "UPS and NUT Setup Guide - Amsterdam v7").

.NOTES
    Must be run elevated (Register-ScheduledTask with a SYSTEM principal requires it).
    Idempotent: safe to re-run, replaces any existing task of the same name.
#>

$ErrorActionPreference = "Stop"

$TaskName = "UPS-Watch-ImageBeast"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument '-ExecutionPolicy Bypass -NoProfile -File C:\repos\scripts\ups-watch.ps1 -MinutesOnBattery 8'

# New-ScheduledTaskTrigger won't take -AtStartup and -RepetitionInterval together
# directly, so build the repeating schedule on a throwaway "Once" trigger and copy
# its .Repetition onto the real AtStartup trigger. Standard, well-documented workaround.
$trigger = New-ScheduledTaskTrigger -AtStartup
# [TimeSpan]::MaxValue overflows Task Scheduler's XML duration format (its cap is
# P99999999D...); 10 years is effectively indefinite for this purpose without hitting
# that limit.
$repeating = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$trigger.Repetition = $repeating.Repetition

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName' before re-registering..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Polls ups2 on WorkBenchUnix; shuts down ImageBeast after 8 min on battery. See UPS and NUT Setup Guide Amsterdam v7, Appendix A3."

Write-Host "Registered. Current state:"
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State
Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
