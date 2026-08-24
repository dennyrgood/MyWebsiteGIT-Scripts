# launchdaemons — root-level launchd jobs (macOS)

Sibling to `../launchagents/`. That directory covers **LaunchAgents**: `gui/$UID`
domain, run as the logged-in user, only while someone is logged in. This
directory covers **LaunchDaemons**: `system` domain, root, running whether or
not anyone is logged in, loaded at boot. Use this one when the job needs to
survive no-one-logged-in or needs root privilege for its whole lifetime, not
just at launch.

## Daemons

| Label | What it runs | Log |
|---|---|---|
| `com.dennis.mmm-nut-upsmon` | `mmm-nut-upsmon-start.sh` (this dir), which wraps `upsmon` (NUT) — netclient monitoring `ups0@192.168.178.123` on the NAS, root the whole time so its `SHUTDOWNCMD` (`/sbin/shutdown -h now`) can actually fire | `/Library/Logs/mmm_nut_upsmon.log` |

`mmm-nut-upsmon-start.sh` exists because of a real 2026-08-24 incident: after a
reboot, `upsmon` failed to start for ~10 minutes (60 consecutive "already
running" errors in the log) even though no other instance existed — a PID
file survived from before the reboot, and `upsmon`'s own check only tests
whether that PID *number* is alive, not whether it's actually `upsmon`. Early
in a fresh boot, low PIDs get reused fast, so the stale number collided with
an unrelated process. The wrapper checks whether the recorded PID is a real
`upsmon` before removing the file — a genuine second instance is left alone,
never blindly deleted out from under it. See the script's own header for the
full incident writeup.

Config lives outside this repo, at `/opt/homebrew/etc/nut/upsmon.conf`
(root:wheel, mode 600 — it holds the NAS monitoring password). See the
UPS/NUT setup guide, Section 7, for why: credentials never go in this repo.

## Why a LaunchDaemon and not `brew services start nut`

`brew services start nut` runs in the `gui/$UID` domain as whichever user
invoked it — fine for polling, but `SHUTDOWNCMD` needs root, and a
non-root `upsmon` will poll happily forever and silently never shut the
machine down. A LaunchDaemon is the only way to get root for the daemon's
entire run on macOS.

## Install / update / remove

```bash
cd ~/repos/scripts/launchdaemons
sudo ./install.sh              # install or reload
sudo ./install.sh --uninstall  # stop and remove
```

Re-run after editing the plist — it boots out the old copy first.

## Day-to-day

```bash
# is it running?
sudo launchctl print system/com.dennis.mmm-nut-upsmon | head -20

# restart after a config change (e.g. edited upsmon.conf)
sudo launchctl kickstart -k system/com.dennis.mmm-nut-upsmon

# stop until next boot / reinstall
sudo launchctl bootout system/com.dennis.mmm-nut-upsmon

# watch the log
tail -f /Library/Logs/mmm_nut_upsmon.log
```

## Caveats

- **PATH trap.** `ProgramArguments` uses `/opt/homebrew/sbin/upsmon`, not
  `upsmon` — a system LaunchDaemon's environment does not include
  `/opt/homebrew` on `PATH`. A plist relying on bare command names fails
  silently: launchd reports nothing wrong, the process just never starts.
- **Plist ownership.** launchd silently refuses to load a `/Library/LaunchDaemons`
  plist unless it's owned `root:wheel` and not group/world-writable.
  `install.sh` enforces this every run; a manual `cp` without the matching
  `chown`/`chmod` will look installed and do nothing.
- **Absence of errors is not confirmation.** Check the log and
  `launchctl print` after every change — don't infer success from launchd
  not complaining.
