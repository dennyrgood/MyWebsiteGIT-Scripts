# Prompt for Claude session on mmm (Mathes-Mac-mini)

Paste/point a Claude Code session on the Mac mini at this file. Context:
moving the OneDrive heartbeat writer from a `.zshrc` starter to a launchd
LaunchAgent, matching denniss-macbook-air's 2026-07-16 setup. General
background in the scripts repo's `launchagents/MIGRATION.md` — but the
mini deliberately has NO clone of the scripts repo and won't get one
(too many stale copies already), so this file is self-contained: the
plist to install is inlined below, adapted to the mini's paths.

## Scope: heartbeat only

This Mac has NO Ollama (no app, nothing on 11434) and should not get one.
It also should NOT run the search_adv GUI or travel HTTP servers.

## Mini specifics (verified remotely 2026-07-16)

- The heartbeat script is a standalone copy at
  `~/onedrive_heartbeat_writer_all_macs.py` — verified byte-identical to
  the repo's `Status/` copy, so it is current. It stays where it is; the
  plist below points at it.
- The `.zshrc` starter (lines 5–7) currently runs it and works.
- `/usr/bin/python3` exists (3.9.6) — what the plist uses.

## Steps

1. **Stop the shell-started copy:**
   `pkill -f onedrive_heartbeat_writer_all_macs.py`

2. **Write the plist** to
   `~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist`, exactly:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.dennis.heartbeat-writer</string>

       <key>ProgramArguments</key>
       <array>
           <string>/usr/bin/python3</string>
           <string>/Users/dennishmathes/onedrive_heartbeat_writer_all_macs.py</string>
       </array>

       <key>WorkingDirectory</key>
       <string>/Users/dennishmathes</string>

       <key>EnvironmentVariables</key>
       <dict>
           <key>PYTHONUNBUFFERED</key>
           <string>1</string>
       </dict>

       <key>RunAtLoad</key>
       <true/>
       <key>KeepAlive</key>
       <true/>

       <key>StandardOutPath</key>
       <string>/Users/dennishmathes/Library/Logs/heartbeat_writer.log</string>
       <key>StandardErrorPath</key>
       <string>/Users/dennishmathes/Library/Logs/heartbeat_writer.log</string>
   </dict>
   </plist>
   ```

   (Same as the repo's plist except ProgramArguments/WorkingDirectory
   point at the mini's home-dir script instead of a repo clone.)

3. **Load it:**
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist`

4. **Grant Full Disk Access to `/usr/bin/python3`** (manual, System
   Settings → Privacy & Security → Full Disk Access → + → ⌘⇧G →
   `/usr/bin/python3`), then:
   `launchctl kickstart -k gui/$(id -u)/com.dennis.heartbeat-writer`
   Without this, every OneDrive write fails `Operation not permitted`
   while the agent looks "running" — check the log, not `launchctl list`.
   (This is the step that bit on denniss-macbook-air.)

5. **Verify:** no errors in `tail ~/Library/Logs/heartbeat_writer.log`,
   and a fresh mtime on
   `~/OneDrive/_sync_monitor/$(hostname -s)/heartbeat_$(hostname -s).txt`
   — the script derives the folder from the hostname; confirm which
   `_sync_monitor` subfolder the mini actually writes (the fleet dir also
   holds Bekah/GC writers; don't touch those).

6. **Retire the old starter:** comment out (don't delete) the `.zshrc`
   block (lines 5–7), noting the LaunchAgent replaces it — keeps a
   one-uncomment rollback.

## Ongoing caveat (no repo clone here)

If `Status/onedrive_heartbeat_writer_all_macs.py` is ever changed in the
scripts repo, the mini's `~/onedrive_heartbeat_writer_all_macs.py` copy
must be updated by hand (scp from another Mac), then
`launchctl kickstart -k gui/$(id -u)/com.dennis.heartbeat-writer`.

## Done when

- `com.dennis.heartbeat-writer` running with clean log (no TCC errors),
  heartbeat file mtime fresh, `.zshrc` starter commented out, and it
  survives a reboot (RunAtLoad) without any terminal being opened.
