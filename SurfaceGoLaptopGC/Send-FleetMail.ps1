# AmsterdamDesktop\Send-FleetMail.ps1
# 2026-08-31 UTC -- created
#
# Shared mail-sending function for this box's health-monitor / nightly-summary
# scripts. Windows equivalent of the Mac/Ubuntu boxes' `msmtp --account=icloud`
# call. Dot-source this file, then call Send-FleetMail.
#
# Credential comes from Setup-IcloudMailCredential.ps1 (run once per box, per
# account) -- see that script for why the cred file lives outside the repo
# and can't be copied between boxes.
#
# NOTE ON Send-MailMessage: it's marked Obsolete by Microsoft (no TLS 1.2
# guarantee, no modern auth) but still functional in Windows PowerShell 5.1,
# which is what every box in this fleet runs (per CLAUDE.md). iCloud's SMTP
# (smtp.mail.me.com:587, STARTTLS) works fine with it as of this writing.
# If it's ever retired, swap the body of Send-FleetMail for a System.Net.Mail
# call directly -- callers don't need to change.
#
# Usage (from another script):
#   . "$PSScriptRoot\Send-FleetMail.ps1"
#   Send-FleetMail -Subject "[amsterdamdesktop] HEALTH ALERT" -Body $alertBody
#
# Standalone smoke test:
#   powershell -NoProfile -ExecutionPolicy Bypass -File Send-FleetMail.ps1 -Test

param(
    [switch]$Test
)

$Script:FleetMailTo = "dennyrgood@yahoo.com"
$Script:FleetMailFrom = "dennis.mathes@icloud.com"
$Script:FleetMailSmtpServer = "smtp.mail.me.com"
$Script:FleetMailSmtpPort = 587
$Script:FleetMailCredPath = Join-Path $env:LOCALAPPDATA "fleet-scripts\icloud-mail-cred.xml"

function Send-FleetMail {
    param(
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$Body
    )

    if (-not (Test-Path $Script:FleetMailCredPath)) {
        Write-Warning "No mail credential at $($Script:FleetMailCredPath) -- run Setup-IcloudMailCredential.ps1 first. Alert NOT sent: $Subject"
        return $false
    }

    try {
        $cred = Import-Clixml -Path $Script:FleetMailCredPath
    } catch {
        Write-Warning "Failed to read/decrypt mail credential (wrong account/machine?): $_. Alert NOT sent: $Subject"
        return $false
    }

    try {
        # -Encoding is required: without it, Send-MailMessage picks an encoding that
        # mangles non-ASCII characters (confirmed 2026-08-31 -- the checkmark/warning
        # glyphs in amsdt-nightly-summary.ps1's subject/body arrived as "??" at the
        # recipient until this was added).
        Send-MailMessage `
            -From $Script:FleetMailFrom `
            -To $Script:FleetMailTo `
            -Subject $Subject `
            -Body $Body `
            -Encoding ([System.Text.Encoding]::UTF8) `
            -SmtpServer $Script:FleetMailSmtpServer `
            -Port $Script:FleetMailSmtpPort `
            -UseSsl `
            -Credential $cred `
            -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Send-MailMessage failed: $_. Alert NOT sent: $Subject"
        return $false
    }
}

if ($Test) {
    $host_name = $env:COMPUTERNAME
    $ok = Send-FleetMail -Subject "[$host_name] Send-FleetMail test -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
                          -Body "This is a test message from Send-FleetMail.ps1 -Test on $host_name. If you got this, the iCloud SMTP path from Windows works."
    if ($ok) {
        Write-Host "Test mail sent. Check dennyrgood@yahoo.com."
    } else {
        Write-Host "Test mail FAILED -- see warning above."
        exit 1
    }
}
