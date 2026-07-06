**OneDrive Sync Monitor**

Installation & Operations Guide

*February 2026*

# Overview

This system monitors OneDrive sync health across multiple machines in
different time zones. A dedicated Win11 server continuously writes a UTC
timestamp to a file inside the OneDrive folder. Client machines read
that file and alert if the timestamp becomes stale, indicating that sync
has stopped working.

The approach is a heartbeat: if the server\'s timestamp is more than 5
minutes old on a client machine, OneDrive has not synced the file
recently. Alerts fire as persistent desktop notifications.

## Components

  ------------------------------- --------------------------------------------
  **File**                        **Role**

  heartbeat_writer.py             Runs on Win11 server via Task Scheduler.
                                  Writes UTC timestamp to OneDrive every 5
                                  minutes. No dependencies --- pure Python
                                  stdlib.

  heartbeat_checker_windows.pyw   Runs on Win11 clients via Task Scheduler.
                                  Reads timestamp, alerts if stale.

  heartbeat_checker_macos.py      Runs on macOS clients as a Login Item. Loops
                                  forever, checks every 5 minutes.

  setup_checker_windows.ps1       One-time PowerShell script to register the
                                  Windows client Task Scheduler job.
  ------------------------------- --------------------------------------------

## Heartbeat File

All machines share one file inside OneDrive:

> OneDrive/\_sync_monitor/heartbeat_server.txt

Contents are a single UTC ISO timestamp, e.g.:

> 2026-02-19T14:32:00+00:00

  -----------------------------------------------------------------------
  *All timestamps are UTC. Time zones are irrelevant --- each machine
  compares the file\'s UTC timestamp against its own UTC clock.*

  -----------------------------------------------------------------------

# Server Setup --- heartbeat_writer.py

The writer is a simple Python loop that writes a fresh UTC timestamp
every 5 minutes and sleeps. No Flask, no web server, no firewall
configuration required. It runs as a Task Scheduler job on your
always-on Win11 server.

## Prerequisites

- Python 3.10+ --- no additional packages required

