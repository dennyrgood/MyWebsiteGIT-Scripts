# surface3-gc-snapshot-fleet-configs.ps1
# Created 2026-07-21; converted to repo-based snapshot 2026-07-28 after surface3-gc
# gained a local repo checkout (was previously a no-repo box staging bespoke files +
# Task Scheduler exports through OneDrive\ForFleetConfigs\surface3-gc\).
#
# Exports this box's fleet Task Scheduler tasks into the fleet-configs repo snapshot.
# Manual-run; review `git diff` and commit.
#
# Task list = existing TaskSched\*.xml + any task DISCOVERED by its action running the
# fleet writer/metrics/heartbeat/watchdog (matched on the action, so a display name with
# spaces or typos like "Heartbeat Write OneDrive" is found fine).
#
# Hardened: one stale or protected task never aborts the run. Do NOT set
# $ErrorActionPreference='Stop' (it turns schtasks' stderr into a terminating error);
# each export checks $LASTEXITCODE and is wrapped.

$Machine = "Surface3GC"         # fleet-configs folder name for this box

$repoRoot = @("D:\repos", "C:\repos", "$env:USERPROFILE\repos") |
            Where-Object { Test-Path "$_\fleet-configs" } | Select-Object -First 1
if (-not $repoRoot) { Write-Error "fleet-configs repo not found under D:\repos, C:\repos, or ~\repos"; return }

$dest = Join-Path $repoRoot "fleet-configs\$Machine\TaskSched"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$wanted = [System.Collections.Generic.List[string]]::new()
Get-ChildItem $dest -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $wanted.Add($_.BaseName) }
Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet[-_ ]?metrics[-_ ]?server|fleet[-_ ]?monitor|heartbeat|run[-_ ]?hidden|watchdog|bekah|gc_'
} | ForEach-Object { $wanted.Add($_.TaskName) }
$wanted = @($wanted | Select-Object -Unique)

Write-Host "Tasks to export:"; $wanted | ForEach-Object { Write-Host "  [$_]" }; Write-Host ""

foreach ($t in $wanted) {
    $out = Join-Path $dest "$t.xml"
    try {
        $xml = & schtasks /Query /TN "\$t" /XML 2>$null
        if ($LASTEXITCODE -eq 0 -and $xml) {
            $xml | Out-File -FilePath $out -Encoding Unicode
            Write-Host "exported: $t"
        } else {
            Write-Warning "skipped '$t' (missing, protected, or inaccessible -- exit $LASTEXITCODE; try an elevated shell)"
        }
    } catch {
        Write-Warning "skipped '$t' ($($_.Exception.Message))"
    }
}

# Some boxes have multiple local accounts, and the
# real PSProfile content can live under an account other than the one running this
# script -- so search all user profiles on the box before falling back to $PROFILE
# (which covers boxes like ImageBeast that never adopted the PSProfile indirection).
$psProfileCandidates = @("$env:USERPROFILE\PSProfile\Microsoft.PowerShell_profile.ps1")
$psProfileCandidates += Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "Public" } |
    ForEach-Object { Join-Path $_.FullName "PSProfile\Microsoft.PowerShell_profile.ps1" }
$psProfileCandidates += $PROFILE
$psProfileSrc = $psProfileCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($psProfileSrc) {
    $psProfileDest = Join-Path $repoRoot "fleet-configs\$Machine\PSProfile"
    New-Item -ItemType Directory -Force -Path $psProfileDest | Out-Null
    Copy-Item $psProfileSrc (Join-Path $psProfileDest "Microsoft.PowerShell_profile.ps1") -Force
    Write-Host "exported: PSProfile\Microsoft.PowerShell_profile.ps1"
} else {
    Write-Warning "skipped PSProfile (no Microsoft.PowerShell_profile.ps1 found under any C:\Users\* account or at $PROFILE)"
}


# --- Syncthing (added 2026-08-28) -------------------------------------------
# This box holds the off-site restic copy of the Immich library at D:\Immich.
# WBU's config records that it SENDS here; nothing recorded what this end does
# with it -- the local path, the Receive Only folder type, the device pairing.
# If this machine died, the receiving half would be rebuilt from memory.
#
# config.xml is captured with <apikey> and <password> REDACTED, then VERIFIED:
# if either survives into the output the file is deleted rather than committed.
# Neither is needed for a rebuild -- both are regenerated on a fresh install.
#
# NOT captured: cert.pem / key.pem, this box's device identity. Keeping them
# would let a rebuild retain its device ID and avoid re-pairing, but a private
# key in a repo is wider exposure than that convenience is worth. A rebuilt box
# gets a new device ID and must be re-added on WBU.
$stDestRoot = Join-Path $repoRoot "fleet-configs\$Machine"

