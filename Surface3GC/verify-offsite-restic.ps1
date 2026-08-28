# verify-offsite-restic.ps1 -- manual verification of the off-site Immich restic
# copy held on this machine (s3g). Read-only except for a scratch restore.
# Created: 2026-08-28. See WorkBenchUnix/OFFSITE_BACKUP.md on wbu.
#
# Run occasionally, not on a schedule -- wbu already verifies the repo nightly
# and confirms replication after every backup. What this adds is proof that the
# copy HERE opens and gives files back, independently of anything wbu believes.
#
# NOTE: restic takes an exclusive lock, so Syncthing will flag a "Locally
# Changed Item" while this runs. Harmless -- /locks is in .stignore and never
# syncs back. It clears when restic exits.

$ErrorActionPreference = "Stop"

$env:RESTIC_REPOSITORY = "D:\Immich"     # set once, so -r is not repeated
$restic  = "D:\Scripts\restic.exe"
$scratch = "D:\rtest"
$sample  = "/mnt/immich-data/immich/images/profile"

function Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}
function Wait-Next { Read-Host "Press Enter to continue" | Out-Null }

# Prompt once and keep the passphrase in this process only. It is never written
# to disk: the whole point of the off-site design is that s3g holds ciphertext
# and no key, so a stolen machine yields nothing.
$sec = Read-Host "restic passphrase" -AsSecureString
$env:RESTIC_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

try {
    Step "Snapshots -- does the repo open at all?"
    & $restic snapshots
    Wait-Next

    Step "Integrity -- is every referenced pack present?"
    # Structure only. `check --read-data` re-hashes all 85 GiB and takes hours
    # on this hardware; worth running by hand occasionally, not here.
    & $restic check
    Wait-Next

    Step "Database dumps present?"
    & $restic ls latest /mnt/immich-data/immich/postgres-dumps-latest
    Wait-Next

    Step "Restore a sample to $scratch"
    # Clear first, not after. If a previous run was interrupted, restoring over
    # leftovers would show stale files and look like success.
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
    & $restic restore latest -i $sample --target $scratch

    Step "What came back"
    Get-ChildItem $scratch -Recurse -File |
        Select-Object Length, LastWriteTime, FullName | Format-List
    Write-Host "Open one of the files above to confirm it is genuinely readable." -ForegroundColor Yellow
    Wait-Next
}
finally {
    # Always runs, including on Ctrl-C or an error partway through, so the
    # scratch copy and the passphrase never outlive the script.
    if (Test-Path $scratch) {
        Remove-Item $scratch -Recurse -Force
        Write-Host "cleaned up $scratch"
    }
    Remove-Item Env:\RESTIC_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Verification complete." -ForegroundColor Green
