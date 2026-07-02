#!/usr/bin/env python3
# export_archive.py
# Created: 2026-06-23 17:48 UTC
# Modified: 2026-06-25 06:15 UTC
#
# Export script: pulls asset/people/album data from the live immich API,
# writes photos into one or both of:
#   --multi-output : People/<name>/, Events/<album>/, UnMatched/  (duplicated
#                    copies, one per person/album the photo belongs to)
#   --flat-output  : Archive/<YYYY>/                              (single
#                    canonical copy per photo, full metadata regardless)
# Both copies get the SAME full metadata (all people, all albums) embedded
# via exiftool. NEVER modifies immich originals — only writes into copies
# under the given output paths.
#
# Supports --only-person / --only-album filters (exact name or "prefix*"
# wildcard, case-insensitive) and --dry-run (writes nothing, logs what it
# would do). All progress goes to a log file; all errors go to a separate
# error file. Nothing is printed to the screen except a final summary line.

import argparse
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import requests

IMMICH_URL = "http://localhost:2283"
API_KEY = "iuCCTHgYgbSaGQ2USs1xW4rk9bfZwHvQWhsi1agIU"
IMMICH_ORIGINALS_PATH = Path("/mnt/immich-data/immich/images/upload")
HEADERS = {"x-api-key": API_KEY}

UNMATCHED_DIRNAME = "UnMatched"
LOG_DIR = Path.home() / ".cache" / "immich-export"
EXIFTOOL_TIMEOUT_SECONDS = 30

# Immich's API returns originalPath as an absolute path INSIDE the docker
# container (e.g. /data/upload/<owner-id>/<xx>/<yy>/<uuid>.jpg). On the host
# filesystem, the actual file lives at IMMICH_ORIGINALS_PATH joined with
# whatever comes after this container-internal prefix. This prefix must
# match your docker-compose.yml UPLOAD_LOCATION mapping.
CONTAINER_UPLOAD_PREFIX = "/data/upload/"


def resolve_original_path(asset: dict) -> Path:
    original_path = asset["originalPath"]
    if original_path.startswith(CONTAINER_UPLOAD_PREFIX):
        relative = original_path[len(CONTAINER_UPLOAD_PREFIX):]
    else:
        # Fallback: strip any leading slash so the join below is relative,
        # not absolute (an absolute right-hand side silently discards the
        # left side in pathlib joins).
        relative = original_path.lstrip("/")
    return IMMICH_ORIGINALS_PATH / relative


# ---------- logging ----------

class Logger:
    """Routes progress lines to a log file and errors to a separate error
    file. Nothing goes to stdout except the final summary."""

    def __init__(self, dry_run: bool):
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        prefix = "dryrun_" if dry_run else ""
        self.log_path = LOG_DIR / f"{prefix}export_log_{ts}.txt"
        self.err_path = LOG_DIR / f"{prefix}export_errors_{ts}.txt"
        self._log_fh = open(self.log_path, "w", encoding="utf-8")
        self._err_fh = open(self.err_path, "w", encoding="utf-8")
        self.error_count = 0
        self.log_line_count = 0

    def log(self, msg: str):
        self._log_fh.write(msg + "\n")
        self.log_line_count += 1

    def error(self, msg: str):
        self._err_fh.write(msg + "\n")
        self.error_count += 1

    def close(self):
        self._log_fh.close()
        self._err_fh.close()


# ---------- immich API ----------

def check_response_status(r: requests.Response):
    """Raise a clear, actionable error on 401 specifically -- this almost
    always means API_KEY at the top of this script is still the placeholder
    value or has gone stale (e.g. after an Immich restart), not a real code
    bug. Checking the key is the first thing to do before chasing anything
    else."""
    if r.status_code == 401:
        raise RuntimeError(
            "\n\n*** 401 Unauthorized from Immich API ***\n"
            "IDIOT-CHECK: Did you set the real API_KEY near the top of this "
            "script? Look for: API_KEY = \"PUT_KEY_HERE\"\n"
            "If it's already set, the key may have gone stale after an "
            "Immich restart -- generate a fresh one from the Immich web UI "
            "(Account Settings -> API Keys) and update it here.\n"
        )
    r.raise_for_status()


def api_get(path: str, params: dict | None = None) -> dict:
    r = requests.get(f"{IMMICH_URL}/api{path}", headers=HEADERS, params=params, timeout=60)
    check_response_status(r)
    return r.json()


def api_post(path: str, body: dict) -> dict:
    r = requests.post(f"{IMMICH_URL}/api{path}", headers=HEADERS, json=body, timeout=60)
    check_response_status(r)
    return r.json()


