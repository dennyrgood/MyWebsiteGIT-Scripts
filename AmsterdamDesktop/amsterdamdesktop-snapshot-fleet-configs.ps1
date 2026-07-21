# amsterdamdesktop-snapshot-fleet-configs.ps1
# Created 2026-07-21; hardened 2026-07-21.
# Exports this box's fleet Task Scheduler tasks into the fleet-configs repo snapshot.
# Manual-run; review `git diff` and commit.
#
# Task list = existing TaskSched\*.xml (the curated set: Cloudflared, OpenWebUI,
# Flask*, Fleet Checker/status, HeartbeatWriter) + any task DISCOVERED by its action
# running the fleet writer/metrics/heartbeat. We match on the action, not the task
# name, so a display name with spaces (e.g. "Fleet Metrics Server") is found fine.
#
# Hardened: one stale or protected task never aborts the run.
#   - Do NOT set $ErrorActionPreference='Stop' -- it turns schtasks' stderr into a
#     terminating error and kills the loop.
#   - Each export is wrapped and checks $LASTEXITCODE, so a stale XML name (no such
#     task) or a protected task ("Access is denied", e.g. OpenWebUI) is skipped with
#     a warning instead of crashing.
# NOTE: amsterdamdesktop's repos live on D:\ -- the repo probe handles that.

$Machine = "AmsterdamDesktop"    # fleet-configs folder name for this box

$repoRoot = @("D:\repos", "C:\repos", "$env:USERPROFILE\repos") |
            Where-Object { Test-Path "$_\fleet-configs" } | Select-Object -First 1
if (-not $repoRoot) { Write-Error "fleet-configs repo not found under D:\repos, C:\repos, or ~\repos"; return }

$dest = Join-Path $repoRoot "fleet-configs\$Machine\TaskSched"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Build the wanted task-name list (existing XMLs + discovered-by-action), de-duped.
$wanted = [System.Collections.Generic.List[string]]::new()
Get-ChildItem $dest -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $wanted.Add($_.BaseName) }
Get-ScheduledTask | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'fleet[-_ ]?metrics[-_ ]?server|fleet[-_ ]?monitor|heartbeat[-_ ]?writer|run[-_ ]?hidden'
} | ForEach-Object { $wanted.Add($_.TaskName) }
$wanted = @($wanted | Select-Object -Unique)

Write-Host "Tasks to export:"; $wanted | ForEach-Object { Write-Host "  [$_]" }; Write-Host ""

foreach ($t in $wanted) {
    $out = Join-Path $dest "$t.xml"
    try {
        $xml = & schtasks /Query /TN "\$t" /XML 2>$null
        if ($LASTEXITCODE -eq 0 -and $xml) {
            $xml | Out-File -FilePath $out -Encoding Unicode   # UTF-16, as schtasks /Create /XML requires
            Write-Host "exported: $t"
        } else {
            Write-Warning "skipped '$t' (missing, protected, or inaccessible -- exit $LASTEXITCODE; try an elevated shell)"
        }
    } catch {
        Write-Warning "skipped '$t' ($($_.Exception.Message))"
    }
}

Write-Host "`nSnapshot complete. Review: cd $repoRoot\fleet-configs ; git status"
