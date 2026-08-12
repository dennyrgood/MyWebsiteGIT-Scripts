<#
.SYNOPSIS
    Cleanly stops the ChatWorkhorseUnix VM (via the shared Stop-VMAndWait logic).

.DESCRIPTION
    Thin wrapper around Stop-VMAndWait in ../ups-watch.functions.ps1 - the same
    function ups-watch.ps1 uses for its production UPS-triggered shutdown. Tries
    a clean, docker-compose-aware shutdown over SSH first (same path CWHU's own
    upsmon uses), falls back to a plain ACPI power button if that's unreachable.

    Useful standalone - e.g. before manually rebooting the ChatWorkhorse host,
    since VirtualBox's own --autostop-type isn't supported on Windows hosts and
    a plain Windows restart will NOT stop the VM gracefully on its own.

    Verified working on ChatWorkhorse 2026-08-12: clean SSH path stopped all 4
    Immich containers with exit code 0 (not 137/SIGKILL), reached poweroff.

.EXAMPLE
    .\TakeDown_VM.ps1
#>

param(
    [string]$VMName        = "ChatWorkhorseUnix",
    [int]   $TimeoutSeconds = 180,
    [string]$SSHUser       = "dhm",
    [string]$SSHKeyPath    = (Join-Path $env:USERPROFILE ".ssh\cwh_ups_watch_ed25519"),
    [int]   $SSHConnectTimeoutSeconds = 10
)

$StateDir = Join-Path $env:ProgramData "ups-watch"
$LogFile  = Join-Path $StateDir "ups-watch.log"
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

. (Join-Path $PSScriptRoot "..\ups-watch.functions.ps1")

$ok = Stop-VMAndWait -Name $VMName -TimeoutSeconds $TimeoutSeconds `
    -SSHUser $SSHUser -SSHKeyPath $SSHKeyPath -SSHConnectTimeoutSeconds $SSHConnectTimeoutSeconds

if ($ok) { exit 0 } else { exit 1 }
