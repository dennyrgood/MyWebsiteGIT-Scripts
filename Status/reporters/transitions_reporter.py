"""
reporters/transitions_reporter.py — status transition log
Diffs each cycle's assembled state against the previous cycle's state and appends
a JSONL line for every host/service status change. Previous-cycle state is
persisted to transitions_state.json (in status_dir) so it survives checker
restarts (Task Scheduler RestartOnFailure, or the watchdog killing/restarting the
process) instead of resetting to empty and synthesizing phantom transitions.
See Status/SPEC_status_transitions_log.md (Part B) for background.
Standard interface: report(state, status_dir, checker_host) — called by engine
after every poll cycle, same signature as json_reporter.report().

Edit log:
  2026-08-13 UTC — Phase 1 (alert-log noise-reduction project), applied in one pass:
    item 1 — replaced the in-memory _previous_state dict with transitions_state.json,
      persisted to status_dir. Cold start emits one {"scope":"monitor","event":"start"}
      marker and reseeds state instead of diffing against an empty table.
    item 2 — host-down no longer fans out into one line per service ("Host unreachable"
      x N); the affected/recovered service names are folded into the single host
      transition's detail instead.
    item 3 — "unknown" is no longer a real state: a raw "unknown" observation carries
      the prior effective status forward and never itself produces a transition.
      (This also does most of item 2's work: since a host-down-forced "unknown" never
      changes the stored effective status, no per-service line fires for it. A
      service's own line fires again on recovery ONLY if its real post-recovery status
      actually differs from its pre-outage status — i.e. real events still surface.)
    item 4 — FAIL_STREAK_THRESHOLD consecutive raw "down" observations required before
      an entity's effective status flips to "down"; a single "up" clears immediately
      (asymmetric, per spec). Applies to hosts and services alike.
    item 6 — PORTABLE_HOSTS (laptops that sleep) don't get a host down/up transition
      unless the outage outlasts PORTABLE_GRACE_SECONDS; servers stay strict.
    item 7 — SCHEDULED_BLIP_WINDOWS: a down/up pair inside a configured daily window is
      suppressed, but if the window closes with no down observed that day, one
      "scope":"scheduled_blip" alert line fires instead (silence is the anomaly).
    item 8 — flap collapse: >FLAP_THRESHOLD transitions for one entity within
      FLAP_WINDOW_MINUTES collapses into a single "scope":"chatter" line and suppresses
      further lines for that entity until it holds stable for FLAP_STABLE_MINUTES.
    All tuning constants live in config.py, not here.
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path

import config

logger = logging.getLogger(__name__)

TRANSITIONS_FILENAME = "status_transitions.jsonl"
STATE_FILENAME = "transitions_state.json"
SCHEMA_VERSION = 1
MAX_LINES = 1000


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _load_state(path: Path) -> dict:
    """Load persisted per-entity state. Missing/corrupt file -> {} (cold start)."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    try:
        return json.loads(raw).get("entities", {})
    except (json.JSONDecodeError, ValueError):
        logger.error("Corrupt %s, treating as cold start", path)
        return {}


def _save_state(path: Path, entities: dict) -> None:
    """Write state atomically (tmp + replace), same pattern as _trim()."""
    payload = {
        "schema_version": SCHEMA_VERSION,
        "updated_utc": _now().isoformat().replace("+00:00", "Z"),
        "entities": entities,
    }
    tmp_path = path.with_suffix(".tmp")
    try:
        tmp_path.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
        tmp_path.replace(path)
    except OSError as e:
        logger.error("Failed to write state to %s: %s", path, e)
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass


def _resolve_effective_status(raw_status: str, prev_entity: dict | None, is_portable_host: bool, now: datetime) -> tuple[str, int, str | None]:
    """
    Turn a raw observed status into the effective status to store/diff.
    Returns (effective_status, new_fail_streak, new_down_since).

      - "unknown"  -> carry the prior effective status forward (item 3); never itself
                       a transition, never touches the fail streak.
      - "up"/other -> clears immediately: effective = raw, streak resets to 0 (item 4's
                       asymmetry — one good observation is enough).
      - "down"     -> requires FAIL_STREAK_THRESHOLD consecutive raw downs before the
                       effective status flips (item 4). Portable hosts additionally hold
                       at the prior status until PORTABLE_GRACE_SECONDS has elapsed since
                       the raw down first started (item 6), even once the streak
                       threshold is met.
    """
    prev_status = prev_entity.get("status") if prev_entity else None
    prev_streak = prev_entity.get("fail_streak", 0) if prev_entity else 0
    prev_down_since = prev_entity.get("down_since") if prev_entity else None

    if raw_status == "unknown":
        return (prev_status if prev_status is not None else "unknown"), prev_streak, prev_down_since

    if raw_status != "down":
        return raw_status, 0, None

    new_streak = prev_streak + 1
    down_since = prev_down_since or now.isoformat().replace("+00:00", "Z")

    if is_portable_host:
        elapsed_s = (now - _parse_ts(down_since)).total_seconds()
        if elapsed_s >= config.PORTABLE_GRACE_SECONDS:
            return "down", new_streak, down_since
        return (prev_status if prev_status is not None else "up"), new_streak, down_since

    if new_streak >= config.FAIL_STREAK_THRESHOLD:
        return "down", new_streak, down_since
    return (prev_status if prev_status is not None else "up"), new_streak, down_since