def get_albums() -> dict:
    # Verified live: /api/albums returns [{id, albumName, ...}] (no nested
    # assets at this level -- assets come from /api/albums/{id}).
    data = api_get("/albums")
    albums = {}
    for album in data:
        detail = api_get(f"/albums/{album['id']}")
        albums[album["id"]] = {
            "name": detail["albumName"],
            "assets": {a["id"] for a in detail.get("assets", [])},
        }
    return albums


def get_assets() -> list:
    # CRITICAL: withPeople and withExif must be True or those fields are absent.
    assets = []
    page = 1
    while True:
        body = {"page": page, "size": 1000, "withPeople": True, "withExif": True}
        data = api_post("/search/metadata", body)
        items = data.get("assets", {}).get("items", [])
        if not items:
            break
        assets.extend(items)
        if len(items) < 1000:
            break
        page += 1
    return assets


def build_album_lookup(albums: dict) -> dict:
    mapping = {}
    for a in albums.values():
        for aid in a["assets"]:
            mapping.setdefault(aid, []).append(a["name"])
    return mapping


# ---------- name matching (exact or "prefix*" wildcard, case-insensitive) ----------

def name_matches(candidate: str, pattern: str) -> bool:
    if not candidate:
        return False
    candidate_l = candidate.lower()
    pattern_l = pattern.lower()
    if pattern_l.endswith("*"):
        return candidate_l.startswith(pattern_l[:-1])
    return candidate_l == pattern_l


# ---------- metadata ----------

