# Prompt for Claude session on mmm (Mathes-Mac-mini)

Paste/point a Claude Code session on the Mac mini at this file. Context:
moving the OneDrive heartbeat writer from a `.zshrc` starter to a launchd
LaunchAgent, matching denniss-macbook-air's 2026-07-16 setup. General
background in `MIGRATION.md` (same dir) — but the mini differs from the
other Macs in ways that change the steps, so follow THIS file.

## Scope: heartbeat only

This Mac has NO Ollama (no app, nothing on 11434) and should not get one.
It also should NOT run the search_adv GUI or travel HTTP servers — so do
not run `./install.sh`; install only the heartbeat plist, by hand.

## How the mini differs (verified remotely 2026-07-16)

- **No `~/repos/scripts` clone exists.** The heartbeat script is a
  standalone copy at `~/onedrive_heartbeat_writer_all_macs.py` — verified
  byte-identical to the repo's `Status/` copy, so nothing is diverged.
- The `.zshrc` starter (lines 5–7) runs that home-dir copy and is
  currently working (heartbeat alive under framework Python 3.13).
- `/usr/bin/python3` exists (3.9.6) — fine, that's what the plist uses.

## Steps

1. **Clone the repo** (preferred, keeps the mini updatable):
   `mkdir -p ~/repos && git clone https://github.com/dennyrgood/scripts ~/repos/scripts`
   If cloning is undesirable, instead copy
   `com.dennis.heartbeat-writer.plist` over by hand and edit its script
   path to `/Users/dennishmathes/onedrive_heartbeat_writer_all_macs.py`.
2. **Stop the shell-started copy:**
   `pkill -f onedrive_heartbeat_writer_all_macs.py`
3. **Install the heartbeat plist only:**
   ```bash
   cp ~/repos/scripts/launchagents/com.dennis.heartbeat-writer.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist
   ```
   The plist runs the repo copy (`~/repos/scripts/Status/...`) with
   `/usr/bin/python3`, cwd `~/repos/scripts/Status`, logs to
   `~/Library/Logs/heartbeat_writer.log`, `PYTHONUNBUFFERED=1`. Paths
   assume user `dennishmathes` — true on the mini.
4. **Grant Full Disk Access to `/usr/bin/python3`** (manual, System
   Settings → Privacy & Security → Full Disk Access → + → ⌘⇧G →
   `/usr/bin/python3`), then:
   `launchctl kickstart -k gui/$(id -u)/com.dennis.heartbeat-writer`
   Without this, every OneDrive write fails `Operation not permitted`
   while the agent looks "running" — check the log, not `launchctl list`.
5. **Verify:** no errors in `tail ~/Library/Logs/heartbeat_writer.log`,
   and a fresh mtime on
   `~/OneDrive/_sync_monitor/$(hostname -s)/heartbeat_$(hostname -s).txt`
   — note the script derives the folder from the hostname; confirm which
   `_sync_monitor` subfolder the mini actually writes (the fleet dir also
   holds Bekah/GC writers; don't touch those).
6. **Retire the old starter:** comment out (don't delete) the `.zshrc`
   block (lines 5–7), noting the LaunchAgent replaces it. Once the agent
   is verified, the home-dir script copy `~/onedrive_heartbeat_writer_all_macs.py`
   is redundant — leave it as rollback insurance for now.

## Done when

- `com.dennis.heartbeat-writer` running with clean log (no TCC errors),
  heartbeat file mtime fresh, `.zshrc` starter commented out, and it
  survives a reboot (RunAtLoad) without any terminal being opened.
