<#
    Shared functions for VM-stop logic used by both ups-watch.ps1 (the production
    UPS-driven shutdown watchdog) and ChatWorkHorse/TakeDown_VM.ps1 (a standalone
    manual trigger for the same VM-stop path). Factored out after TakeDown_VM.ps1
    and this logic briefly drifted out of sync with each other - see repo history
    around 2026-08-12.

    Callers must set $StateDir and $LogFile before dot-sourcing this file -
    Write-Log and Invoke-CleanShutdownViaSSH both write to $LogFile, and the
    latter also drops ssh-clean-shutdown.{out,err}.log under $StateDir.

    Contains ONLY function definitions - safe to dot-source (no top-level
    executable code, no `exit` calls that would terminate the caller's session).
#>

function Write-Log([string]$Message) {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") + "Z"
    $line  = "$stamp  $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

<#
    Triggers CWHU's own clean shutdown (docker compose stop, respecting
    depends_on order, then systemctl poweroff) over SSH, using a dedicated key
    restricted via a forced `command=` in authorized_keys to run ONLY
    clean.ubuntu.shutdown - nothing else, even if this key were compromised.

    Only ISSUES the shutdown; does not wait for it to complete. Caller still
    polls VBoxManage for the VM to actually reach poweroff - that confirms it
    worked, not this function's return value.

    Returns $true only if the trigger was successfully issued (SSH connected,
    remote command exited 0 - meaning clean.ubuntu.shutdown got as far as
    calling `systemctl poweroff` itself). Returns $false on anything else -
    unreachable host, sudo not permitted, a busy check inside the script
    refusing to run, etc. - so the caller falls back to ACPI. That fallback
    matters most exactly when it's least likely to help: if CWHU's guest
    networking is what's actually down, SSH cannot reach it either, so ACPI (a
    hypervisor-level signal, independent of guest networking) is the only thing
    left that can still get the VM down before the host loses power.

    Verified working end-to-end on ChatWorkhorse 2026-08-12: all 4 Immich
    containers (server, postgres, machine_learning, redis) exited 0, not 137.
#>
function Invoke-CleanShutdownViaSSH([string]$Name, [string]$User, [string]$KeyPath, [int]$TimeoutSeconds) {
    $ssh = Join-Path $env:SystemRoot "System32\OpenSSH\ssh.exe"
    if (-not (Test-Path $ssh))     { Write-Log "Clean-shutdown skipped: ssh.exe not found at $ssh."; return $false }
    if (-not (Test-Path $KeyPath)) { Write-Log "Clean-shutdown skipped: SSH key not found at $KeyPath."; return $false }

    $sshArgs = @(
        "-i", $KeyPath,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=$TimeoutSeconds",
        "$User@$Name",
        "true"   # ignored - the server's forced command overrides whatever we ask for
    )

    try {
        $proc = Start-Process -FilePath $ssh -ArgumentList $sshArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $StateDir "ssh-clean-shutdown.out.log") `
            -RedirectStandardError  (Join-Path $StateDir "ssh-clean-shutdown.err.log")
    }
    catch {
        Write-Log "Clean-shutdown SSH attempt failed to start: $($_.Exception.Message)"
        return $false
    }

    # Generous margin over -o ConnectTimeout: that only bounds the TCP handshake,
    # not the remote script's own runtime (docker compose stop can take up to its
    # STOP_TIMEOUT per container, 60s by default).
    if (-not $proc.WaitForExit(($TimeoutSeconds + 90) * 1000)) {
        Write-Log "WARNING: clean-shutdown SSH command did not return in time - killing it and falling back to ACPI."
        try { $proc.Kill() } catch { }
        return $false
    }

    if ($proc.ExitCode -ne 0) {
        Write-Log "Clean-shutdown SSH command exited $($proc.ExitCode) (see ssh-clean-shutdown.*.log) - falling back to ACPI."
        return $false
    }

    Write-Log "Clean-shutdown triggered successfully via SSH (docker compose stop, then poweroff issued)."
    return $true
}

<#
    Stops the VirtualBox VM and waits for it to actually reach poweroff.

    Tries Invoke-CleanShutdownViaSSH first (see above), falls back to a bare
    ACPI power button signal if that doesn't succeed. Waiting matters more than
    sending: CWHU runs a warm-standby Immich stack with Postgres in Docker, so
    its shutdown takes real time either way, and shutting Windows down mid-stop
    is precisely what this whole system exists to avoid. Returns $true if the
    VM is confirmed down.
#>
function Stop-VMAndWait([string]$Name, [int]$TimeoutSeconds, [string]$SSHUser, [string]$SSHKeyPath, [int]$SSHConnectTimeoutSeconds) {
    $vbox = Join-Path $env:ProgramFiles "Oracle\VirtualBox\VBoxManage.exe"
    if (-not (Test-Path $vbox)) {
        Write-Log "ERROR: VBoxManage not found at $vbox - cannot stop VM '$Name'."
        return $false
    }

    $info = & $vbox showvminfo $Name --machinereadable 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: cannot query VM '$Name' (exit $LASTEXITCODE). Is this task running as the VM's owner, not SYSTEM?"
        return $false
    }

    $state = ($info | Select-String '^VMState=') -replace 'VMState=', '' -replace '"', ''
    if ($state -match 'poweroff|aborted|saved') {
        Write-Log "VM '$Name' already down (state: $state)."
        return $true
    }

    # CWHU's own upsmon should already have shut it down five minutes ago. Try the
    # same clean, docker-compose-aware path it uses before falling back to a bare
    # ACPI signal - see Invoke-CleanShutdownViaSSH for why this matters (avoids
    # SIGKILLing Postgres mid-checkpoint) and why ACPI stays as the fallback
    # rather than the only mechanism (it doesn't depend on CWHU's guest
    # networking being up, unlike SSH).
    $clean = Invoke-CleanShutdownViaSSH -Name $Name -User $SSHUser -KeyPath $SSHKeyPath -TimeoutSeconds $SSHConnectTimeoutSeconds
    if (-not $clean) {
        Write-Log "VM '$Name' still running (state: $state) - sending ACPI power button."
        & $vbox controlvm $Name acpipowerbutton 2>&1 | Out-Null
    }

    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 5
        $waited += 5
        $info  = & $vbox showvminfo $Name --machinereadable 2>&1
        $state = ($info | Select-String '^VMState=') -replace 'VMState=', '' -replace '"', ''
        if ($state -match 'poweroff|aborted') {
            Write-Log "VM '$Name' reached '$state' after ${waited}s."
            return $true
        }
    }

    # Deliberately does NOT `controlvm poweroff`. That is equivalent to yanking the
    # VM's power cord and would corrupt exactly what the wait was protecting. Better
    # to shut Windows down and let the hypervisor's own stop handling take over.
    Write-Log "WARNING: VM '$Name' still '$state' after ${TimeoutSeconds}s - proceeding anyway."
    return $false
}