def _in_scheduled_window(host: str, service: str | None, now: datetime) -> dict | None:
    """Return the matching SCHEDULED_BLIP_WINDOWS entry if (host, service) has one
    active right now, else None. Windows are UTC time-of-day, assumed same-day
    (start < end); none of today's configured windows cross midnight."""
    for win in config.SCHEDULED_BLIP_WINDOWS:
        if win["host"] != host or win["service"] != service:
            continue
        start_h, start_m = (int(x) for x in win["start_utc"].split(":"))
        end_h, end_m = (int(x) for x in win["end_utc"].split(":"))
        start_t, end_t = now.replace(hour=start_h, minute=start_m, second=0, microsecond=0), \
                          now.replace(hour=end_h, minute=end_m, second=0, microsecond=0)
        if start_t <= now <= end_t:
            return win
    return None


def _just_closed_window(host: str, service: str | None, now: datetime) -> dict | None:
    """Return a SCHEDULED_BLIP_WINDOWS entry whose window ended within the last
    poll interval (so we check the day's outcome exactly once, shortly after close)."""
    grace = timedelta(seconds=config.POLL_INTERVAL_SECONDS * 2)
    for win in config.SCHEDULED_BLIP_WINDOWS:
        if win["host"] != host or win["service"] != service:
            continue
        end_h, end_m = (int(x) for x in win["end_utc"].split(":"))
        end_t = now.replace(hour=end_h, minute=end_m, second=0, microsecond=0)
        if end_t <= now <= end_t + grace:
            return win
    return None


def _apply_flap_and_emit(entity: dict, transition: dict, now: datetime) -> dict | None:
    """
    Update an entity's recent_transitions/flap bookkeeping and decide what (if
    anything) actually gets appended to the JSONL file for this change (item 8).
    Mutates `entity` in place. Returns the line to append, or None if suppressed.
    """
    recent = [t for t in entity.get("recent_transitions", [])
              if (now - _parse_ts(t)) <= timedelta(minutes=config.FLAP_WINDOW_MINUTES)]

    if entity.get("flap_suppressed"):
        # Still flapping — hold suppression, just note the occurrence.
        recent.append(now.isoformat().replace("+00:00", "Z"))
        entity["recent_transitions"] = recent
        entity["status_since"] = now.isoformat().replace("+00:00", "Z")
        return None

    if len(recent) >= config.FLAP_THRESHOLD:
        entity["flap_suppressed"] = True
        entity["recent_transitions"] = recent + [now.isoformat().replace("+00:00", "Z")]
        entity["status_since"] = now.isoformat().replace("+00:00", "Z")
        label = f'{transition["host"]}/{transition["service"]}' if transition.get("service") else transition["host"]
        return {
            "ts": transition["ts"], "scope": "chatter", "host": transition["host"],
            "service": transition.get("service"), "from": None, "to": None,
            "detail": f"chatter: {label}, {len(recent) + 1} transitions in {config.FLAP_WINDOW_MINUTES}m — suppressing further lines until stable {config.FLAP_STABLE_MINUTES}m",
        }

    recent.append(now.isoformat().replace("+00:00", "Z"))
    entity["recent_transitions"] = recent
    entity["status_since"] = now.isoformat().replace("+00:00", "Z")
    return transition


