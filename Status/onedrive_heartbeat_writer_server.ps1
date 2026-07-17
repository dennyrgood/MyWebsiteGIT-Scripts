# onedrive_heartbeat_writer_server.ps1
# Fleet FLEET_OPS - Heartbeat + Machine Info + Metrics History Writer
# Writes heartbeat_{host}.txt, machine_info_{host}.json, and metrics_history_{host}.json
# to the local C:\fleet_monitor dir, served over Tailscale by fleet_metrics_server.py.
# (Filename keeps the "onedrive" prefix for Task Scheduler compatibility; OneDrive is no longer used.)
# Main loop: 150s — heartbeat + machine_info
# History: every 30s tick (every 5th tick = 150s triggers machine_info write)
# Last updated: 2026-06-16 14:12 UTC

# ── Hostname resolution ────────────────────────────────────────

$hostnameMap = @{
    "amsterdamdeskto" = "amsterdamdesktop"
}

$rawHost     = $env:COMPUTERNAME.ToLower()
$checkerHost = if ($hostnameMap.ContainsKey($rawHost)) { $hostnameMap[$rawHost] } else { $rawHost }

# ── Local metrics dir (served over Tailscale; no OneDrive) ─────

$heartbeatDir  = if ($env:FLEET_METRICS_DIR) { $env:FLEET_METRICS_DIR } else { "C:\fleet_monitor" }
$heartbeatFile = Join-Path $heartbeatDir "heartbeat_$checkerHost.txt"
$infoFile      = Join-Path $heartbeatDir "machine_info_$checkerHost.json"
$historyFile   = Join-Path $heartbeatDir "metrics_history_$checkerHost.json"

$HISTORY_MAX_LINES = 120

# ── Ensure directory exists ────────────────────────────────────

New-Item -ItemType Directory -Force -Path $heartbeatDir | Out-Null

# ── Helper: run PowerShell expression, return $null on error ──

function Safe-Get {
    param([scriptblock]$block)
    try { & $block } catch { $null }
}

# ── Helper: format datetime as local "Jun 9 23:35" ────────────

function Format-LocalDT {
    param([datetime]$dt)
    if ($null -eq $dt) { return $null }
    $local = $dt.ToLocalTime()
    return $local.ToString("MMM d HH:mm")
}

# ── Collect Windows-specific info via CIM/registry ────────────

