# chatworkhorse-snapshot-fleet-configs.ps1
# Created 2026-07-21; hardened 2026-07-21.
# Exports this box's fleet Task Scheduler tasks into the fleet-configs repo snapshot.
# Manual-run; review `git diff` and commit.
#
# Task list = existing TaskSched\*.xml + any task DISCOVERED by its action running the
# fleet writer/metrics/heartbeat (matched on the action, so a display name with spaces
# like "Fleet Metrics Server" is found fine).
#
# Hardened: one stale or protected task never aborts the run. Do NOT set
# $ErrorActionPreference='Stop' (it turns schtasks' stderr into a terminating error);
# each export checks $LASTEXITCODE and is wrapped, so a stale XML name or an
# inaccessible task ("Access is denied") is skipped with a warning.

$Machine = "ChatWorkHorse"       # fleet-configs folder name for this box

$repoRoot = @("D:\repos", "C:\repos", "$env:USERPROFILE\repos") |
            Where-Object { Test-Path "$_\fleet-configs" } | Select-Object -First 1
if (-not $repoRoot) { Write-Error "fleet-configs repo not found under D:\repos, C:\repos, or ~\repos"; return }

$dest = Join-Path $repoRoot "fleet-configs\$Machine\TaskSched"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$wanted = [System.Collections.Generic.List[string]]::new()
Get-ChildItem $dest -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $wanted.Add($_.BaseName) }
Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet[-_ ]?metrics[-_ ]?server|fleet[-_ ]?monitor|heartbeat[-_ ]?writer|run[-_ ]?hidden|watchdog'
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

Write-Host "`nSnapshot complete. Review: cd $repoRoot\fleet-configs ; git status"