def report(state: dict, status_dir: Path, checker_host: str) -> None:
    """Diff state against persisted previous-cycle state and append any transitions."""
    state_path = status_dir / STATE_FILENAME
    prev_entities = _load_state(state_path)
    cold_start = not prev_entities

    current: dict = {}
    transitions = []
    timestamp_utc = state.get("meta", {}).get("timestamp_utc")
    # All window/streak/grace/flap logic is anchored to this poll cycle's own
    # timestamp, not wall-clock time — keeps behavior deterministic and testable,
    # and correct even if this function is ever called slightly late.
    now = _parse_ts(timestamp_utc) if timestamp_utc else _now()

    if cold_start:
        transitions.append({
            "ts": timestamp_utc, "scope": "monitor", "host": None, "service": None,
            "from": None, "to": None, "event": "start",
            "detail": f"Monitor (re)started on {checker_host}; state seeded, no diff this cycle",
        })

    for machine in state.get("machines", []):
        tailscale_name = machine["machine"]["tailscale_name"]
        raw_host_status = machine["host"]["status"]
        host_detail = machine["host"].get("detail")
        is_portable = tailscale_name in config.PORTABLE_HOSTS

        prev_host_entity = prev_entities.get(tailscale_name)
        eff_host_status, host_streak, host_down_since = _resolve_effective_status(
            raw_host_status, prev_host_entity, is_portable, now)
        prev_host_status = prev_host_entity.get("status") if prev_host_entity else None

        host_entity = dict(prev_host_entity) if prev_host_entity else {}
        host_entity.update({"status": eff_host_status, "fail_streak": host_streak, "down_since": host_down_since})
        current[tailscale_name] = host_entity

        # --- services: resolve effective status first (needed for host-detail annotation) ---
        svc_infos = []
        for svc in machine.get("services", []):
            svc_name = svc["name"]
            raw_svc_status = svc["tailscale_check"]["status"]
            svc_detail = svc["tailscale_check"].get("detail")
            entity_key = f"{tailscale_name}/{svc_name}"
            prev_svc_entity = prev_entities.get(entity_key)

            eff_svc_status, svc_streak, svc_down_since = _resolve_effective_status(
                raw_svc_status, prev_svc_entity, False, now)
            prev_svc_status = prev_svc_entity.get("status") if prev_svc_entity else None

            svc_entity = dict(prev_svc_entity) if prev_svc_entity else {}
            svc_entity.update({"status": eff_svc_status, "fail_streak": svc_streak, "down_since": svc_down_since})
            current[entity_key] = svc_entity

            svc_infos.append({
                "name": svc_name, "status": eff_svc_status, "prev_status": prev_svc_status,
                "detail": svc_detail, "entity_key": entity_key, "entity": svc_entity,
            })

        if cold_start:
            continue

        # --- host transition --- (SCHEDULED_BLIP_WINDOWS only apply at service scope today)
        if prev_host_status is not None and prev_host_status != eff_host_status:
            if eff_host_status != "up":
                affected = [s["name"] for s in svc_infos]
                detail = f"{host_detail} — services affected: {', '.join(affected)}" if affected else host_detail
            else:
                parts = [f'{s["name"]} {s["status"]}' for s in svc_infos]
                detail = f"{host_detail} — services: {', '.join(parts)}" if parts else host_detail
            t = {
                "ts": timestamp_utc, "scope": "host", "host": tailscale_name, "service": None,
                "from": prev_host_status, "to": eff_host_status, "detail": detail,
            }
            line = _apply_flap_and_emit(host_entity, t, now)
            if line:
                transitions.append(line)

        # --- service transitions ---
        for s in svc_infos:
            if s["prev_status"] is None or s["prev_status"] == s["status"]:
                continue
            win = _in_scheduled_window(tailscale_name, s["name"], now)
            if win:
                # Suppress the line, but remember today's date so the "did the
                # expected blip happen" check below can tell it occurred.
                s["entity"]["blip_seen_date"] = now.date().isoformat()
                continue
            t = {
                "ts": timestamp_utc, "scope": "service", "host": tailscale_name, "service": s["name"],
                "from": s["prev_status"], "to": s["status"], "detail": s["detail"],
            }
            line = _apply_flap_and_emit(s["entity"], t, now)
            if line:
                transitions.append(line)

        # --- flap-stability check: lift suppression once quiet for FLAP_STABLE_MINUTES ---
        for entity in [host_entity] + [s["entity"] for s in svc_infos]:
            if entity.get("flap_suppressed") and entity.get("status_since"):
                if (now - _parse_ts(entity["status_since"])) >= timedelta(minutes=config.FLAP_STABLE_MINUTES):
                    entity["flap_suppressed"] = False
                    entity["recent_transitions"] = []

        # --- scheduled-blip absence check (item 7): fires once, shortly after the window closes ---
        for win in config.SCHEDULED_BLIP_WINDOWS:
            if win["host"] != tailscale_name:
                continue
            closed = _just_closed_window(win["host"], win["service"], now)
            if not closed:
                continue
            entity_key = f'{win["host"]}/{win["service"]}'
            entity = current.get(entity_key, {})
            today = now.date().isoformat()
            if entity.get("blip_seen_date") == today:
                continue  # blip happened as expected — nothing to report
            if entity.get("blip_alerted_date") == today:
                continue  # already alerted once today
            entity["blip_alerted_date"] = today
            transitions.append({
                "ts": timestamp_utc, "scope": "scheduled_blip", "host": win["host"], "service": win["service"],
                "from": None, "to": None, "event": "missing",
                "detail": f'Expected {win["label"]} blip ({win["start_utc"]}-{win["end_utc"]} UTC) did not occur today',
            })

    _save_state(state_path, current)

    if transitions:
        _append_transitions(status_dir / TRANSITIONS_FILENAME, transitions)


def _append_transitions(path: Path, transitions: list) -> None:
    """Append transition lines, then trim the file to the last MAX_LINES entries."""
    try:
        with path.open("a", encoding="utf-8") as f:
            for t in transitions:
                f.write(json.dumps(t, default=str) + "\n")
    except OSError as e:
        logger.error("Failed to append transitions to %s: %s", path, e)
        return

    _trim(path)


def _trim(path: Path) -> None:
    """Keep only the last MAX_LINES lines, written atomically."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        logger.error("Failed to read %s for trim: %s", path, e)
        return

    if len(lines) <= MAX_LINES:
        return

    trimmed = lines[-MAX_LINES:]
    tmp_path = path.with_suffix(".tmp")
    try:
        tmp_path.write_text("\n".join(trimmed) + "\n", encoding="utf-8")
        tmp_path.replace(path)
    except OSError as e:
        logger.error("Failed to write trimmed %s: %s", path, e)
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
