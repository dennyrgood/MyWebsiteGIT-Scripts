#!/bin/bash
# scheduled_scan.sh
# Wrapper for the launchd-triggered daily fleet scan. Not meant to be run
# interactively -- use comfy_fleet.sh directly for that. This wrapper adds
# the housekeeping steps that only make sense for an unattended, recurring
# run: stable "latest" copies (so the served directory always has one
# obvious file to open) and automatic pruning of old timestamped output
# (so fleet-output/ doesn't grow forever, the way it did across one day's
# interactive session).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORTS_DIR="$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports"
OUTPUT_DIR="$REPORTS_DIR/fleet-output"
# 2026-08-31: comfy-fleet-http serves LOCAL_OUTPUT_DIR, NOT $OUTPUT_DIR directly.
# $OUTPUT_DIR lives inside OneDrive's live-syncing tree, and a long-running
# `python3 -m http.server` process holding that as its launchd WorkingDirectory
# was found (twice in <24h) to get its cached cwd handle invalidated by an
# OneDrive sync operation -- `ls` on the directory worked fine the whole time,
# but the server's own directory listing returned "No permission to list
# directory" for hours until manually restarted. Rather than keep auto-healing
# around that (see mb-health-monitor.sh's matching 2026-08-31 comment, which
# stays in place as a safety net), the server now points at a plain local
# directory that OneDrive never touches, refreshed from $OUTPUT_DIR at the end
# of every scan below -- same-day fresh, but immune to OneDrive's sync churn.
LOCAL_OUTPUT_DIR="$SCRIPT_DIR/fleet-output-local"

# Two fatal bugs hid in this file's eight lines of housekeeping (2026-09-04),
# and the first one went unnoticed for a week: `set -e` kills the script
# silently, so a truncated run looks exactly like a successful one in the log.
# Never again -- announce the line number and exit code on any unexpected death.
trap 'rc=$?; echo "*** FAILED: ${BASH_SOURCE[0]} line $LINENO exited $rc ***" >&2' ERR

echo "=== $(date) -- scheduled fleet scan starting ==="

"$SCRIPT_DIR/comfy_fleet.sh"

# Keep the last 3 runs' worth of timestamped files (inputs, fleet-output,
# history). Runs BEFORE the latest/mirror step below so the published copies
# and the mirror reflect the same retention window -- prune always keeps the
# newest run, so the report just generated is never the one pruned.
# Pinned to the Homebrew interpreter: under launchd's minimal PATH a bare
# `python3` resolves to Apple's 3.9.6, which predates the PEP 604 `str | None`
# hints this file uses (and, per the TCC note below, lacks the Full Disk Access
# the Homebrew build has).
/opt/homebrew/bin/python3 "$SCRIPT_DIR/comfy_fleet.py" --config "$REPORTS_DIR/fleet_config.json" \
    --prune-output --confirm-prune --keep-runs 3

# Needed_In_Bare.html -- separate, single-purpose report (not part of
# comfy_fleet.py's own pipeline), added 2026-09-04. Regenerated every run so
# it never goes stale, using the fresh CSVs comfy_fleet.sh just produced.
# Writes only into $OUTPUT_DIR/ (report) and $OUTPUT_DIR/thumbs/ (PNG
# thumbnails via `sips`) -- both already proven python3-writable under
# launchd; `sips`'s own TCC access under launchd is unconfirmed as of this
# writing, so a thumbnail failure must not be treated as a fatal error here
# (the report already degrades gracefully to "no PNG" placeholders).
/opt/homebrew/bin/python3 "$SCRIPT_DIR/needed_in_bare.py" --config "$REPORTS_DIR/fleet_config.json"

