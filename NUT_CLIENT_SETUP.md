# NUT client setup — ImageBeast, ChatWorkhorse, ChatWorkhorseUnix

Created 2026-08-04. Companion to *UPS & NUT Setup Guide — Amsterdam v4* (Google Doc).
That document covers architecture and rationale; this one is the procedure.

WorkBenchUnix is the NUT server for UPS #2 and is already done. This covers the three
machines that still need clients.

## Shutdown ordering

Staggered so that dependants stop before what they depend on. Every machine on UPS #2
watches `ups2` on WorkBenchUnix — **not** the NAS, which is on a different UPS with a
much lighter load and a correspondingly slower discharge.

| Machine | Minutes on battery | Mechanism | Notes |
|---|---|---|---|
| **ChatWorkhorseUnix** (VM) | 5 | `upsmon` + `upssched` | Must be down before its host |
| **ImageBeast** | 8 | `ups-watch.ps1` | |
| **ChatWorkhorse** (host) | 8 | `ups-watch.ps1 -VMName` | Also *waits* for the VM to reach poweroff |
| WorkBenchUnix | 10 | `upsmon` + `upssched` | Already configured |

CWHU's 5 minutes gives a 3-minute margin before its host even begins. The host's wait
loop is the second line of defence — the margin makes it usually right, the wait makes
it guaranteed.

CWHU shuts *itself* down rather than being driven entirely from the host, so it still
stops cleanly if the host's scheduled task is broken or misconfigured.

---

## Why PowerShell rather than a NUT client on Windows

`ups-watch.ps1` speaks NUT's line protocol directly over TCP.

- **No NUT binaries to install.** NUT's Windows builds are sporadic and
  community-maintained; this needs no `upsc.exe`, no MSI, no USB driver.
- **No credentials on any Windows box.** `upsd` serves variable reads without
  authentication — only commands and `SET` need a login. The `monslave` account
  exists on WBU for a real `upsmon` client if one is ever wanted; it is not used here.
- **One script across the fleet.** The same file serves ImageBeast, ChatWorkhorse, and
  later AmsterdamDesktop and Laura's desktops (those point at the NAS instead).

The v4 guide recommends preferring a real `upsmon` client because only registered
clients participate in `HOSTSYNC`. **That no longer applies**: `HOSTSYNC` matters when
the primary is about to cut UPS output, and killpower is permanently disabled
fleet-wide because BIOS restore-on-AC-loss has never worked on these machines.

---

## ImageBeast

```powershell
C:\repos\scripts\ups-watch.ps1 -MinutesOnBattery 8
```

Dry run first — reads the UPS, logs, shuts down nothing:

```powershell
.\ups-watch.ps1 -MinutesOnBattery 8 -WhatIf
```

**Scheduled Task**

