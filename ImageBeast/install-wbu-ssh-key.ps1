<#
.SYNOPSIS
    Authorises WorkBenchUnix to SSH into this machine with a key, so no password
    is ever typed or transcribed.

.DESCRIPTION
    Created: 2026-08-29 UTC.

    Run ELEVATED on ImageBeast:   powershell -ExecutionPolicy Bypass -File .\ImageBeast\install-wbu-ssh-key.ps1

    WHY administrators_authorized_keys AND NOT ~/.ssh/authorized_keys:
    Windows OpenSSH treats any account in the local Administrators group specially.
    For those accounts sshd reads ONLY C:\ProgramData\ssh\administrators_authorized_keys
    and ignores the per-profile file entirely. IMAGEBEAST\Pc is the primary local
    account (SID ...-1000) and is an administrator, so a key placed in the profile
    would be silently ignored - the login just falls back to asking for a password,
    which looks identical to having installed nothing.

    The ACL reset is equally load-bearing. sshd refuses to read this file if anything
    beyond Administrators and SYSTEM can write it, and it reports that only in its own
    log - the client just sees "Permission denied (publickey)".
#>
$ErrorActionPreference = "Stop"

$Key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINLACAojeEM0+uWNkKyb3IeDH9vH8w1tKmz5Rr6F7XLx wbu-to-imagebeast"
$File = "C:\ProgramData\ssh\administrators_authorized_keys"

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Must be run elevated (Run as Administrator)."
}

if (-not (Test-Path C:\ProgramData\ssh)) { New-Item -ItemType Directory -Path C:\ProgramData\ssh -Force | Out-Null }

# Idempotent: re-running must not append a second copy.
if ((Test-Path $File) -and (Select-String -Path $File -SimpleMatch -Pattern "wbu-to-imagebeast" -Quiet)) {
    Write-Host "Key already present - not appending again."
} else {
    Add-Content -Path $File -Value $Key
    Write-Host "Key appended to $File"
}

# UTF8 without BOM: a BOM on the first line makes sshd reject that key.
$content = Get-Content $File
[IO.File]::WriteAllLines($File, $content, (New-Object Text.UTF8Encoding $false))

icacls $File /inheritance:r | Out-Null
icacls $File /grant "Administrators:F" | Out-Null
icacls $File /grant "SYSTEM:F"         | Out-Null
Write-Host "ACLs restricted to Administrators + SYSTEM."

$svc = Get-Service sshd -ErrorAction SilentlyContinue
if ($null -eq $svc)            { Write-Host "WARNING: sshd service not found - is OpenSSH Server installed?" }
elseif ($svc.Status -ne "Running") { Write-Host "WARNING: sshd is $($svc.Status) - start it, and set StartupType Automatic." }
else                           { Write-Host "sshd is running." }

Write-Host ""
Write-Host "Test from WorkBenchUnix:  ssh imagebeast hostname"
