**macOS Heartbeat Checker**

Final Solution --- Setup & Operations

Overview

The macOS heartbeat checker runs as a persistent background process,
started automatically each time a Terminal window opens. It loops
forever, checking the OneDrive heartbeat file every 5 minutes and firing
a desktop notification if sync appears stuck.

Getting this working on macOS required navigating significant platform
restrictions around background processes, notification permissions, and
file access. This document describes the final working solution.

What Didn\'t Work and Why

launchd

launchd is the standard macOS background process manager. It failed for
two reasons: macOS sandboxes launchd agents from the UI so notifications
were silently swallowed, and the Python binary launched by launchd was
denied access to the OneDrive folder due to macOS TCC (privacy)
restrictions.

cron

cron has the same sandbox problem as launchd on modern macOS ---
notifications from cron jobs are blocked.

Script Editor Login Item

Wrapping the script in a Script Editor .app and adding it as a Login
Item worked for notifications but caused two problems: Script Editor
appeared as a Dock icon (messy), and closing Script Editor killed the
process.

Finder Dialog

An AppleScript Finder dialog was added to get an in-your-face alert. It
worked from Terminal but caused AppleEvent timeout errors when running
in a loop over time.

nohup and disown

Both nohup and disown were tried to fully detach the process from the
Terminal session. Neither prevented the \'you have running jobs\'
warning from zsh when closing the Terminal window. They were dropped as
they added complexity without solving the problem.

Final Solution

Terminal Startup Command

Terminal Settings → Profiles → Shell tab → check Run command → paste:

> pgrep -qf heartbeat_checker \|\|
> /Users/dennishmathes/repos/scripts/onedrive_heartbeat_checker_macos.py
> &

Make sure Run inside shell is checked.

  -----------------------------------------------------------------------
  *The pgrep guard prevents multiple instances when multiple Terminal
  windows are open. pgrep finds sleeping processes, so the guard works
  correctly even while the script is between its 5-minute checks.*

  -----------------------------------------------------------------------

Known Limitation

The checker process is tied to the first Terminal window that launched
it. Closing that window will kill the process and show a \'you have
running jobs\' warning. The next Terminal window opened will restart it
automatically via the startup command.

  -----------------------------------------------------------------------
  *Practical workaround: don\'t close your first Terminal window. If you
  do, just open a new one and the checker restarts automatically.*

  -----------------------------------------------------------------------

Script Setup

The checker script must be executable with the correct shebang:

> \# Shebang at top of onedrive_heartbeat_checker_macos.py
> #!/Library/Frameworks/Python.framework/Versions/3.13/bin/python3
>
> \# Make it executable chmod +x
> /Users/dennishmathes/repos/scripts/onedrive_heartbeat_checker_macos.py

Python Binary

The checker must use a Python binary that has been granted file access
by macOS. Python 3.13 works:

> /Library/Frameworks/Python.framework/Versions/3.13/bin/python3

  -----------------------------------------------------------------------
  *The system Python at /usr/bin/python3 does NOT work --- it is denied
  access to the OneDrive folder by macOS privacy restrictions.*

  -----------------------------------------------------------------------

Notification Setup

Notifications use terminal-notifier with the full hardcoded path since
PATH is limited in the Terminal startup context:

> TERMINAL_NOTIFIER = \"/opt/homebrew/bin/terminal-notifier\"

Notification permissions in System Settings → Notifications → Terminal:

- Alert Style: Persistent

- Play sound for notification: On

Debug Commands

Is it running?

Use ps aux --- unlike pgrep it clearly shows sleeping processes and
which terminal session they belong to:

> ps aux \| grep heartbeat_checker

Expected output (ignore the grep line itself):

> dennishmathes 38961 0.0 0.1 \... s001 SN 12:32AM 0:00.05
> /Library/Developer/CommandLineTools/\.../Python
> /Users/dennishmathes/repos/scripts/onedrive_heartbeat_checker_macos.py

  -----------------------------------------------------------------------
  *The S or SN state means sleeping --- this is normal between checks. It
  does not mean the process is stuck or dead.*

  -----------------------------------------------------------------------

Quick running check (no output)

Returns exit code 0 if running, exit code 1 if not. No output either way
--- that is correct behavior for -q (quiet):

> pgrep -qf heartbeat_checker

To see the exit code explicitly:

> pgrep -qf heartbeat_checker; echo \$?

0 = running, 1 = not running.

Check for multiple instances

> pgrep -fl heartbeat_checker

Should show exactly one line. If more than one, kill all and restart:

> pkill -f heartbeat_checker
> /Users/dennishmathes/repos/scripts/onedrive_heartbeat_checker_macos.py
> &

Stop

> pkill -f heartbeat_checker

Test notifications

> \# Write stale timestamp --- should trigger alert within 5 minutes
> echo \"2026-02-19T00:00:00+00:00\" \>
> \~/OneDrive/\_sync_monitor/heartbeat_server.txt \# Write current
> timestamp --- clears the alert condition echo \"\$(date -u
> +%Y-%m-%dT%H:%M:%S+00:00)\" \>
> \~/OneDrive/\_sync_monitor/heartbeat_server.txt

Check error log

If the checker starts but immediately dies, check:

> cat /tmp/heartbeat_checker_err.log
