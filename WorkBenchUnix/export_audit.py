#!/usr/bin/env python3
# export_audit.py
#
# Read-only diagnostic: compares files already on disk under a
# --multi-output/--flat-output tree against what export_archive.py would
# currently name them, to see how "dirty" (unmatchable) the existing export
# is before building a backfill/manifest tool on top of it. Touches nothing.
#
# For each existing file found:
#   CLEAN     - name exactly matches an asset's expected dest_filename
#   SUFFIXED  - name matches expected_stem_<id6><ext> and that id6 is a
#               genuine prefix of a real asset id (collision copy, as
#               produced by export_archive.resolve_dest)
#   ORPHAN    - name doesn't match any current asset's expected filename at
#               all (asset deleted/renamed in Immich since export, or the
#               file predates a metadata change that altered the date/name)
#
# Also reports the reverse: assets with NO matching file anywhere on disk
# (never exported, or exported under a filename that no longer matches).

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

from export_archive import get_albums, get_assets, build_album_lookup, make_dest_filename, resolve_original_path

SUFFIX_RE = re.compile(r"^(.*)_([0-9a-fA-F]{6})$")


def index_assets():
    albums = get_albums()
    album_map = build_album_lookup(albums)
    assets = get_assets()
    by_expected_stem = {}
    by_id6 = defaultdict(list)
    for asset in assets:
        aid = asset["id"]
        src = resolve_original_path(asset)
        dest_filename = make_dest_filename(asset, src)
        stem = Path(dest_filename).stem
        by_expected_stem.setdefault(stem, []).append(aid)
        by_id6[aid[:6]].append(aid)
    return assets, album_map, by_expected_stem, by_id6


def audit_root(root: Path, by_expected_stem: dict, by_id6: dict):
    clean = 0
    suffixed = 0
    orphans = []
    matched_asset_ids = set()

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        stem = path.stem

        if stem in by_expected_stem:
            clean += 1
            matched_asset_ids.update(by_expected_stem[stem])
            continue

        m = SUFFIX_RE.match(stem)
        if m:
            base_stem, id6 = m.group(1), m.group(2)
            if base_stem in by_expected_stem and id6 in by_id6:
                suffixed += 1
                matched_asset_ids.update(by_id6[id6])
                continue

        orphans.append(path)

    return clean, suffixed, orphans, matched_asset_ids


def main():
    parser = argparse.ArgumentParser(
        description="Audit how well existing export output matches current Immich asset filenames. Read-only.")
    parser.add_argument("--multi-output", type=Path, default=None)
    parser.add_argument("--flat-output", type=Path, default=None)
    parser.add_argument("--show-orphans", type=int, default=20,
                         help="Max orphan file paths to print per root (default 20, 0 for none).")
    args = parser.parse_args()

    roots = [p for p in (args.multi_output, args.flat_output) if p is not None]
    if not roots:
        print("ERROR: at least one of --multi-output or --flat-output is required.", file=sys.stderr)
        sys.exit(1)

    print("Fetching asset list from Immich API...")
    assets, album_map, by_expected_stem, by_id6 = index_assets()
    print(f"{len(assets)} assets known to Immich.\n")

    all_matched_ids = set()
    for root in roots:
        if not root.exists():
            print(f"=== {root} === does not exist, skipping.")
            continue
        print(f"=== {root} ===")
        clean, suffixed, orphans, matched_ids = audit_root(root, by_expected_stem, by_id6)
        all_matched_ids.update(matched_ids)
        total = clean + suffixed + len(orphans)
        print(f"  files on disk:  {total}")
        print(f"  clean matches:  {clean}")
        print(f"  suffixed matches: {suffixed}")
        print(f"  orphans (no match): {len(orphans)}")
        if orphans and args.show_orphans:
            print(f"  first {min(args.show_orphans, len(orphans))} orphan(s):")
            for o in orphans[:args.show_orphans]:
                print(f"    {o}")
        print()

    unexported = [a for a in assets if a["id"] not in all_matched_ids]
    print(f"=== Assets with no matching file in any given root: {len(unexported)} / {len(assets)} ===")
    if unexported[:20]:
        for a in unexported[:20]:
            print(f"    {a['id']}  {a.get('originalFileName')}")
        if len(unexported) > 20:
            print(f"    ... and {len(unexported) - 20} more")


if __name__ == "__main__":
    main()
