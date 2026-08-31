# TestMailWindowsMachines.ps1
# 2026-08-31 UTC -- created
#
# Generic, machine-agnostic iCloud SMTP smoke test for any Windows fleet box. Run this
# directly (no per-machine Send-FleetMail.ps1 needed) whenever you just want to confirm
# "does mail work from THIS box right now" -- e.g. to check if the 2026-08-31 credential-
# typo class of failure (see icloud-smtp-typo-not-mystery memory) has recurred, or when
# setting up a new box before its own <alias>-health-monitor.ps1/Send-FleetMail.ps1 exist.
#
# This is a self-contained copy of Send-FleetMail's logic (not a dot-sourced dependency)
# so it works standalone from the repo root on any box, using whatever credential that
# box already has at %LOCALAPPDATA%\fleet-scripts\icloud-mail-cred.xml (created via
# Setup-IcloudMailCredential.ps1, copies of which live in each scripts\<Machine>\ folder).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File TestMailWindowsMachines.ps1
#
# ASCII only -- PowerShell 5.1 has no BOM handling and mis-decodes non-ASCII (CLAUDE.md).

$ErrorActionPreference = "Stop"

$FleetMailTo = "dennyrgood@yahoo.com"
$FleetMailFrom = "dennis.mathes@icloud.com"
$FleetMailSmtpServer = "smtp.mail.me.com"
$FleetMailSmtpPort = 587
$FleetMailCredPath = Join-Path $env:LOCALAPPDATA "fleet-scripts\icloud-mail-cred.xml"

$hostName = $env:COMPUTERNAME
Write-Host "Testing iCloud SMTP mail from: $hostName"
Write-Host "Credential path: $FleetMailCredPath"
Write-Host ""

if (-not (Test-Path $FleetMailCredPath)) {
    Write-Host "FAILED: no credential file found. Run Setup-IcloudMailCredential.ps1 first" -ForegroundColor Red
    Write-Host "(a copy lives in each scripts\<Machine>\ folder, or copy one over)."
    exit 1
}

try {
    $cred = Import-Clixml -Path $FleetMailCredPath
} catch {
    Write-Host "FAILED to decrypt credential: $_" -ForegroundColor Red
    Write-Host "If this is a fresh box or the credential was regenerated elsewhere, re-run"
    Write-Host "Setup-IcloudMailCredential.ps1 on THIS box (DPAPI keys are per-machine)."
    exit 1
}

Write-Host "Credential username: $($cred.UserName)"
if ($cred.UserName -notmatch '@icloud\.com$') {
    Write-Host "WARNING: username does not end in @icloud.com -- check for a typo (.net vs .com)" -ForegroundColor Yellow
}
Write-Host ""

try {
    # -Encoding is required: without it, Send-MailMessage mangles non-ASCII characters
    # (confirmed 2026-08-31 -- see AmsterdamDesktop/Send-FleetMail.ps1 for the same note).
    Send-MailMessage `
        -From $FleetMailFrom `
        -To $FleetMailTo `
        -Subject "[$hostName] TestMailWindowsMachines -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -Body "Generic mail test from $hostName via TestMailWindowsMachines.ps1 (repo root). If you got this, iCloud SMTP works from this box right now." `
        -Encoding ([System.Text.Encoding]::UTF8) `
        -SmtpServer $FleetMailSmtpServer `
        -Port $FleetMailSmtpPort `
        -UseSsl `
        -Credential $cred `
        -ErrorAction Stop
    Write-Host "SUCCESS: mail sent. Check $FleetMailTo." -ForegroundColor Green
} catch {
    Write-Host "FAILED: $_" -ForegroundColor Red
    exit 1
}
