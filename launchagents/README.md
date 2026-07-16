# launchagents — auto-started local servers (macOS)

Repo-versioned launchd LaunchAgents for the personal HTTP servers that used
to be started by hand after every reboot. `install.sh` copies each plist
into `~/Library/LaunchAgents` and loads it; from then on the servers start
at every login, restart automatically if they crash, and log to files.

## Agents

| Label | What it runs | Port | Log |
|---|---|---|---|
| `com.dennis.search-adv-web` | search_adv web GUI (`search_adv/.venv` python, `search_adv_web.py`) | 5025 | `~/Library/Logs/search_adv_web.log` |
| `com.dennis.travel-http` | `python3 -m http.server` in `~/repos/dennyrgood.github.io/travel` | 5030 | `~/Library/Logs/travel_http.log` |
| `com.dennis.heartbeat-writer` | `Status/onedrive_heartbeat_writer_all_macs.py` (fleet heartbeat → OneDrive) | — | `~/Library/Logs/heartbeat_writer.log` |

Port notes: 5000 is taken by macOS AirPlay; travel deliberately sits at 5030
so the 8xxx range stays free for ad-hoc testing (the generic `start_http`
script at the repo root is unchanged for that).

To set up another Mac (heartbeat only, incl. the required Full Disk Access
grant), see `MIGRATION.md`.

## Install / update / remove

```bash
cd ~/repos/scripts/launchagents
./install.sh              # install or reload all agents (safe to re-run)
./install.sh --uninstall  # stop and remove all agents
```

Re-run `./install.sh` after editing a plist — it boots out the old copy
first. Adding a new server = drop another `.plist` in this dir and re-run.

## Day-to-day

```bash
# restart after a code change (replaces the old Ctrl-C / rerun cycle)
launchctl kickstart -k gui/501/com.dennis.search-adv-web

# stop until next login / reinstall
launchctl bootout gui/501/com.dennis.search-adv-web

# is it running?  (second column 0 = last exit was clean)
launchctl list | grep com.dennis

# watch a log
tail -f ~/Library/Logs/search_adv_web.log
```

(`501` is the uid on this Mac; `gui/$(id -u)` is the portable spelling.)

## Ollama (not an agent here)

The tray Ollama.app is the only Ollama server on this Mac. It binds
127.0.0.1; tailnet access is provided by a persistent Tailscale forward
(`tailscale serve --bg --tcp 11434 tcp://127.0.0.1:11434`, disable with
`tailscale serve --tcp=11434 off`). **Never `export OLLAMA_HOST` in shell
init files** — the tray app captures the shell environment and its server
will try to bind that address (a remote host's IP = permanent crash loop,
the 2026-07-16 "hosed install" that wasn't). Point the CLI at a remote
server with an alias instead (see `~/.zshrc`).

## Caveats

- The plists hardcode `/Users/dennishmathes` paths — Mac-specific. The
  Ubuntu equivalent would be systemd user units, not covered here.
- `KeepAlive` means a server that dies at startup (e.g. port already in
  use by a manually-started copy) will be retried in a loop — check the
  log and kill the manual copy rather than fighting launchd.
