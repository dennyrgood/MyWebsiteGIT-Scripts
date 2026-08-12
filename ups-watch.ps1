<#
.SYNOPSIS
    UPS watchdog for the Windows fleet. Polls a NUT server and shuts the machine
    down after a sustained outage, optionally stopping a VirtualBox VM first.

.DESCRIPTION
    Created: 2026-08-04 UTC. Supersedes the ChatWorkhorse script in "UPS & NUT Setup
    Guide — Amsterdam v3", which polled the NAS (UPS #1) for battery.charge <= 20.
    That was wrong twice over: it watched the wrong UPS, and a percentage read from a
    UPS you are not plugged into says nothing useful about your own remaining runtime.

    NO NUT BINARIES REQUIRED. This speaks NUT's line protocol directly over TCP, so
    there is nothing to install on Windows — no upsc.exe, no MSI, no USB driver. That
    matters because NUT's Windows builds are sporadic and community-maintained.

    NO CREDENTIALS REQUIRED. upsd serves variable reads (GET VAR) without
    authentication; only commands and SET need a login. So no password lands on any
    Windows box. The `monslave` account on WBU exists for a real upsmon client if one
    is ever wanted — it is deliberately not used here.

    TRIGGER IS ELAPSED TIME, NOT BATTERY PERCENTAGE, matching WorkBenchUnix. The UPS
    driver in use (nutdrv_qx) reports no battery.runtime at all, so a percentage
    cannot be converted into "how long do I have" without guessing.

    State is a timestamp file, so the countdown survives the script exiting between
    runs — this is designed to be called every minute by Task Scheduler, not to sit
    resident.

.PARAMETER UpsHost
    NUT server. Machines on UPS #2 (ImageBeast, ChatWorkhorse) use WorkBenchUnix.
    Machines on UPS #1, or with no UPS of their own, use the NAS (192.168.178.123).

.PARAMETER MinutesOnBattery
    Minutes on battery before shutting down. Stagger these across the fleet so
    dependants stop before the machines they depend on. Current plan:
        CWHU (VM)      5   (its own upsmon, not this script)
        ImageBeast     8
        ChatWorkhorse  8   (waits for the VM regardless)
        WorkBenchUnix 10   (its own upssched timer)

.PARAMETER VMName
    Optional VirtualBox VM to stop before shutting down. Used on ChatWorkhorse for
    ChatWorkhorseUnix. Leave empty elsewhere.

    Stopping tries a clean shutdown first: a dedicated SSH key (SSHKeyPath),
    restricted via a forced `command=` in the VM's authorized_keys to run ONLY
    clean.ubuntu.shutdown, triggers the same docker-compose-aware stop CWHU's own
    upsmon uses (respects depends_on order, gives Postgres real headroom instead
    of Compose's bare 10s default). Falls back to a plain ACPI power button only
    if that's unreachable or doesn't complete in time - which matters most
    exactly when it's least likely to help, i.e. if CWHU's guest networking is
    itself what's down. See ups-watch.functions.ps1 for the implementation and
    ChatWorkHorse/ for the sudoers/authorized_keys setup this depends on.

.PARAMETER SSHUser
.PARAMETER SSHKeyPath
.PARAMETER SSHConnectTimeoutSeconds
    Only used when VMName is set. See VMName above.

.EXAMPLE
    # ImageBeast
    .\ups-watch.ps1 -MinutesOnBattery 8

.EXAMPLE
    # ChatWorkhorse — stop the VM first, and wait for it to actually be off
    .\ups-watch.ps1 -MinutesOnBattery 8 -VMName ChatWorkhorseUnix

.NOTES
    SCHEDULED TASK MUST NOT RUN AS SYSTEM WHEN -VMName IS USED.
    VirtualBox VMs belong to the user who started them. A task running as SYSTEM
    cannot see or control a VM owned by dhm — `VBoxManage showvminfo` simply reports
    it does not exist, the wait loop falls through, and Windows shuts down on top of
    a running VM. Run the task as the VM's owner with "Run with highest privileges"
    and "Run whether user is logged on or not".
#>

param(
    [string]$UpsHost          = "192.168.178.242",   # WorkBenchUnix (UPS #2). NAS is 192.168.178.123.
    [string]$UpsName          = "ups2",
    [int]   $Port             = 3493,
    [int]   $MinutesOnBattery = 8,
    [string]$VMName           = "",
    [int]   $VMWaitSeconds    = 180,
    [string]$SSHUser          = "dhm",
    [string]$SSHKeyPath       = (Join-Path $env:USERPROFILE ".ssh\cwh_ups_watch_ed25519"),
    [int]   $SSHConnectTimeoutSeconds = 10,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$StateDir    = Join-Path $env:ProgramData "ups-watch"
$StateFile   = Join-Path $StateDir "$UpsName-onbatt-since.txt"
$TriggerFile = Join-Path $StateDir "$UpsName-triggered.txt"
$LogFile     = Join-Path $StateDir "ups-watch.log"

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# Write-Log, Invoke-CleanShutdownViaSSH, and Stop-VMAndWait live in
# ups-watch.functions.ps1, shared with ChatWorkHorse/TakeDown_VM.ps1. Must be
# dot-sourced AFTER $StateDir/$LogFile are set above - both functions use them.
. (Join-Path $PSScriptRoot "ups-watch.functions.ps1")

<#
    Reads one variable from upsd. Returns $null on any failure — caller must treat
    that as "unknown", never as "on battery".
#>
function Get-UpsVar([string]$VarName) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect($UpsHost, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000, $false)) {
            throw "connect timed out after 5s"
        }
        $client.EndConnect($connect)
        $client.ReceiveTimeout = 5000
        $client.SendTimeout    = 5000

        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true

        $writer.WriteLine("GET VAR $UpsName $VarName")
        $response = $reader.ReadLine()
        try { $writer.WriteLine("LOGOUT") } catch { }

        if ($null -eq $response)         { throw "no response from upsd" }
        if ($response -like "ERR*")      { throw "upsd returned: $response" }

        # Expected: VAR ups2 ups.status "OL"
        if ($response -match '"([^"]*)"') { return $Matches[1] }
        throw "unparseable response: $response"
    }
    finally {
        if ($client) { $client.Close() }
    }
}

