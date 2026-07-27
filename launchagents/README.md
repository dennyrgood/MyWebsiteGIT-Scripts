# launchagents — auto-started local servers (macOS)

Repo-versioned launchd LaunchAgents for the personal HTTP servers that used
to be started by hand after every reboot. `install.sh` copies each plist
into `~/Library/LaunchAgents` and loads it; from then on the servers start
at every login, restart automatically if they crash, and log to files.

## Agents

| Label | What it runs | Port | Log |
|---|---|---|---|
| `com.dennis.search-adv-web` | search_adv web GUI (`search_adv/.venv` python, `search_adv_web.py`) | 5025 | `~/Library/Logs/search_adv_web.log` |
| `com.dennis.search-shows-web` | search_shows web GUI — cast/actor/show-info via TVmaze/TMDB/OMDb (`search_shows/.venv` python, `search_shows_web.py`) | 5020 | `~/Library/Logs/search_shows_web.log` |
| `com.dennis.travel-http` | `python3 -m http.server` in `~/repos/dennyrgood.github.io/travel` | 5030 | `~/Library/Logs/travel_http.log` |
| `com.dennis.tmdb-explorer` | TMDB explorer web GUI — raw TMDB lookup/browse (`tmdb_explorer/.venv` python, `tmdb_explorer.py`) | 5035 | `~/Library/Logs/tmdb_explorer.log` |
| `com.dennis.heartbeat-writer` | `Status/onedrive_heartbeat_writer_all_macs.py` (fleet heartbeat → local `~/fleet_monitor`) | — | `~/Library/Logs/heartbeat_writer.log` |
| `com.dennis.fleet-metrics-server` | `Status/fleet_metrics_server.py` (serves `~/fleet_monitor` to the checker over Tailscale) | 9100 | `~/Library/Logs/fleet_metrics_server.log` |

Port notes: 5000 is taken by macOS AirPlay; travel deliberately sits at 5030
so the 8xxx range stays free for ad-hoc testing (the generic `start_http`
script at the repo root is unchanged for that).

To set up another Mac (heartbeat only, incl. the required Full Disk Access
grant), see `MIGRATION.md`.

## Install / update / remove

`install.sh` is host-aware — it looks at `scutil --get ComputerName` and
only installs the agents that machine should run: mb (`denniss-macbook-air`,
primary) gets all 6; mb2 (`denniss-2nd-macbook-air`) and mmm
(`mathes-mac-mini`) are fleet-only (`heartbeat-writer` +
`fleet-metrics-server` — no Ollama, no search_adv/search_shows/travel/tmdb
GUIs). An unrecognized host aborts with an error rather than silently
installing everything; add it to the `case` statement in `install.sh` first.

```bash
cd ~/repos/scripts/launchagents
./install.sh              # install or reload this host's agents (safe to re-run)
./install.sh --uninstall  # stop and remove this host's agents
./install.sh --all        # force every agent regardless of host (debugging only)
```

Re-run `./install.sh` after editing a plist — it boots out the old copy
first. Adding a new server = drop another `.plist` in this dir, add its
label to the right host's list in `install.sh`, and re-run.

## Day-to-day

```bash
# restart after a code change (replaces the old Ctrl-C / rerun cycle)
launchctl kickstart -k gui/$UID/com.dennis.search-shows-web

# stop until next login / reinstall
launchctl bootout gui/$UID/com.dennis.search-shows-web

# is it running?  (columns: PID, last-exit-status, label — 0 = last exit was clean)
launchctl list | grep com.dennis

# full detail: state, last run, next scheduled, plist path
launchctl print gui/$UID/com.dennis.search-shows-web

# watch a log
tail -f ~/Library/Logs/search_shows_web.log
```

(`$UID` is a zsh/bash builtin that expands to the current user's uid —
works unmodified on any Mac; `$(id -u)` is the fully portable spelling if
`$UID` isn't set in your shell.)

Note on the exit-status column: `launchctl kickstart -k` restarts a service
by sending it SIGTERM, so right after using `-k` the status column will show
`-15` (i.e. "killed") even though the restart succeeded — that's expected,
not a fault. It clears on the *next* natural exit. If you want a clean `0`
immediately (e.g. before double-checking health), bootout + bootstrap instead
of kickstart:

```bash
launchctl bootout gui/$UID/com.dennis.search-shows-web
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.dennis.search-shows-web.plist
```

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