def run_exiftool(cmd: list[str], description: str, logger: Logger) -> tuple[bool, str]:
    """Run an exiftool command with a timeout, and if it times out, attempt
    to kill it AND VERIFY the kill actually worked -- subprocess.run()'s
    built-in timeout handling sends SIGKILL but does not confirm the process
    actually died, which is exactly the gap that let a hung exiftool process
    run undetected for hours, consuming a full CPU core, during this
    project's development. Returns (success, stdout_or_empty)."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = proc.communicate(timeout=EXIFTOOL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.communicate(timeout=5)
            logger.error(f"exiftool TIMED OUT after {EXIFTOOL_TIMEOUT_SECONDS}s on {description} "
                         f"(PID {proc.pid}) -- killed successfully")
        except subprocess.TimeoutExpired:
            logger.error(f"exiftool TIMED OUT after {EXIFTOOL_TIMEOUT_SECONDS}s on {description} "
                         f"(PID {proc.pid}) -- DID NOT DIE after SIGKILL. This process is now "
                         f"a zombie consuming CPU. The system may be degraded. Check manually: "
                         f"ps -p {proc.pid}")
        return False, ""

    if proc.returncode != 0:
        logger.error(f"exiftool failed on {description}: {stderr.strip()}")
        return False, ""
    return True, stdout


def detect_real_extension(src: Path, logger: Logger) -> str:
    """Detect the real file type of the SOURCE file once per asset, returning
    just the correct extension (e.g. 'jpg'). This replaces re-detecting the
    same thing once per fan-out target in multi-output, which was launching
    an extra exiftool process per person/album for files that are identical
    in content -- a real, measured ~30% of total exiftool calls in a typical
    run. Returns the current extension unchanged if detection fails or the
    source can't be read (failure is logged but non-fatal; downstream copies
    will simply keep their original extension)."""
    ok, stdout = run_exiftool(
        ["exiftool", "-FileTypeExtension", "-s3", str(src)],
        f"detecting file type for {src}", logger,
    )
    if not ok or not stdout.strip():
        return src.suffix.lstrip(".").lower()
    return stdout.strip().lower()


def apply_known_extension(dst: Path, real_ext: str, logger: Logger, dry_run: bool) -> Path:
    """Rename the destination copy to match a real_ext already determined
    once per asset by detect_real_extension(). No exiftool call here --
    this is a pure filesystem rename, applied identically to every fan-out
    copy of the same source asset."""
    if dry_run:
        return dst  # nothing on disk yet to rename in dry-run mode

    current_ext = dst.suffix.lstrip(".").lower()
    if real_ext and real_ext != current_ext:
        new_dst = dst.with_suffix(f".{real_ext}")
        try:
            dst.rename(new_dst)
            logger.log(f"FIXEXT {dst} -> {new_dst} (extension said {current_ext}, actually {real_ext})")
            return new_dst
        except OSError as e:
            logger.error(f"Could not rename {dst} to fix extension: {e}")
            return dst
    return dst


def write_metadata(path: Path, description: str, keywords: list[str], logger: Logger, dry_run: bool) -> bool:
    """Returns True if metadata was written successfully (or dry-run, where
    nothing is attempted). Returns False on any failure -- callers must use
    this to decide whether to log a success line."""
    if dry_run:
        return True
    cmd = [
        "exiftool", "-overwrite_original", "-m",
        f"-EXIF:ImageDescription={description}",
        f"-IPTC:Caption-Abstract={description}",
        f"-XMP-dc:Description={description}",
    ]
    for kw in keywords:
        cmd += [f"-IPTC:Keywords+={kw}", f"-XMP-dc:Subject+={kw}"]
    cmd.append(str(path))
    ok, _ = run_exiftool(cmd, f"writing metadata to {path}", logger)
    return ok


def build_description(existing: str, people: list[str], albums: list[str]) -> str:
    parts = []
    if existing:
        parts.append(existing)
    if people:
        parts.append("\nPeople:\n" + ", ".join(people))
    if albums:
        parts.append("\nEvents:\n" + ", ".join(albums))
    return "\n".join(parts)


def make_dest_filename(asset: dict, src: Path) -> str:
    date_str = (
        asset.get("localDateTime", "")[:10]
        or asset.get("fileCreatedAt", "")[:10]
        or "0000-00-00"
    )
    original_name = asset.get("originalFileName") or src.name
    return f"{date_str}_{original_name}"


def resolve_people(asset: dict) -> list[str]:
    # /api/assets/{id} confirmed: people[] entries already include "name"
    # inline -- no need to cross-reference a separate people_map by id.
    people = []
    for p in asset.get("people", []):
        name = p.get("name")
        if name:
            people.append(name)
    return list(dict.fromkeys(people))  # dedupe, preserve order


# ---------- safety ----------

def assert_paths_safe(output_paths: list[Path]):
    immich_path = IMMICH_ORIGINALS_PATH.resolve()
    for out in output_paths:
        out_resolved = out.resolve()
        assert not str(out_resolved).startswith(str(immich_path)), \
            f"Output path is inside immich originals -- refusing: {out}"
        assert not str(immich_path).startswith(str(out_resolved)), \
            f"immich originals is inside output path -- refusing: {out}"


def safe_copy(src: Path, dst: Path, allowed_root: Path, logger: Logger, dry_run: bool):
    dst_resolved = dst.resolve()
    allowed_resolved = allowed_root.resolve()
    if not str(dst_resolved).startswith(str(allowed_resolved)):
        logger.error(f"Refusing to write outside allowed root {allowed_root}: {dst}")
        return False
    if dry_run:
        return True
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copy2(src, dst)
        return True
    except OSError as e:
        logger.error(f"Copy failed {src} -> {dst}: {e}")
        return False


def resolve_dest(dst: Path, asset_id: str) -> Path:
    if not dst.exists():
        return dst
    stem = dst.stem
    suffix = dst.suffix
    return dst.with_name(f"{stem}_{asset_id[:6]}{suffix}")


# ---------- per-asset processing ----------

def publish_multi(asset: dict, people: list[str], albums: list[str], src: Path,
                   dest_filename: str, real_ext: str, desc: str, keywords: list[str],
                   multi_root: Path, logger: Logger, dry_run: bool):
    targets = []
    for p in people:
        targets.append(multi_root / "People" / p / dest_filename)
    for a in albums:
        targets.append(multi_root / "Events" / a / dest_filename)
    if not targets:
        targets.append(multi_root / UNMATCHED_DIRNAME / dest_filename)

    for dst in targets:
        dst = resolve_dest(dst, asset["id"])
        prefix = "[DRY RUN] " if dry_run else ""
        ok = safe_copy(src, dst, multi_root, logger, dry_run)
        if ok:
            dst = apply_known_extension(dst, real_ext, logger, dry_run)
            metadata_ok = write_metadata(dst, desc, keywords, logger, dry_run)
            if metadata_ok:
                logger.log(f"{prefix}MULTI  {dst}  | keywords: {', '.join(keywords) if keywords else '(none)'}")


def publish_flat(asset: dict, src: Path, dest_filename: str, real_ext: str, desc: str,
                  keywords: list[str], flat_root: Path, logger: Logger, dry_run: bool):
    date_str = dest_filename[:4] if dest_filename[:4].isdigit() else "0000"
    dst = flat_root / "Archive" / date_str / dest_filename
    dst = resolve_dest(dst, asset["id"])
    prefix = "[DRY RUN] " if dry_run else ""
    ok = safe_copy(src, dst, flat_root, logger, dry_run)
    if ok:
        dst = apply_known_extension(dst, real_ext, logger, dry_run)
        metadata_ok = write_metadata(dst, desc, keywords, logger, dry_run)
        if metadata_ok:
            logger.log(f"{prefix}FLAT   {dst}  | keywords: {', '.join(keywords) if keywords else '(none)'}")


def publish_asset(asset: dict, album_map: dict, multi_root: Path | None,
                   flat_root: Path | None, logger: Logger, dry_run: bool):
    aid = asset["id"]
    src = resolve_original_path(asset)
    dest_filename = make_dest_filename(asset, src)

    people = resolve_people(asset)
    albums = album_map.get(aid, [])

    existing_desc = asset.get("exifInfo", {}).get("description") or ""
    desc = build_description(existing_desc, people, albums)
    keywords = people + albums

    # Detect the real file type ONCE per asset (from the source), rather
    # than once per fan-out target -- the content doesn't change between
    # copies, so re-detecting it per copy was pure waste (measured ~30% of
    # total exiftool calls in a typical run).
    real_ext = "" if dry_run else detect_real_extension(src, logger)

    if multi_root is not None:
        publish_multi(asset, people, albums, src, dest_filename, real_ext, desc, keywords,
                      multi_root, logger, dry_run)

    if flat_root is not None:
        publish_flat(asset, src, dest_filename, real_ext, desc, keywords,
                     flat_root, logger, dry_run)


# ---------- filtering ----------

def filter_assets(assets: list, album_map: dict, only_person: str | None,
                   only_album: str | None) -> list:
    if not only_person and not only_album:
        return assets

    filtered = []
    for asset in assets:
        people = resolve_people(asset)
        albums = album_map.get(asset["id"], [])

        person_match = only_person and any(name_matches(p, only_person) for p in people)
        album_match = only_album and any(name_matches(a, only_album) for a in albums)

        if only_person and only_album:
            if person_match or album_match:
                filtered.append(asset)
        elif only_person:
            if person_match:
                filtered.append(asset)
        elif only_album:
            if album_match:
                filtered.append(asset)
    return filtered


# ---------- main ----------

def stamp_filesystem_dates(output_roots: list[Path], logger: Logger, dry_run: bool):
    """Run the exiftool filesystem date-stamp pass against each output root,
    per Appendix A: 'exiftool "-FileModifyDate<DateTimeOriginal" -r <root>'.
    Required so sort-by-date works correctly in plain file browsers, since
    shutil.copy2() leaves the filesystem mtime as the copy time, not the
    photo's actual date."""
    for root in output_roots:
        if not root.exists():
            continue
        prefix = "[DRY RUN] " if dry_run else ""
        logger.log(f"{prefix}STAMP  Running filesystem date-stamp pass on {root}")
        if dry_run:
            continue
        cmd = ["exiftool", "-FileModifyDate<DateTimeOriginal", "-r", str(root)]
        try:
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
            logger.log(f"STAMP  exiftool output: {result.stdout.strip()}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Filesystem date-stamp pass failed on {root}: {e.stderr.strip()}")