| Setting | Value |
|---|---|
| Triggers | **Two of them** — see the trap below. (1) At startup, (2) Daily. Both repeating every **1 minute**, indefinitely |
| Action | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\repos\scripts\ups-watch.ps1 -MinutesOnBattery 8` |
| Run as | SYSTEM or a local admin |
| Options | Run whether user is logged on or not |

One minute is the poll interval, not the countdown — the countdown is a timestamp in
`C:\ProgramData\ups-watch\`, so it survives the script exiting between runs.

### The boot-trigger trap — read this before trusting the task

A **startup trigger alone is not enough**, and it fails invisibly.

A `BootTrigger`'s repetition does not begin until the trigger actually fires. Create
the task on a running machine and nothing is scheduled until its next reboot — which
on a server may be months away. Meanwhile every indicator you would naturally check
reads healthy:

```
Scheduled Task State: Enabled     Status: Ready     Last Result: 0
Next Run Time:        N/A
```

**None of those four fields can tell you.** `Next Run Time` reads `N/A` for a
repetition-based schedule whether it is running or not — verified on ImageBeast
2026-08-29, N/A both while dead for 17 days and while polling correctly every minute.

This is exactly how ImageBeast sat through the 2026-08-29 full-outage test. Task
present, correctly configured, enabled, last result 0 — and never once scheduled,
because it was created on 2026-08-12 while the machine had been up since 2026-08-03.

Two consequences:

1. **Add a Daily trigger as well**, also repeating every 1 minute indefinitely. It
   makes the schedule independent of reboots and re-establishes itself every day, so
   the watchdog cannot be silently unscheduled for weeks.
2. **Verify that `Last Run Time` ADVANCES.** It is the only field that distinguishes
   a running schedule from a dead one. Sample it twice, ~90 seconds apart:

   ```
   schtasks /query /tn "UPS-Watch-ImageBeast" /fo LIST /v | findstr /i "last run"
   ```

   It must move forward by a minute between samples. A fixed timestamp — however old —
   means nothing is running, no matter what Status, Last Result or Next Run Time say.
   On ImageBeast it sat at `8/12/2026 1:19:39 AM` for 17 days while every other field
   read healthy.

   Do not check the log instead: on mains the script exits silently by design, so an
   empty log is indistinguishable from one that never ran.

---

## ChatWorkhorse

Same script, plus the VM:

```powershell
C:\repos\scripts\ups-watch.ps1 -MinutesOnBattery 8 -VMName ChatWorkhorseUnix
```

> ### The task must NOT run as SYSTEM
>
> VirtualBox VMs belong to the user who started them. A task running as SYSTEM cannot
> see or control a VM owned by `dhm` — `VBoxManage showvminfo` reports that it does not
> exist, the wait loop falls straight through, and Windows shuts down on top of a
> running VM with a live Postgres inside it.
>
> Run the task as **the VM's owner**, with *Run with highest privileges* and *Run
> whether user is logged on or not*.
>
> The script logs a specific error if this is wrong — check
> `C:\ProgramData\ups-watch\ups-watch.log` for "Is this task running as the VM's
> owner, not SYSTEM?" after the first trigger test.

**Verify VM control works before trusting any of it:**

```powershell
& "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe" showvminfo ChatWorkhorseUnix --machinereadable | Select-String VMState
```

Run that *as the account the task will use*. It must print a `VMState=` line.

Also set VirtualBox's host-shutdown behaviour for this VM to **ACPI shutdown**, not
"save state" — a saved state on a machine that subsequently loses power is worse than
a clean stop.

---

## ChatWorkhorseUnix

CWHU runs a warm-standby Immich stack with Postgres in Docker Compose
(`restore_from_wbu.sh` tears it down and replays the dump nightly). An ACPI power
button alone is **not** a clean stop: it triggers a normal systemd shutdown, where
`docker.service` stopping gives Compose its 10-second default and can SIGKILL Postgres
mid-checkpoint. That is exactly what `clean.ubuntu.shutdown` exists to prevent, and it
applies here as much as on WBU.

```bash
cd ~/repos/scripts && git pull
sudo bash ChatWorkhorseUnix/setup-nut-client.sh
```

It refuses to run on the wrong host, checks WBU is reachable on 3493, prompts for the
`monslave` password with `read -s` (never echoed, never a script argument), and
installs `upsmon` + `upssched` with the 5-minute timer.

Get the password on WBU with:

```bash
sudo grep -A1 monslave /etc/nut/upsd.users
```

`clean.ubuntu.shutdown` works unmodified on CWHU — it discovers Compose stacks from
container labels rather than hardcoded paths, and its header names both boxes.

---

## Verification

**Per machine, after setup:**

| Machine | Check |
|---|---|
| ImageBeast | `.\ups-watch.ps1 -WhatIf` logs a status line, no errors |
| ChatWorkhorse | as above, **plus** `VBoxManage showvminfo` works as the task's user |
| CWHU | `upsc ups2@192.168.178.242` returns data; no `ACCESS-DENIED` in `journalctl -u nut-monitor` |

**The notify path on CWHU cannot be tested locally.** A fresh `upsmon` start never
emits COMMOK — only a connection that drops and returns does, and CWHU has no local
`upsd` to bounce. Force it from the server:

```bash
# on WorkBenchUnix
sudo systemctl restart nut-server
# then on CWHU
journalctl -t upssched-cmd -n 5 --no-pager
```

A `SELFTEST` line means the timer will arm. No line means it will not.

**Full live test** — pull UPS #2's mains for under 5 minutes and watch:

```bash
journalctl -f -t nut-monitor -t upssched-cmd      # CWHU and WBU
```

Two `-t` flags OR together. Mixing `-u` and `-t` **ANDs** them and shows nothing —
this produced a false "the test didn't work" result during WBU's first test.

On Windows, tail `C:\ProgramData\ups-watch\ups-watch.log`.

Expect, in order: every box logs on-battery within seconds; nothing shuts down; on
replug every countdown cancels.

---

## Known limitations

- **`ups-watch.ps1` has never been executed.** It was written on Linux with no
  PowerShell available — not run, not syntax-checked. Treat the first `-WhatIf` run as
  the real test. (Same caveat as `sync-all.ps1`.)
- **Full shutdown is untested end to end** on every machine, WBU included. Everything
  up to the trigger is verified; the trigger firing for real is not.
- **No firewall backstop.** `ufw` is inactive on WBU, so `upsd` is reachable by
  anything on the LAN. Reads are unauthenticated by design; commands need the
  generated 24-character password. Nothing to configure — just don't assume a
  firewall is there.
- **CWHU's countdown depends on the network to WBU.** If the VM's networking is down,
  it gets no signal and only its host's wait loop protects it.