## Configuration

  ------------------- -----------------------------------------------------------
  **Setting**         **Notes**

  HEARTBEAT_FILE      Set to your actual OneDrive path. Must be a Path object,
                      e.g.
                      Path(\"D:/OneDrive/\_sync_monitor/heartbeat_server.txt\")

  WRITE_INTERVAL      300 --- seconds between writes (5 minutes).
  ------------------- -----------------------------------------------------------

  -----------------------------------------------------------------------
  *HEARTBEAT_FILE must be a Path object, not a plain string. The code
  calls .parent.mkdir() and .write_text() on it which are Path methods.
  Correct: HEARTBEAT_FILE =
  Path(\"D:/OneDrive/\_sync_monitor/heartbeat_server.txt\")*

  -----------------------------------------------------------------------

## Test Interactively First

Before setting up Task Scheduler, run the writer once from the command
line to confirm it works:

> d:\\Misc\\Python313\\python.exe
> d:\\repos\\scripts\\heartbeat_writer.py

You should see output like:

> Heartbeat writer running. Writing to:
> D:\\OneDrive\\\_sync_monitor\\heartbeat_server.txt
> \[2026-02-19T14:32:00+00:00\] Heartbeat written.

Press Ctrl+C to stop once confirmed, then proceed with Task Scheduler
setup.

## Install via Task Scheduler --- PowerShell

Kill any manually started instances first, then run this PowerShell
block to register the task:

> \# Kill any running instances first
>
> taskkill /f /im pythonw.exe
>
> \# Register the Task Scheduler job
>
> \$python = \"d:\\Misc\\Python313\\pythonw.exe\"
>
> \$script = \"d:\\repos\\scripts\\onedrive_heartbeat_writer.py\"
>
> \$action = New-ScheduledTaskAction -Execute \$python -Argument
> \"\`\"\$script\`\"\"
>
> \$trigger = New-ScheduledTaskTrigger -AtStartup
>
> \$settings = New-ScheduledTaskSettingsSet \`
>
> -ExecutionTimeLimit (New-TimeSpan -Hours 0) \`
>
> -MultipleInstances IgnoreNew \`
>
> -StartWhenAvailable
>
> \$principal = New-ScheduledTaskPrincipal \`
>
> -UserId \$env:USERNAME \`
>
> -LogonType Interactive \`
>
> -RunLevel Limited
>
> Register-ScheduledTask \`
>
> -TaskName \"HeartbeatWriter\" \`
>
> -Action \$action \`
>
> -Trigger \$trigger \`
>
> -Settings \$settings \`
>
> -Principal \$principal \`
>
> -Description \"Writes OneDrive heartbeat timestamp every 5 minutes\"
> \`
>
> -Force

  -----------------------------------------------------------------------
  *MultipleInstances IgnoreNew is critical --- it prevents Task Scheduler
  from spawning additional instances if the task is already running.
  Without this you can end up with multiple writers all updating the
  file, causing it to update more frequently than every 5 minutes.*

  -----------------------------------------------------------------------

## Start and Verify

Start the task immediately without rebooting, then confirm only one
instance is running:

> \# Start it
>
> Start-ScheduledTask -TaskName \"HeartbeatWriter\"
>
> \# Confirm exactly one pythonw process for the writer
>
> Get-WmiObject Win32_Process \| Where-Object {\$\_.Name -eq
> \"pythonw.exe\"} \| Select-Object ProcessId, CommandLine
>
> \# Confirm the file is being written type
>
> \"D:\\OneDrive\\\_sync_monitor\\heartbeat_server.txt\"

Wait 5 minutes and run the type command again to confirm the timestamp
has updated.

## Diagnosing Multiple Instances

If the heartbeat file is updating more frequently than every 5 minutes,
you likely have multiple writer instances running. Check:

> Get-WmiObject Win32_Process \| Where-Object {\$\_.Name -eq
> \"pythonw.exe\"} \| Select-Object ProcessId, CommandLine

If you see more than one heartbeat_writer.py entry, kill them all and
restart via Task Scheduler:

> taskkill /f /im pythonw.exe Start-ScheduledTask -TaskName
> \"HeartbeatWriter\"

# Windows Client Setup --- heartbeat_checker_windows.pyw

The .pyw extension means no console window. Task Scheduler triggers it
every 5 minutes in your interactive user session so desktop
notifications are visible.

## Prerequisites

- Python 3.10+

- pip install plyer

  -----------------------------------------------------------------------
  *Install using the full path to ensure the correct Python environment:
  d:\\Misc\\Python313\\python.exe -m pip install plyer*

  -----------------------------------------------------------------------

## Configuration

  -------------------------- --------------------------------------------
  **Setting**                **Notes**

  ONEDRIVE_PATH              Hardcode to your actual OneDrive path. Do
                             not rely on auto-detection.

  STALE_THRESHOLD_MINUTES    5 --- alert if heartbeat is older than this
                             many minutes.
  -------------------------- --------------------------------------------

## Debug Interactively First

Before setting up Task Scheduler, verify the checker works by running it
with python.exe so any errors are visible:

> d:\\Misc\\Python313\\python.exe
> \"d:\\repos\\scripts\\onedrive_heartbeat_checker_windows.pyw\"

  -----------------------------------------------------------------------
  *pythonw.exe runs silently --- errors are invisible. Always debug with
  python.exe first, then Task Scheduler will use pythonw.exe for
  production.*

  -----------------------------------------------------------------------

## Installation via PowerShell Script

1.  Edit \$scriptPath at the top of setup_checker_windows.ps1 to point
    to where you saved the .pyw file.

2.  Open PowerShell and run:

> .\\setup_checker_windows.ps1

1.  The task runs every 5 minutes and at every logon.

  -----------------------------------------------------------------------
  *The task is registered with LogonType Interactive --- it runs in your
  logged-on user session so desktop notifications are visible. Do not
  change this to \'Run whether user is logged on or not\' or
  notifications will be silently swallowed.*

  -----------------------------------------------------------------------

## Testing

Write a stale timestamp then trigger the task manually:

> echo 2026-02-19T00:00:00+00:00 \>
> %USERPROFILE%\\OneDrive\\\_sync_monitor\\heartbeat_server.txt
>
> Start-ScheduledTask -TaskName \'OneDriveHeartbeatChecker\'

A Windows toast notification should appear within seconds.

# macOS Client Setup --- heartbeat_checker_macos.py

The macOS checker starts at login and loops forever, checking every 5
minutes. It uses terminal-notifier for persistent desktop notifications.

## Prerequisites

- Python 3 (pre-installed on macOS)

- Homebrew --- https://brew.sh

- terminal-notifier: brew install terminal-notifier

## Configuration

  ------------------- ---------------------------------------------------
  **Setting**         **Notes**

  ONEDRIVE_PATH       \~/OneDrive --- change if your folder has a
                      different name (e.g. OneDrive - Company).

  STALE_THRESHOLD     5 --- alert if heartbeat is older than this many
                      minutes.

  CHECK_INTERVAL      300 --- seconds between checks (5 minutes).
  ------------------- ---------------------------------------------------

## Notification Permissions

1.  Run this once from Terminal to register terminal-notifier with
    macOS:

> terminal-notifier -title \"Test\" -message \"Test\" -sender
> com.apple.Terminal

1.  Go to System Settings → Notifications → Terminal.

2.  Set Alert Style to Persistent.

3.  Enable Play sound for notification.

## Setup as a Login Item

macOS cannot run a .py file directly as a login item. Wrap it in a
Script Editor app.

1.  Open Script Editor (Applications → Utilities → Script Editor).

2.  Paste this one line, editing your username:

> do shell script \"/usr/bin/python3
> /Users/YOURUSERNAME/repos/scripts/onedrive_heartbeat_checker_macos.py\"

1.  File → Export → File Format: Application. Save as
    OneDriveMonitor.app (e.g. \~/Applications/).

2.  System Settings → General → Login Items → + → select
    OneDriveMonitor.app.

## Testing

Write a stale timestamp and run directly from Terminal:

> echo \"2026-02-19T00:00:00+00:00\" \>
> \~/OneDrive/\_sync_monitor/heartbeat_server.txt
>
> python3 \~/repos/scripts/onedrive_heartbeat_checker_macos.py

A persistent notification banner should appear immediately. Press Ctrl+C
to stop the loop when done testing.

To test the login item without rebooting:

> open \~/Applications/OneDriveMonitor.app

To verify it is running:

> pgrep -fl heartbeat_checker_macos

To stop it:

> pkill -f heartbeat_checker_macos

# Ongoing Operations

## Verifying Everything Is Running

  ------------------- ---------------------------------------------------
  **Machine**         **How to verify**

  Win11 Server        Task Scheduler → HeartbeatWriter → check Last Run
                      Time. Also confirm heartbeat_server.txt has a
                      recent timestamp.

  Win11 Client        Task Scheduler → OneDriveHeartbeatChecker → check
                      Last Run Time.

  macOS Client        Terminal: pgrep -fl heartbeat_checker_macos ---
                      should show a Python process.
  ------------------- ---------------------------------------------------

## What the Alerts Mean

  ------------------- ---------------------------------------------------
  **Alert**           **Meaning and Action**

  Heartbeat file not  File never arrived. Check OneDrive is running and
  found               \_sync_monitor is not excluded from selective sync.

  Heartbeat file is   File exists but has no content. Check
  empty               heartbeat_writer.py is running on the server.

  Sync appears stuck  Timestamp is stale. Restart OneDrive on this
                      machine and/or the server.

  Could not parse     File has unexpected content. Write a fresh UTC
  timestamp           timestamp manually.
  ------------------- ---------------------------------------------------

## Restarting OneDrive

### Windows

> taskkill /f /im OneDrive.exe && start OneDrive.exe

### macOS

> killall OneDrive && open -a OneDrive

## Stopping and Starting the Monitor

### Win11 Server

> Stop-ScheduledTask -TaskName \'HeartbeatWriter\' Start-ScheduledTask
> -TaskName \'HeartbeatWriter\'

### Win11 Client

> Stop-ScheduledTask -TaskName \'OneDriveHeartbeatChecker\'
> Start-ScheduledTask -TaskName \'OneDriveHeartbeatChecker\'

### macOS Client

> pkill -f heartbeat_checker_macos open
> \~/Applications/OneDriveMonitor.app

## Manual Test Commands

### Write a current timestamp (should NOT alert)

> \# macOS echo \"\$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\" \>
> \~/OneDrive/\_sync_monitor/heartbeat_server.txt
>
> \# Windows PowerShell \[DateTime\]::UtcNow.ToString(\'o\') \|
> Set-Content
> \"\$env:USERPROFILE\\OneDrive\\\_sync_monitor\\heartbeat_server.txt\"

### Write a stale timestamp (SHOULD alert)

> \# macOS echo \"2026-02-19T00:00:00+00:00\" \>
> \~/OneDrive/\_sync_monitor/heartbeat_server.txt
>
> \# Windows PowerShell \'2026-02-19T00:00:00+00:00\' \| Set-Content
> \"\$env:USERPROFILE\\OneDrive\\\_sync_monitor\\heartbeat_server.txt\"

## Tuning

If false positives are too frequent, increase STALE_THRESHOLD_MINUTES
(Windows) or STALE_THRESHOLD (macOS) to 10 minutes. This gives OneDrive
more breathing room on slow networks or after waking from sleep.

  -----------------------------------------------------------------------
  *The checker exits silently when the machine has no internet
  connection. You will not receive alerts when offline.*

  -----------------------------------------------------------------------