def main():
    parser = argparse.ArgumentParser(description="Export immich library to archive folder(s).")
    parser.add_argument("--multi-output", type=Path, default=None,
                         help="Path for the multi-copy People/Events/UnMatched tree.")
    parser.add_argument("--flat-output", type=Path, default=None,
                         help="Path for the flat single-copy-per-photo archive.")
    parser.add_argument("--only-person", type=str, default=None,
                         help='Filter to assets tagged with a matching person. Exact name or "prefix*", case-insensitive.')
    parser.add_argument("--only-album", type=str, default=None,
                         help='Filter to assets in a matching album. Exact name or "prefix*", case-insensitive.')
    parser.add_argument("--dry-run", action="store_true",
                         help="Preview actions only -- writes nothing, logs what would happen.")
    parser.add_argument("--limit", type=int, default=None,
                         help="Process at most N assets (applied after --only-person/--only-album filtering). For quick test runs.")
    args = parser.parse_args()

    if args.multi_output is None and args.flat_output is None:
        print("ERROR: at least one of --multi-output or --flat-output is required.", file=sys.stderr)
        sys.exit(1)

    output_paths = [p for p in (args.multi_output, args.flat_output) if p is not None]
    assert_paths_safe(output_paths)

    logger = Logger(dry_run=args.dry_run)
    logger.log(f"RUN {' '.join(sys.argv)}")

    albums = get_albums()
    album_map = build_album_lookup(albums)
    assets = get_assets()
    assets = filter_assets(assets, album_map, args.only_person, args.only_album)
    if args.limit is not None:
        assets = assets[:args.limit]

    for asset in assets:
        try:
            publish_asset(asset, album_map, args.multi_output, args.flat_output,
                          logger, args.dry_run)
        except Exception as e:
            logger.error(f"Unhandled error on asset {asset.get('id', '?')}: {e}")

    stamp_filesystem_dates(output_paths, logger, args.dry_run)

    logger.close()
    print(f"Done. {len(assets)} assets processed. "
          f"{logger.log_line_count} log lines -> {logger.log_path}. "
          f"{logger.error_count} errors -> {logger.err_path}.")


if __name__ == "__main__":
    main()

# 2026-06-30 UTC: path updated win-d -> immich-data (mount rename)