function Invoke-FleetShutdown([string]$Reason) {
    Write-Log "TRIGGER: $Reason"

    if ($WhatIf) {
        Write-Log "WhatIf: would stop VM (if configured) and shut down. Nothing done."
        return
    }

    Set-Content -Path $TriggerFile -Value ((Get-Date).ToUniversalTime().ToString("o"))

    if ($VMName) {
        [void](Stop-VMAndWait -Name $VMName -TimeoutSeconds $VMWaitSeconds `
            -SSHUser $SSHUser -SSHKeyPath $SSHKeyPath -SSHConnectTimeoutSeconds $SSHConnectTimeoutSeconds)
    }

    Write-Log "Shutting down Windows."
    & shutdown /s /t 30 /c "UPS on battery ${MinutesOnBattery}min - shutting down"
}

# --- main ------------------------------------------------------------------

# Already fired during this power event. The shutdown is in flight (the VM wait
# alone can take minutes); do not stack another on top of it. Cleared on ONLINE.
if (Test-Path $TriggerFile) { exit 0 }

try {
    $status = Get-UpsVar "ups.status"
}
catch {
    # Deliberately does NOT shut down. A rebooting NUT server, a switch blip or a
    # saturated link are indistinguishable from a real outage here, and powering the
    # machine off every time WBU is briefly unreachable would cause far more downtime
    # than it prevents.
    Write-Log "WARN: cannot read $UpsName@${UpsHost}: $($_.Exception.Message) - no action taken."
    exit 0
}

# " OB " padded so it matches the token, not a substring of something else.
if (" $status " -notlike "* OB *") {
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force
        Write-Log "Power restored (status: $status) - countdown cancelled."
    }
    if (Test-Path $TriggerFile) { Remove-Item $TriggerFile -Force }
    exit 0    # Silent when healthy, so this does not write a log line every minute forever.
}

if (-not (Test-Path $StateFile)) {
    Set-Content -Path $StateFile -Value ((Get-Date).ToUniversalTime().ToString("o"))
    Write-Log "ON BATTERY (status: $status) - ${MinutesOnBattery}min countdown started."
    exit 0
}

$since   = [datetime]::Parse((Get-Content $StateFile -Raw).Trim()).ToUniversalTime()
$elapsed = ((Get-Date).ToUniversalTime() - $since).TotalMinutes

if ($elapsed -ge $MinutesOnBattery) {
    Invoke-FleetShutdown ("on battery {0:N1}min, threshold {1}min" -f $elapsed, $MinutesOnBattery)
}
else {
    Write-Log ("On battery {0:N1}min of {1}min." -f $elapsed, $MinutesOnBattery)
}