$stCandidates = @(
    "$env:LOCALAPPDATA\Syncthing\config.xml",
    "$env:LOCALAPPDATA\Syncthing\data\config.xml",
    "$env:APPDATA\Syncthing\config.xml"
)
$stCfgPath = $stCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $stCfgPath) {
    Write-Warning "Syncthing config.xml not found in: $($stCandidates -join ', ') -- skipping Syncthing capture"
} else {
    Write-Host "Syncthing config: $stCfgPath"
    try {
        [xml]$stCfg = Get-Content $stCfgPath -Raw
        $liveKey = $stCfg.configuration.gui.apikey
        $livePw  = $stCfg.configuration.gui.password
        if ($stCfg.configuration.gui.apikey)   { $stCfg.configuration.gui.apikey   = "REDACTED" }
        if ($stCfg.configuration.gui.password) { $stCfg.configuration.gui.password = "REDACTED" }

        $stOut = Join-Path $stDestRoot "syncthing-config.xml"
        $stCfg.Save($stOut)

        # Fail closed. A regex redaction fails open; this checks the actual result.
        $saved = Get-Content $stOut -Raw
        $leaked = $false
        if ($liveKey -and $saved.Contains($liveKey)) { $leaked = $true }
        if ($livePw  -and $saved.Contains($livePw))  { $leaked = $true }
        if ($leaked) {
            Remove-Item $stOut -Force
            Write-Warning "REDACTION FAILED - secret survived into output; syncthing-config.xml removed"
        } else {
            Write-Host "exported: syncthing-config.xml (apikey/password redacted and verified)"

            $lines = @()
            $lines += "Remote devices"
            foreach ($d in $stCfg.configuration.device) {
                $addrs = ($d.address -join ", ")
                $lines += ("  {0,-22} {1}..  addresses: {2}" -f $d.name, $d.id.Substring(0,7), $addrs)
            }
            $lines += ""
            $lines += "Folders"
            foreach ($f in $stCfg.configuration.folder) {
                if (-not $f.id) { continue }
                $names = @()
                foreach ($fd in $f.device) {
                    $m = $stCfg.configuration.device | Where-Object { $_.id -eq $fd.id }
                    $names += $(if ($m) { $m.name } else { $fd.id.Substring(0,7) })
                }
                $lines += ("  {0}  ({1})" -f $f.label, $f.id)
                $lines += ("      path        : {0}" -f $f.path)
                $lines += ("      type        : {0}" -f $f.type)
                $lines += ("      ignorePerms : {0}" -f $f.ignorePerms)
                $lines += ("      shared with : {0}" -f ($names -join ", "))
                $lines += ("      versioning  : {0}" -f $(if ($f.versioning.type) { $f.versioning.type } else { "none" }))
            }
            $lines += ""
            $lines += ("GUI: {0}  tls={1}  (apikey/password redacted)" -f $stCfg.configuration.gui.address, $stCfg.configuration.gui.tls)
            $lines | Out-File -FilePath (Join-Path $stDestRoot "syncthing-topology.txt") -Encoding utf8
            Write-Host "exported: syncthing-topology.txt"
        }
    } catch {
        Write-Warning "Syncthing capture failed: $_"
    }

    try {
        $stExe = Get-Command syncthing.exe -ErrorAction SilentlyContinue
        if ($stExe) {
            & $stExe.Source --version | Select-Object -First 1 |
                Out-File (Join-Path $stDestRoot "syncthing-version.txt") -Encoding utf8
        }
    } catch { Write-Warning "could not read syncthing version: $_" }

    # Record that the received repo is where the docs claim. Cheap, and catches
    # a folder path silently changed in the GUI.
    if (Test-Path "D:\Immich\config") {
        $n = (Get-ChildItem "D:\Immich" -Directory | Measure-Object).Count
        "restic repo present at D:\Immich ($n subdirs, config present)" |
            Out-File (Join-Path $stDestRoot "restic-offsite-repo.txt") -Encoding utf8
        Write-Host "noted: restic repo present at D:\Immich"
    } else {
        Write-Warning "D:\Immich\config not found - the off-site restic repo is not where expected"
    }
}

Write-Host "`nSnapshot complete. Review: cd $repoRoot\fleet-configs ; git status"