# --- Post-scan housekeeping: ALL of it in python3, deliberately -----------------
# Under launchd this agent has NO shell-level access to the OneDrive
# CloudStorage folder. Probed directly 2026-09-04 from a launchd-launched
# process:
#     ls  : DENIED      cp : DENIED      cmp : DENIED
#     /opt/homebrew/bin/python3 : OK (23 entries)
# That is macOS TCC granting Full Disk Access per-binary; python3 has it,
# the system shell utilities do not. It works interactively because a Terminal
# shell inherits Terminal's own grant.
#
# This is why three separate bugs hid here for weeks, each masking the next:
#   1. `ls -t ... | head -1` under `set -euo pipefail` -> SIGPIPE killed the run
#      before anything else could be reached.
#   2. the bare glob matched fleet_report_latest.html itself -> `cp X X` failed.
#   3. and underneath both: ls/cp/cmp/rsync were being DENIED the whole time,
#      so even "fixed" the copies silently did nothing -- `|| true` turned the
#      failure into an empty variable and the guarded `cp` just never ran,
#      leaving fleet_report_latest.html and the served mirror permanently stale.
# Doing the work in the one binary that actually has access removes the class
# of problem rather than patching each symptom.
/opt/homebrew/bin/python3 - "$OUTPUT_DIR" "$LOCAL_OUTPUT_DIR" <<'HOUSEKEEP_PY'
import filecmp, os, re, shutil, sys

out_dir, local_dir = sys.argv[1], sys.argv[2]
os.makedirs(local_dir, exist_ok=True)
TS = re.compile(r"^fleet_(report|explorer)_\d{4}-\d{2}-\d{2}_\d{4}\.html$")

# 1. Stable "latest" copies, so a bookmark/tile always resolves to something
#    current. Only timestamped files are ever copy SOURCES -- matching
#    fleet_*_latest.html here is what made the old `cp X X` fail.
newest = {}
for name in os.listdir(out_dir):
    m = TS.match(name)
    if m:
        kind = m.group(1)
        if name > newest.get(kind, ""):      # yyyy-mm-dd_HHmm sorts chronologically
            newest[kind] = name
for kind, name in sorted(newest.items()):
    dst = os.path.join(out_dir, f"fleet_{kind}_latest.html")
    shutil.copy2(os.path.join(out_dir, name), dst)
    print(f"latest: fleet_{kind}_latest.html <- {name}")
if not newest:
    print("ERROR: no timestamped report/explorer found to publish", file=sys.stderr)
    sys.exit(1)

# 2. Mirror to the plain local dir the web server serves (OneDrive never
#    touches that one -- see the 2026-08-31 note on the http agent). Walks
#    subdirectories too (added 2026-09-04 for thumbs/, from Needed_In_Bare.html
#    -- the original flat-files-only version silently never mirrored it).
copied = removed = 0
src_rel = set()
for root, dirs, files in os.walk(out_dir):
    rel_root = os.path.relpath(root, out_dir)
    for name in files:
        rel = name if rel_root == "." else os.path.join(rel_root, name)
        src_rel.add(rel)
        sp, dp = os.path.join(root, name), os.path.join(local_dir, rel)
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        if not os.path.exists(dp) or not filecmp.cmp(sp, dp, shallow=False):
            shutil.copy2(sp, dp)
            copied += 1
for root, dirs, files in os.walk(local_dir, topdown=False):
    rel_root = os.path.relpath(root, local_dir)
    for name in files:
        rel = name if rel_root == "." else os.path.join(rel_root, name)
        if rel not in src_rel:                           # --delete equivalent
            os.remove(os.path.join(root, name))
            removed += 1
    if rel_root != "." and not os.listdir(root):
        os.rmdir(root)
print(f"mirror: {copied} copied, {removed} removed, {len(src_rel)} in sync")

# 3. Verify the outcome instead of trusting any exit code -- the served report
#    must actually be the one just generated.
for kind in newest:
    a = os.path.join(out_dir,   f"fleet_{kind}_latest.html")
    b = os.path.join(local_dir, f"fleet_{kind}_latest.html")
    if not (os.path.exists(b) and filecmp.cmp(a, b, shallow=False)):
        print(f"ERROR: served fleet_{kind}_latest.html does not match source", file=sys.stderr)
        sys.exit(1)
print("verified: served copies match the current run")
HOUSEKEEP_PY

echo "=== $(date) -- scheduled fleet scan complete ==="
