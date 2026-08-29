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

.PARAMETER MinBatteryPercent
    Shut down if battery charge falls to or below this, regardless of elapsed time.
    Whichever of the three conditions fires first wins: this floor, the UPS's own LB
    flag, or MinutesOnBattery.

    This exists because elapsed time alone assumes a known runtime, and runtime varies
    enormously with how recently the battery was last drained. Measured 2026-08-29:
    a rested battery fell 1.15%/min, but the same battery after only 35 minutes of
    recharging fell 5.20%/min - 4.5x faster - while still reporting 98% at the start.
    A percentage read shortly after a discharge is surface charge, not stored energy.

    WorkBenchUnix and ChatWorkhorseUnix already have this via NUT: WBU's ups.conf sets
    `ignorelb` with `override.battery.charge.low = 15`, so upsd publishes LB at 15% and
    both act on it. The Windows clients were the only machines with no floor at all.

    35 is deliberately well above that 15% LB: at the discharge rate measured on
    2026-08-29 the gap between them is only a couple of minutes, and a Windows box has
    a 30-second shutdown delay plus the actual shutdown to get through. ChatWorkhorse
    may want more still, since it can spend up to VMWaitSeconds waiting for the VM.

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
    [int]   $MinBatteryPercent = 35,
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

try {
    $status = Get-UpsVar "ups.status"
}
catch {
    $why = $_.Exception.Message

    # An unreadable UPS means two completely different things depending on whether a
    # countdown is already running, and the original version of this script treated
    # them the same.
    #
    # NOT ARMED: a rebooting NUT server, a switch blip or a saturated link are
    # indistinguishable from a real outage, and powering off every time WBU is briefly
    # unreachable would cause far more downtime than it prevents. Do nothing.
    #
    # ALREADY ARMED: we have seen OB and are counting. The server going away now is
    # evidence the outage is ONGOING - most likely the server shut itself down because
    # of it - which is the opposite of a reason to stand down. Keep counting on
    # elapsed wall-clock, which needs no UPS, and fire at the threshold.
    #
    # 2026-08-29: ChatWorkhorse reached "7.0min of 8min", then WorkBenchUnix powered
    # off 30 seconds before its 8-minute poll. Every subsequent poll landed here and
    # did nothing. It missed shutting down by 60 seconds, on battery, with the NUT
    # server already gone.
    if (Test-Path $StateFile) {
        $since   = [datetime]::Parse((Get-Content $StateFile -Raw).Trim()).ToUniversalTime()
        $elapsed = ((Get-Date).ToUniversalTime() - $since).TotalMinutes

        # A state file far older than the threshold is stale, not a live countdown -
        # e.g. left behind by a reboot while the server happened to be down. Firing on
        # that would shut the machine down on mains for no reason.
        if ($elapsed -gt [Math]::Max($MinutesOnBattery * 3, 60)) {
            Remove-Item $StateFile -Force
            Write-Log ("WARN: cannot read {0}@{1}: {2} - discarding stale {3:N1}min countdown." -f $UpsName, $UpsHost, $why, $elapsed)
            exit 0
        }

        if ($elapsed -ge $MinutesOnBattery) {
            Write-Log ("WARN: cannot read {0}@{1}: {2}" -f $UpsName, $UpsHost, $why)
            Invoke-FleetShutdown ("UPS unreadable AND countdown expired - {0:N1}min of {1}min on battery" -f $elapsed, $MinutesOnBattery)
            exit 0
        }

        Write-Log ("WARN: cannot read {0}@{1}: {2} - countdown continues on elapsed time ({3:N1} of {4}min)." -f $UpsName, $UpsHost, $why, $elapsed, $MinutesOnBattery)
        exit 0
    }

    Write-Log "WARN: cannot read $UpsName@${UpsHost}: $why - not armed, no action taken."
    exit 0
}

# " OB " padded so it matches the token, not a substring of something else.
if (" $status " -notlike "* OB *") {
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force
        Write-Log "Power restored (status: $status) - countdown cancelled."
    }
    # Clearing the latch MUST happen here, after the UPS has been read, and not be
    # guarded by an early exit at the top of main.
    #
    # 2026-08-29: it previously was. `if (Test-Path $TriggerFile) { exit 0 }` sat
    # above the status read, so once this file existed the script exited before ever
    # reaching this line - the only line that removes it. Any machine that fired a
    # shutdown was therefore permanently disarmed from its next boot onward, and
    # silently, because the early exit came before any logging. Found when ImageBeast
    # sat through the 2026-08-29 full-outage test without shutting down.
    if (Test-Path $TriggerFile) {
        Remove-Item $TriggerFile -Force
        Write-Log "Trigger latch cleared - armed again."
    }
    exit 0    # Otherwise silent when healthy, so this does not log every minute forever.
}

# On battery, and we already fired for THIS event: the shutdown is in flight (the VM
# wait alone can take minutes), so do not stack another on top of it. Reaching here
# means the UPS was read, so the latch above gets its chance the moment power returns.
if (Test-Path $TriggerFile) { exit 0 }

# Arm on first sight of OB, then fall through to the checks below rather than
# returning. If the battery is already critical when the outage starts - a second
# outage on a half-recharged battery, say - waiting a further minute to notice is
# exactly the wrong thing to do.
if (-not (Test-Path $StateFile)) {
    Set-Content -Path $StateFile -Value ((Get-Date).ToUniversalTime().ToString("o"))
    Write-Log "ON BATTERY (status: $status) - ${MinutesOnBattery}min countdown started."
}

$since   = [datetime]::Parse((Get-Content $StateFile -Raw).Trim()).ToUniversalTime()
$elapsed = ((Get-Date).ToUniversalTime() - $since).TotalMinutes

# Read charge only while on battery - on mains this script has already exited.
# Failure is non-fatal: fall back to elapsed time and the LB flag.
$charge = $null
try { $charge = [int](Get-UpsVar "battery.charge") } catch { }

# Three independent reasons to stop, whichever arrives first. Elapsed time alone was
# not enough: see .PARAMETER MinBatteryPercent for the 2026-08-29 measurements.
$reason = $null
if (" $status " -like "* LB *") {
    # The UPS itself, via WBU's override.battery.charge.low, says the battery is done.
    $reason = "UPS reports LOW BATTERY (status: $status)"
}
elseif ($null -ne $charge -and $charge -le $MinBatteryPercent) {
    $reason = "battery {0}% at or below floor {1}%, after {2:N1}min on battery" -f $charge, $MinBatteryPercent, $elapsed
}
elseif ($elapsed -ge $MinutesOnBattery) {
    $reason = "on battery {0:N1}min, threshold {1}min" -f $elapsed, $MinutesOnBattery
}

if ($reason) {
    Invoke-FleetShutdown $reason
}
else {
    $c = if ($null -eq $charge) { "?" } else { "$charge" }
    Write-Log ("On battery {0:N1}min of {1}min, charge {2}% (floor {3}%)." -f $elapsed, $MinutesOnBattery, $c, $MinBatteryPercent)
}
