# How to roll out health-monitor + nightly-summary to a Windows fleet box

Playbook validated end-to-end on `amsterdamdesktop` and `chatworkhorse` (2026-08-31).
Follow this order for each remaining box (ib, tb, rws, s3g, surfacegolaptopgc/sgc) —
skipping steps or doing them out of order is what caused both false-start failures
below, so read "Failure modes hit" before you improvise.

## Order of operations (do not reorder)

1. **Probe the box's real services** — don't assume, don't copy another box's list.
   `Get-ScheduledTask` (non-Microsoft tasks), `Get-NetTCPConnection -State Listen`,
   and `Get-CimInstance Win32_Process | Select CommandLine` to map port -> real
   script -> real task name. amsdt and cwh both had Flask/service ports that did NOT
   match assumptions from a first pass — always confirm each `app.run(port=...)` (or
   equivalent) by reading the actual script, not by guessing from context.
2. **Write `<box>-health-monitor.ps1` + `<box>-nightly-summary.ps1`** in
   `scripts/<Machine>/`, plus that folder's own copy of `Send-FleetMail.ps1` (it
   dot-sources via `$PSScriptRoot`, so every machine folder needs its own copy — same
   content, just copy it over). Model on `AmsterdamDesktop/amsdt-*.ps1` or
   `ChatWorkHorse/cwh-*.ps1`.
3. **Mail credential**: confirm `Setup-IcloudMailCredential.ps1` has been run on that
   box already (as of 2026-08-31 the user has run it on all boxes). If not, that's a
   blocking prerequisite — do it before anything else (see that script's own header).
4. **Test the scripts by scp'ing them somewhere temporary** (e.g. the account's home
   dir) and running directly over ssh — `powershell -NoProfile -ExecutionPolicy
   Bypass -File <script>.ps1` — to shake out syntax errors and confirm real mail
   delivery BEFORE wiring up Task Scheduler. This is fast iteration; don't skip to
   Task Scheduler with an untested script.
5. **Commit + push the finished, tested scripts** (user does this — never auto-commit
   per CLAUDE.md). Confirm the commit is real: `git log -1 --oneline` on the Mac side.
6. **`git pull` on the target box, in its real repo checkout**
   (`C:\repos\scripts\<Machine>\` on every box except amsdt, which uses `D:\repos`).
   **Verify the file actually landed** before touching Task Scheduler:
   ```
   Test-Path C:\repos\scripts\<Machine>\<box>-health-monitor.ps1
   ```
   This step is the one both false starts skipped straight past — see below.
7. **Only now create the Task Scheduler tasks**, and only pointed at the repo
   checkout path (`C:\repos\scripts\<Machine>\...`), never at a home-directory test
   copy. See "Creating the tasks" below.
8. **Verify**: `schtasks /Run /TN "<name>"`, then `schtasks /Query /TN "<name>" /V
   /FO LIST` and check `Last Result: 0`. For Health Monitor, also confirm the state
   file's `LastWriteTime` actually advanced (proves the script body ran, not just
   that PowerShell started and exited early).

## Failure modes hit on amsdt/cwh (why the order above matters)

- **Emoji/checkmarks arrived as `??`** — `Send-MailMessage` needs `-Encoding
  ([System.Text.Encoding]::UTF8)` explicitly or it mangles non-ASCII body/subject
  text. Already fixed in `Send-FleetMail.ps1` — just make sure every box's copy has
  it (compare against `AmsterdamDesktop/Send-FleetMail.ps1`).
- **`schtasks /Create /XML` failed with "The user name or password is incorrect"**
  even from an elevated prompt, with the exact same `<Principal>` block a working
  GUI-created task used. Cause: `schtasks /Create /XML` does NOT interactively
  prompt for the account password the way the GUI wizard does when the task needs
  "run whether logged on or not" (`LogonType=Password`). You must pass `/RU` and
  `/RP` explicitly on the command line:
  ```
  schtasks /Create /TN "Health Monitor" /XML health-monitor-task.xml /RU "<Machine>\<user>" /RP "<password>"
  ```
  Use the box's own SID (`([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value`)
  in the XML's `<UserId>` if you're templating from another box's exported XML — text
  `Domain\user` form also works once `/RU`/`/RP` are supplied, but matching an
  already-working task's exact SID is the safest template.
- **Task created fine, ran, `Last Result: -196608` (0xFFFD0000), state file never
  updated** — the Action pointed at `C:\repos\scripts\<Machine>\<script>.ps1`, but
  the script had only ever been `scp`'d to the account's home directory
  (`C:\Users\<user>\`) for testing, never committed/pulled into the real repo
  checkout. Task Scheduler silently fails to launch a script that isn't at the path
  its Action names — no error dialog, just a bad exit code. This is why step 6 above
  (verify `Test-Path` before creating tasks) exists: catch this before wasting a
  round-trip on "task ran but did nothing."

## Creating the tasks (XML + schtasks, not the GUI wizard)

Template both tasks off `AmsterdamDesktop`'s or `ChatWorkHorse`'s exported XML
(`schtasks /Query /TN "Health Monitor" /XML` from an already-working box), swapping:
- `<UserId>` — target box's own SID
- `<Arguments>` / `<WorkingDirectory>` — target box's repo path + script name
- `<StartBoundary>` — any near-future timestamp is fine, the trigger recurs
- Health Monitor: `<Repetition><Interval>PT5M</Interval></Repetition>`, `Indefinitely`
- Nightly Summary: no `<Repetition>` block, `<StartBoundary>` time = 07:00:00 local

Save as **UTF-16 with BOM** (required by `schtasks /Create /XML` — UTF-8 is
silently rejected). From macOS:
```
printf '\xFF\xFE' > task-utf16.xml
iconv -f UTF-8 -t UTF-16LE task-utf8.xml >> task-utf16.xml
```

Import (elevated PowerShell on the box, password required — see failure mode above):
```
schtasks /Create /TN "Health Monitor" /XML health-monitor-task.xml /RU "<Machine>\<user>" /RP "<password>"
schtasks /Create /TN "Nightly Summary" /XML nightly-summary-task.xml /RU "<Machine>\<user>" /RP "<password>"
```

Task naming matches the fleet convention already on each box (Title Case with
spaces, no machine-alias prefix — `Health Monitor` / `Nightly Summary`, matching
`Fleet Checker`, `Fleet Metrics Server`, `OpenWebUI`, etc.), not the script's
hyphenated filename.