function Get-MachineInfo {

    # OS / build
    $os      = Safe-Get { Get-CimInstance Win32_OperatingSystem }
    $osBuild = if ($os) { $os.BuildNumber } else { $null }
    $osVer   = if ($os) { "$($os.Version).$osBuild" } else { $null }

    # Last reboot
    $lastReboot = if ($os) { Format-LocalDT $os.LastBootUpTime } else { $null }

    # Last WU-triggered reboot (Event ID 1074, source TrustedInstaller)
    $lastWUReboot = Safe-Get {
        $ev = Get-WinEvent -LogName System -MaxEvents 5000 -ErrorAction SilentlyContinue |
              Where-Object { $_.Id -eq 1074 -and $_.Message -like "*TrustedInstaller*" } |
              Select-Object -First 1
        if ($ev) { Format-LocalDT $ev.TimeCreated } else { $null }
    }

    # Last installed update (date + KB)
    $lastWU   = $null
    $lastWUKB = $null
    $wu = Safe-Get {
        Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1
    }
    if ($wu) {
        $lastWU   = Format-LocalDT $wu.InstalledOn
        $lastWUKB = $wu.HotFixID
    }

    # Pending reboot — check common registry keys
    $pendingReboot = $false
    $pendingReboot = $pendingReboot -or (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
    $pendingReboot = $pendingReboot -or (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
    $pendingReboot = $pendingReboot -or (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations")

    # RAM
    $ramTotalGB = $null
    $ramUsedGB  = $null
    if ($os) {
        $ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $ramUsedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    }

    # CPU % (2-second sample)
    $cpuPercent = Safe-Get {
        $c = Get-CimInstance Win32_Processor
        if ($c) { [math]::Round(($c | Measure-Object -Property LoadPercentage -Average).Average, 0) } else { $null }
    }

    # Disks — local fixed drives and removable drives (e.g. USB flash sticks)
    $disks = @()
    $drives = Safe-Get { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 OR DriveType=2" }
    if ($drives) {
        foreach ($d in $drives) {
            $totalGB = [math]::Round($d.Size / 1GB, 1)
            $freeGB  = [math]::Round($d.FreeSpace / 1GB, 1)
            $usedGB  = [math]::Round($totalGB - $freeGB, 1)
            $disks  += @{
                drive    = $d.DeviceID
                used_gb  = $usedGB
                total_gb = $totalGB
                free_gb  = $freeGB
            }
        }
    }

    return @{
        host           = $checkerHost
        timestamp_utc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        os_build       = $osVer
        last_reboot    = $lastReboot
        last_wu_reboot = $lastWUReboot
        last_wu_date   = $lastWU
        last_wu_kb     = $lastWUKB
        pending_reboot = $pendingReboot
        ram_total_gb   = $ramTotalGB
        ram_used_gb    = $ramUsedGB
        cpu_percent    = $cpuPercent
        disks          = $disks
    }
}

# ── Collect metrics history entry ─────────────────────────────

function Get-MetricsEntry {
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # RAM %
    $ramPct = $null
    $os = Safe-Get { Get-CimInstance Win32_OperatingSystem }
    if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        $ramPct = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 0)
    }

    # CPU %
    $cpuPct = $null
    $cpuPct = Safe-Get {
        $c = Get-CimInstance Win32_Processor
        if ($c) { [math]::Round(($c | Measure-Object -Property LoadPercentage -Average).Average, 0) } else { $null }
    }

    # VRAM % — device-level fields from ComfyUI /system_stats (localhost:8188)
    $vramPct = $null
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:8188/system_stats" -TimeoutSec 5 -ErrorAction Stop
        # Use device-level vram_total/vram_free, NOT torch_vram_total/torch_vram_free
        $vramTotal = $r.devices[0].vram_total
        $vramFree  = $r.devices[0].vram_free
        if ($vramTotal -and $vramTotal -gt 0) {
            $vramPct = [math]::Round(($vramTotal - $vramFree) / $vramTotal * 100, 0)
        }
    } catch { <# ComfyUI down or not present — leave null #> }

    # GPU % — nvidia-smi
    $gpuPct = $null
    try {
        $smiOut = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $smiOut -match '^\s*\d+\s*$') {
            $gpuPct = [int]$smiOut.Trim()
        }
    } catch { <# nvidia-smi unavailable — leave null #> }

    return [PSCustomObject]@{
        ts       = $ts
        ram_pct  = $ramPct
        cpu_pct  = $cpuPct
        vram_pct = $vramPct
        gpu_pct  = $gpuPct
    }
}

# ── Append history entry and trim to last N lines ──────────────

function Write-HistoryEntry {
    try {
        $entry    = Get-MetricsEntry
        $jsonLine = $entry | ConvertTo-Json -Compress

        # Read existing lines (may not exist yet)
        $existing = @()
        if (Test-Path $historyFile) {
            $existing = [System.IO.File]::ReadAllLines($historyFile)
        }

        # Append new line and trim to last 120
        $all      = @($existing) + @($jsonLine)
        $trimmed  = if ($all.Count -gt $HISTORY_MAX_LINES) { $all[($all.Count - $HISTORY_MAX_LINES)..($all.Count - 1)] } else { $all }

        [System.IO.File]::WriteAllLines($historyFile, $trimmed, [System.Text.UTF8Encoding]::new($false))
    } catch { <# silently continue #> }
}

# ── Main loop ─────────────────────────────────────────────────
# Tick every 30s. Every 5th tick (150s) also writes heartbeat + machine_info.

$tickInterval   = 30   # seconds
$machineInfoEvery = 5  # ticks
$tickCount      = 0

while ($true) {

    # Always write history entry
    Write-HistoryEntry

    # Every 5th tick: write heartbeat + machine_info
    if ($tickCount % $machineInfoEvery -eq 0) {

        try {
            [System.IO.File]::WriteAllText(
                $heartbeatFile,
                (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ffffff+00:00"),
                [System.Text.UTF8Encoding]::new($false)
            )
        } catch { <# silently continue #> }

        try {
            $info     = Get-MachineInfo
            $infoJson = $info | ConvertTo-Json -Depth 5 -Compress:$false
            [System.IO.File]::WriteAllText($infoFile, $infoJson, [System.Text.UTF8Encoding]::new($false))
        } catch { <# silently continue #> }
    }

    $tickCount++
    Start-Sleep -Seconds $tickInterval
}
