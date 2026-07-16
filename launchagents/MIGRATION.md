# Migrating the heartbeat writer from .zshrc to launchd

How the heartbeat starter was moved from a per-shell `.zshrc` hack to a
launchd LaunchAgent on denniss-macbook-air (2026-07-16), written up so the
same change can be made on the other Macs. The script itself
(`Status/onedrive_heartbeat_writer_all_macs.py`) is hostname-aware and
unchanged — only how it gets started changes.

## Why bother

- `.zshrc` only starts it when a terminal is opened; after a reboot the
  heartbeat is dead until the first shell. launchd starts it at login and
  restarts it if it crashes (`KeepAlive`).
- One canonical process instead of a pgrep guard racing across shells.

## The catch: macOS privacy (TCC) — this is the part that bites

When started from a shell, the script inherits Terminal's Full Disk
Access, so writing to `~/OneDrive/...` just works. Under launchd it runs
as bare `/usr/bin/python3` with **no** such grant, and OneDrive is a
protected File Provider location — every write fails with
`[Errno 1] Operation not permitted` while the process itself stays
"running" and looks healthy in `launchctl list`. This exactly happened on
the first migration attempt.

**Fix (one-time, per Mac, manual):** System Settings → Privacy & Security
→ Full Disk Access → `+` → ⌘⇧G → `/usr/bin/python3` → enable it. Open the
pane from a terminal with:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

## Steps

1. **Sync the repo** so `launchagents/` is present
   (`cd ~/repos/scripts && git pull`).

2. **Kill the shell-started copy** if one is running:

   ```bash
   pkill -f onedrive_heartbeat_writer_all_macs.py
   ```

3. **Install the agent.** `./install.sh` installs *every* plist in the
   dir — on a Mac that shouldn't run the search_adv GUI (5025) or the
   travel server (5030), install just the heartbeat plist by hand:

   ```bash
   cp ~/repos/scripts/launchagents/com.dennis.heartbeat-writer.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist
   ```

   (On a Mac that should run everything, `cd ~/repos/scripts/launchagents
   && ./install.sh` instead.)

   Note the plist hardcodes `/Users/dennishmathes` paths — fine as long
   as the account name matches; edit the copy in `~/Library/LaunchAgents`
   if not.

4. **Grant Full Disk Access to `/usr/bin/python3`** (see above), then
   restart the agent so the grant takes effect:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.dennis.heartbeat-writer
   ```

5. **Verify** — no `Operation not permitted` in the log, and the
   heartbeat file's mtime is fresh (hostname varies per Mac):

   ```bash
   tail -5 ~/Library/Logs/heartbeat_writer.log
   ls -l ~/OneDrive/_sync_monitor/$(hostname -s)/heartbeat_$(hostname -s).txt
   ```

6. **Retire the `.zshrc` starter** — delete the block, but keep it as a
   comment for easy rollback:

   ```zsh
   # Heartbeat writer is now a LaunchAgent (com.dennis.heartbeat-writer) —
   # see ~/repos/scripts/launchagents/. Old per-shell starter, kept for rollback:
   # pgrep -f onedrive_heartbeat_writer_all_macs.py >/dev/null || \
   #   nohup /usr/bin/python3 ~/repos/scripts/Status/onedrive_heartbeat_writer_all_macs.py \
   #   >> ~/Library/Logs/heartbeat_writer.log 2>&1 &
   ```

## Rollback

```bash
launchctl bootout gui/$(id -u)/com.dennis.heartbeat-writer
rm ~/Library/LaunchAgents/com.dennis.heartbeat-writer.plist
```

then uncomment the `.zshrc` block.

## Gotchas recap

- Agent "running" ≠ agent working — always check the log for TCC errors
  (step 5). `launchctl list` will happily show a clean state while every
  OneDrive write is being denied.
- A macOS update that replaces `/usr/bin/python3` (Xcode CLT stub) can
  invalidate the FDA grant; if heartbeats go stale after an OS update,
  re-check Full Disk Access first.
- Don't run `install.sh` blindly on the travel/secondary Macs — it would
  also start the search_adv web GUI and travel HTTP server there.
