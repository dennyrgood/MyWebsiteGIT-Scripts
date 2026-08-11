# Option 2 — per-client NUT status via the heartbeat path (not built)

Written 2026-08-12. Companion to *UPS and NUT Setup Guide — Amsterdam v7*, Section 8's
monitoring gap, and to the `NUT (ups2)` / `NUT (ups0)` `tcp` checks added to
`Status/config.py` the same day (see git log — that part **was** built).

This document describes a second, larger piece of work that was proposed and then
deliberately **not** built, so the reasoning doesn't have to be reconstructed if it
comes up again. Nothing here exists in the repo yet.

## The gap this would close

The `tcp` checks against `ups2@workbenchunix:3493` and `ups0@192.168.178.123:3493`
that were built prove the NUT **server** is reachable from wherever `checker.py` runs
(AmsterdamDesktop). They do not prove any particular **client** — ImageBeast,
ChatWorkhorse — can reach it. `ups-watch.ps1` on those boxes defaults to the LAN
address for WBU (`192.168.178.242`), which may not be the same network path
`checker.py`'s probe takes. A LAN-segment or NIC-specific problem between ImageBeast
and WBU specifically would pass the server-side check and still leave ImageBeast with
no shutdown signal.

This is a narrow failure mode: it requires the path break to be specific to one
client rather than general, *and* a real power event to land in the same window
before it costs anything (per the guide's Section 8, the failure mode is silent loss
of coverage, not a false trigger).

## Shape of the design, if built later

Follows the existing pattern in `Status/checkers/http_heartbeat_checker.py` closely —
that module already does "fetch a small per-host file over `http://<host>:9100/...`,
judge freshness, return up/down" for writer-liveness. The NUT version would be the
same shape:

1. **`ups-watch.ps1` writes a status file every run**, not just on state change.
   This is the one real design conflict with the script as it exists: its log is
   deliberately silent-when-healthy (so Task Scheduler running it every minute
   doesn't spam a line every minute forever). That's correct for a human-read log,
   wrong for a heartbeat — a monitoring consumer needs "checked 40s ago, fine" to
   tell healthy apart from "the task silently died," which is the same reason
   `http_heartbeat_checker.py` judges staleness rather than trusting content alone.
   So this needs a second, always-written artifact, not a repurposing of the log.

   Proposed fields for `nut_status_<host>.json`:
   ```json
   {
     "checked_at": "2026-08-12T01:23:45Z",
     "ups_name": "ups2",
     "ups_host": "192.168.178.242",
     "reachable": true,
     "status_raw": "OL",
     "on_battery": false,
     "on_battery_since": null,
     "minutes_on_battery": 0,
     "threshold_minutes": 8,
     "shutdown_armed": false,
     "error": null
   }
   ```

2. **`fleet_metrics_server.py`'s filename allowlist would need extending.** Per
   `Status/README_MOVE_AWAY_ONEDRIVE.md`, the server is explicitly path-restricted to
   exactly three filename patterns (`heartbeat_`, `machine_info_`,
   `metrics_history_`). A fourth pattern for `nut_status_` means editing shared code
   that runs on every box in the fleet — Mac, Ubuntu, and Windows — even though only
   two Windows boxes would use it at first. Every running instance needs the updated
   file plus a restart to actually serve the new pattern.

3. **New `checkers/nut_client_checker.py`**, same shape as
   `http_heartbeat_checker.py`: fetch `http://<target_host>:9100/nut_status_<target_host>.json`,
   treat a stale file (task died) as down, `reachable: false` as down, and surface
   `on_battery` / `minutes_on_battery` in the detail string.

4. **Register in `config.py`'s `check_types`** for ImageBeast and ChatWorkhorse only —
   explicitly **not** AmsterdamDesktop, since that box is going native Windows HID
   handling rather than NUT (see the guide's cheap-UPS table). A comment at the config
   entry would need to say so, so a missing tile there reads as "not applicable," not
   "broken."

## Open design call, never resolved

Should `on_battery: true` alone flip the tile to alarm/down, or stay "up" (comms are
fine) with a loud detail string, only escalating once `minutes_on_battery` approaches
the shutdown threshold? Leaning toward the latter at the time this was discussed, but
it's a real judgment call, not a default anyone committed to.

## Why this was shelved rather than built (2026-08-12)

- The marginal benefit over the server-side `tcp` check is the LAN-vs-Tailscale path
  divergence edge case above — real, but narrow, and only costs anything if it
  coincides with an actual outage.
- The cost is not narrow: a new file format, a shared-code change to
  `fleet_metrics_server.py` that has to roll out fleet-wide for a two-box benefit, a
  new checker module, and — the heaviest part — more responsibility added to
  `ups-watch.ps1` itself. That script was, as of this writing, still unexecuted
  end-to-end (Appendix A4's live outage test hadn't happened yet). Piling a
  self-reporting duty onto a shutdown-decision script before the shutdown decision
  itself has been proven in a real event was judged not worth it.

## Revisit if

- A real incident shows the server-side `tcp` check wasn't sufficient — i.e. WBU's
  `upsd` was fine but a specific client still didn't get a usable signal.
- `ups-watch.ps1` has survived a real battery event cleanly (Appendix A4 done, and
  ideally one real outage beyond that), at which point adding a second
  responsibility to it is less likely to be adding risk to something unproven.
