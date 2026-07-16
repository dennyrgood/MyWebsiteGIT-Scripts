# Prompt for Claude session on mb2 (denniss-2nd-macbook-air, MacBook Air M3)

Paste/point a Claude Code session on mb2 at this file. Context: this Mac is
being brought in line with denniss-macbook-air's 2026-07-16 setup — tray
Ollama.app as the single owner of port 11434 (exposed to the tailnet via
`tailscale serve`), and the OneDrive heartbeat writer moved from `.zshrc`
to a launchd LaunchAgent.

## Already done remotely (2026-07-16, from denniss-macbook-air) — do not redo

- `~/.zshrc` fixed: `export OLLAMA_HOST=...` removed (replaced with an
  `ollama` alias pointing the CLI at chatworkhorse), and the
  `start_ollama` auto-start block commented out. Backup:
  `~/.zshrc.pre-ollama-fix.bak`.
- The old bare `ollama serve` (v0.13.5) was killed; nothing owns 11434.

## Task 1 — upgrade + configure Ollama

1. The installed `/Applications/Ollama.app` is v0.13.5 (ancient) and NOT
   brew-managed. Homebrew exists at `/opt/homebrew/bin/brew` but is not on
   PATH. Back up / remove the old app, then `brew install --cask ollama-app`
   (or fresh download from ollama.com). Models in `~/.ollama/models` are
   preserved either way.
2. CRITICAL: never `export OLLAMA_HOST` in any shell init or while
   testing — the tray app captures shell env at startup, and a remote
   value makes its server try to bind the remote IP → permanent crash
   loop. (This was the original disease on both Macs.)
3. Launch the tray app; verify `curl -s http://127.0.0.1:11434/api/version`.
4. Add to Login Items, hidden:
   `osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Ollama.app", hidden:true}'`
5. Expose to the tailnet:
   `tailscale serve --bg --tcp 11434 tcp://127.0.0.1:11434`
   (persists across reboots; disable with `tailscale serve --tcp=11434 off`).
6. Verify FROM ANOTHER MACHINE (serve never answers the local machine),
   e.g. from denniss-macbook-air:
   `curl -s http://denniss-2nd-macbook-air:11434/api/version`
   Use plain http — the `--tcp` forward is raw passthrough; the
   `https://...ts.net` form fails TLS and is not needed.

## Task 2 — heartbeat writer .zshrc → launchd

Follow `~/repos/scripts/launchagents/MIGRATION.md` exactly (pull the repo
first). Key points:

- Install ONLY `com.dennis.heartbeat-writer.plist` by hand — do NOT run
  `./install.sh`, which would also start the search_adv GUI (5025) and
  travel HTTP (5030) servers that belong on the other Mac only.
- The step that bites: grant Full Disk Access to `/usr/bin/python3`
  (System Settings → Privacy & Security), else every OneDrive write fails
  with `Operation not permitted` while the agent looks "running".
- After it's verified (fresh mtime on
  `~/OneDrive/_sync_monitor/$(hostname -s)/heartbeat_$(hostname -s).txt`),
  comment out the heartbeat starter block in `~/.zshrc` (lines starting
  `if ! pgrep -f "onedrive_heartbeat_writer_all_macs.py"`) — it was left
  active on purpose so the heartbeat didn't go dark before the agent works.

## Done when

- Tray Ollama running current version, reachable from the tailnet, in
  Login Items.
- Heartbeat LaunchAgent writing to OneDrive with no TCC errors; `.zshrc`
  starter commented out.
