# verify-restic-integrity-scheduled.ps1 -- unattended integrity check of the
# off-site Immich restic repo held on this machine.
# Created: 2026-08-28. Companion to WorkBenchUnix/OFFSITE_BACKUP.md on wbu.
#
# WHY THIS EXISTS
#   Syncthing verifies block hashes when files are TRANSFERRED, and re-hashes
#   only files whose size or mtime changed. It never re-reads unchanged files.
#   So a bit flipping on this disk next March would leave wbu's completion
#   figure reading 100% indefinitely. Only something reading the bytes HERE can
#   detect that, and nothing did.
#
# NO PASSPHRASE REQUIRED
#   Every file in a restic repo is named by the SHA-256 of its own contents --
#   packs, indexes, snapshots and keys alike (verified against the live repo on
#   2026-08-25). So integrity is checked by re-hashing each file and comparing
#   to its filename. No decryption, no key.
#
#   That matters. Running `restic check` here instead would mean storing the
#   passphrase next to the ciphertext, and the whole point of the off-site
#   design is that this machine holds data it cannot read: a stolen box or a
#   lost drive yields nothing. This check preserves that.
#
# WHAT IT DOES NOT COVER
#   Logical consistency -- whether every blob a snapshot references exists.
#   That is verified nightly on wbu, and Syncthing keeps the two sides
#   byte-identical, so the pair together is equivalent to a full restic check
#   at both ends.

$repo    = "D:\Immich"
$outDir  = "C:\fleet_monitor"     # served by fleet_metrics_server.py on :9100
$outFile = Join-Path $outDir "watchdog_restic-offsite_surface3-gc.json"

# Verify 1/12 of the repo per run. Monthly, that covers everything once a year
# while keeping each run to roughly 7 GiB -- tolerable on this hardware, where
# reading all 85 GiB would take hours. The slice is chosen from the file's own
# name, so successive months cover different files and all are eventually seen.
$buckets = 12
$bucket  = ([int](Get-Date).Month - 1) % $buckets

$started = Get-Date
$checked = 0; $mismatch = 0; $unreadable = 0
$badNames = New-Object System.Collections.Generic.List[string]

function Write-Result($ok, $note) {
    $r = [ordered]@{
        check          = "restic-offsite-integrity"
        host           = $env:COMPUTERNAME
        repo           = $repo
        ok             = $ok
        note           = $note
        bucket         = "$($bucket + 1)/$buckets"
        files_checked  = $checked
        mismatches     = $mismatch
        unreadable     = $unreadable
        bad_files      = @($badNames)
        started_utc    = $started.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        finished_utc   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        elapsed_sec    = [int]((Get-Date) - $started).TotalSeconds
    }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $r | ConvertTo-Json -Depth 4 | Set-Content -Path $outFile -Encoding UTF8
    Write-Host ($r | ConvertTo-Json -Depth 4)
}

try {
    if (-not (Test-Path $repo)) { Write-Result $false "repo path $repo not found"; exit 1 }
    # config is the one file NOT named by its content hash. Its absence means
    # this is not a restic repo, or the drive is not mounted where expected.
    if (-not (Test-Path (Join-Path $repo "config"))) {
        Write-Result $false "no restic config at $repo -- drive not mounted?"; exit 1
    }

    # Only the content-addressed trees. Deliberately excludes the repo root,
    # which holds Syncthing's .stfolder and .stignore.
    $dirs = @("data", "index", "snapshots", "keys") |
            ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ }

    foreach ($f in (Get-ChildItem -Path $dirs -Recurse -File -ErrorAction SilentlyContinue)) {
        $name = $f.Name
        # 64 lowercase hex characters. Anything else is not a restic object.
        if ($name.Length -ne 64) { continue }
        # Deterministic slice from the first byte of the object's own id.
        if (([Convert]::ToInt32($name.Substring(0, 2), 16) % $buckets) -ne $bucket) { continue }

        try {
            $h = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
        } catch {
            $unreadable++
            $badNames.Add("UNREADABLE $name")
            continue
        }
        $checked++
        if ($h -ne $name) {
            $mismatch++
            # Cap the list: if the drive is failing there could be thousands,
            # and this file is fetched over HTTP by the nightly summary.
            if ($badNames.Count -lt 25) { $badNames.Add($name) }
        }
    }

    if ($mismatch -gt 0 -or $unreadable -gt 0) {
        Write-Result $false "$mismatch corrupt, $unreadable unreadable of $checked checked"
        exit 1
    }
    Write-Result $true "$checked files verified, all hashes match"
} catch {
    Write-Result $false "check failed: $_"
    exit 1
}
