#!/usr/bin/env python3
"""
needed_in_bare.py — "what do I need to copy/download to Models_bare, and what
custom nodes do I need to install, to make the prime workflows (root-level
workflows\\*.json) run on TravelBeast + ChatWorkhorse."

A separate, small, single-purpose report — deliberately NOT folded into
comfy_fleet.py's general-purpose pipeline. Reads the same scan CSVs
comfy_fleet.py already produces (and re-fetches live /object_info, same as
comfy_fleet.py does), and reuses comfy_fleet.py's own fuzzy-match / node-load
logic directly rather than re-implementing it — imported, not copied.

Does not generate a .bat — read-only, look-and-decide-yourself report.

Usage:
    /opt/homebrew/bin/python3 needed_in_bare.py [--config path/to/fleet_config.json]
"""
import argparse, difflib, json, os, re, shutil, subprocess, sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
# Reuse comfy_fleet.py's own fuzzy-match and node-loading logic rather than
# re-implementing it -- both are exactly the "is this really the same thing
# under another name" question this report needs answered twice (models,
# custom nodes), and comfy_fleet.py already carries the tested version plus
# the incidents that shaped it. Safe to import: main() is __name__-guarded,
# nothing module-level runs on import.
from comfy_fleet import (
    base_family, load_nodes, load_csv, node_status, NO_NODE_PACKAGES,
    scan_object_info, build_classtype_package_map,
)

MACHINE_TAG_RE = re.compile(r"\(\s*(tb|c|ib|i|bare)\s*\)", re.IGNORECASE)


def machine_tag(name: str):
    m = MACHINE_TAG_RE.search(name)
    if not m:
        return None
    t = m.group(1).lower()
    return "ib" if t == "i" else t


def base_no_tag(name: str) -> str:
    """Filename with extension and machine tag stripped, for name-matching a
    workflow template against its Starting Images PNG counterpart."""
    n = os.path.splitext(name)[0]
    n = MACHINE_TAG_RE.sub("", n)
    return re.sub(r"\s+", " ", n).strip().lower()


def find_latest(reports_dir: Path, hostname: str, pattern: str):
    matches = sorted(reports_dir.glob(f"{hostname}-{pattern}"))
    return matches[-1] if matches else None


# load_csv is imported from comfy_fleet.py -- it already retries on the
# transient OneDrive-lock race (found 2026-09-05, same day this script was
# first run through the real scheduled agent: a fresh scan's CSV was read
# within seconds of the SSH scan writing it, while OneDrive was still
# syncing that file to this Mac, and this script's own local copy of
# load_csv() -- written before that fix existed -- had no retry at all and
# died with "OSError: [Errno 11] Resource deadlock avoided" on its very
# first real run. Two copies of the same helper is exactly how a fix in one
# and not the other happens; importing the one true version removes the
# class of problem instead of just patching this instance of it.


def is_prime_row(row: dict, include_ib: bool) -> bool:
    """True for a row belonging to a root-level workflow template -- same
    predicate as comfy_fleet.py's is_prime_row(), reimplemented here rather
    than imported since it also needs to apply to node_types.csv rows, which
    comfy_fleet.py's version was never asked to handle."""
    if row.get("source", "") != "workflows":
        return False
    wf = row.get("workflow_file", "")
    rel = wf.split("\\", 1)[1] if "\\" in wf else wf
    if "\\" in rel:
        return False
    if not include_ib and machine_tag(rel) == "ib":
        return False
    return True


def vram_verdict(size_gb: float, ok: float, maybe: float) -> str:
    if size_gb <= 0:
        return "?"
    if size_gb <= ok:
        return "OK"
    if size_gb <= maybe:
        return "MAYBE"
    return "BIG"


def host_vram_thresholds(host_vram_gb: float, global_ok: float, global_maybe: float):
    """Same global (ok, maybe) pair for every host -- NOT per-machine.

    2026-09-05: tried making 'maybe' the machine's own literal VRAM (so
    TravelBeast's 8GB collapsed to an all-or-nothing OK/BIG split with no
    MAYBE zone at all). That was wrong: ComfyUI routinely runs models larger
    than VRAM via CPU offload, slower but functional, and the global
    maybe=12 was already calibrated for exactly that -- "still probably runs
    on TravelBeast's 8GB via offload, just slower" (see fleet_config.json /
    comfy_fleet.py's own sync-script comment, "Safe for {vram}GB VRAM",
    which deliberately uses one threshold pair sized to the group's weakest
    machine). Treating VRAM as a hard physical ceiling with no offload above
    it swung the headline readiness number from 81% to 38% on a guess about
    hardware behavior, not a confirmed fact -- reverted per direct
    confirmation. This function is now a pass-through; kept as a named seam
    in case per-machine thresholds are wanted later with real numbers.
    """
    return global_ok, global_maybe


def make_thumbnail(src: Path, dst: Path, width: int = 220) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["sips", "-Z", str(width), str(src), "--out", str(dst)],
            check=True, capture_output=True,
        )
        return True
    except Exception:
        return False


def esc(s: str) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=None)
    args = ap.parse_args()

    if args.config:
        config_path = Path(args.config)
    else:
        for cand in (Path.cwd() / "fleet_config.json", Path(__file__).parent / "fleet_config.json"):
            if cand.exists():
                config_path = cand
                break
        else:
            sys.exit("fleet_config.json not found; pass --config")

    config = json.loads(config_path.read_text())
    reports_dir = Path(config["reports_dir"])
    output_dir = Path(config.get("output_dir", reports_dir / "fleet-output"))
    output_dir.mkdir(parents=True, exist_ok=True)
    thumbs_dir = output_dir / "thumbs"

    machines_cfg = config["machines"]
    source_host = next(h for h, m in machines_cfg.items() if m.get("is_source"))
    replica_hosts = [h for h in machines_cfg if h != source_host]
    vram_ok = config["vram_thresholds"]["ok"]
    vram_maybe = config["vram_thresholds"]["maybe"]
    # Per-machine, not global -- see host_vram_thresholds()'s docstring.
    vram_thresh = {
        h: host_vram_thresholds(m.get("vram_gb", 0), vram_ok, vram_maybe)
        for h, m in machines_cfg.items()
    }
    year_filter = config.get("workflow_year_filter", "2026")

    # Same timestamp + _latest.html pattern as fleet_report_*/fleet_explorer_*
    # -- reuses the timestamp off the fleet_report this same comfy_fleet.sh run
    # just wrote, rather than its own datetime.now(), so all files from one
    # scan carry the identical stamp. Also means it's picked up by
    # comfy_fleet.py's --prune-output for free: that function globs *_*.html
    # for an embedded yyyy-mm-dd_HHmm and prunes by run, no pattern list to
    # keep in sync. Computed up front (not just before writing) so the report
    # header can show it, matching fleet_report.html's own "Generated: ..." line.
    existing_reports = sorted(output_dir.glob("fleet_report_*.html"))
    existing_reports = [f for f in existing_reports if f.name != "fleet_report_latest.html"]
    _m = re.search(r"(\d{4}-\d{2}-\d{2}_\d{4})", existing_reports[-1].name) if existing_reports else None
    timestamp = _m.group(1) if _m else datetime.now().strftime("%Y-%m-%d_%H%M")

    # --- Load per-machine data ---
    models = {}       # host -> {filename.lower(): row}
    full_map = {}      # host -> [rows]
    node_types = {}     # host -> [rows]  (every class_type per workflow)
    node_folders = {}   # host -> {"nodes": set, "nodes_disabled": set, "nodes_modified": dict}
    for host in machines_cfg:
        mf = find_latest(reports_dir, host, "Models-*.csv")
        models[host] = {r["filename"].lower(): r for r in load_csv(mf)} if mf else {}
        ff = find_latest(reports_dir, host, "WorkflowMap-*-full_map.csv")
        full_map[host] = load_csv(ff) if ff else []
        nt = find_latest(reports_dir, host, "WorkflowMap-*-node_types.csv")
        node_types[host] = load_csv(nt) if nt else []
        cn = find_latest(reports_dir, host, "CustomNodes-*.txt")
        if cn:
            nodes, nodes_disabled, nodes_modified = load_nodes(cn)
        else:
            nodes, nodes_disabled, nodes_modified = set(), set(), {}
        node_folders[host] = {"nodes": nodes, "nodes_disabled": nodes_disabled, "nodes_modified": nodes_modified}

    # Representative replica for "is it on Models_bare" -- confirmed identical
    # inventory across TB/CWH (same OneDrive-shared folder), so either works;
    # still check per-machine for the readiness table in case that ever drifts.
    rep_host = replica_hosts[0]

    # Live /object_info, same fetch-with-cache-fallback comfy_fleet.py itself
    # uses -- needed to map a workflow's class_type back to the installed
    # package that provides it, and to tell "installed" from "actually loaded".
    object_info = scan_object_info(config, reports_dir)
    classtype_pkg_map = build_classtype_package_map(object_info)
    loaded_by_host = {}
    for host, oi in object_info.items():
        info = oi.get("object_info") or {}
        pkgs = None
        if info:
            pkgs = set()
            for meta in info.values():
                mod = (meta or {}).get("python_module", "")
                if mod.startswith("custom_nodes."):
                    pkgs.add(mod[len("custom_nodes."):].split(".")[0].lower())
        loaded_by_host[host] = pkgs   # None when unavailable+uncached -> node_status falls back

    # --- Fuzzy-match index: what's on the SOURCE machine's disk, by family,
    #     for guessing at a "not found anywhere" model reference. A guess, not
    #     a fact -- clearly labeled as such everywhere it's shown. ---
    family_on_source = defaultdict(list)
    for fn_lower, row in models[source_host].items():
        family_on_source[base_family(fn_lower)].append(row.get("filename", fn_lower))

    def guess_for(model_ref: str):
        fam = base_family(model_ref)
        hits = sorted(set(family_on_source.get(fam, [])) - {model_ref})
        return hits or None

    # --- Which prime workflows exist, and what MODELS do they need, per the
    #     source's own full_map (source has the complete, authoritative set) ---
    src_rows = full_map[source_host]
    si_by_base = defaultdict(list)
    # Starting-Images PNGs must be pulled from BOTH full_map.csv and
    # node_types.csv -- full_map.csv only emits a "starting_images" row when
    # the PS scanner recognized a model reference inside that PNG's embedded
    # workflow, but node_types.csv emits one for every node regardless. A PNG
    # whose embedded graph has zero recognized model refs (e.g. "OneNode -
    # Remove Background - Birefnet.png", found 2026-09-06 -- its own workflow
    # file has a birefnet.safetensors ref, but the *PNG's* embedded copy
    # apparently doesn't) is invisible to full_map.csv alone, so PNG-matching
    # silently failed for it even though the file genuinely exists under the
    # exact right name. Union both sources so this class of miss can't recur.
    for r in src_rows + node_types.get(source_host, []):
        if r.get("source") == "starting_images":
            si_by_base[base_no_tag(r["workflow_file"].split("\\")[-1])].append(
                r["workflow_file"].split("\\")[-1]
            )

    wf_data = defaultdict(lambda: {"models": set(), "node_types": set(), "png": None})
    for r in src_rows:
        if not is_prime_row(r, include_ib=True):
            continue
        wf = r["workflow_file"].split("\\")[-1]
        if machine_tag(wf) == "ib":
            continue  # ImageBeast-only, not a Models_bare target
        if r.get("model_category") == "background-model":
            continue
        wf_data[wf]["models"].add(r["model_ref"].split("\\")[-1])

    # --- Which NODE PACKAGES do those same prime workflows use, per the
    #     source's node_types.csv (every class_type in the graph, not just
    #     model-referencing ones -- most custom nodes never touch a model). ---
    for r in node_types.get(source_host, []):
        if not is_prime_row(r, include_ib=True):
            continue
        wf = r["workflow_file"].split("\\")[-1]
        if machine_tag(wf) == "ib":
            continue
        if wf not in wf_data:
            continue  # a workflow with zero model refs never created an entry above
        pkg = classtype_pkg_map.get(r.get("class_type", "").lower())
        if pkg and pkg not in NO_NODE_PACKAGES:
            wf_data[wf]["node_types"].add(pkg)

    for wf, d in wf_data.items():
        hits = si_by_base.get(base_no_tag(wf))
        if hits:
            d["png"] = hits[0]

    # --- Per workflow: is every model on Models_bare, and every node package
    #     actually LOADED (not just present) on Models_bare's machines? ---
    def on_bare(model_lower, host):
        return model_lower in models[host]

    def node_missing_hosts(pkg):
        out = []
        for h in replica_hosts:
            st = node_status(node_folders[h], pkg, loaded_by_host.get(h))
            if st != "on":
                out.append((h, st))
        return out

    # Per-workflow, per-machine status. Presence (BLOCKED) and size
    # (NOT COMPATIBLE / MARGINAL) are independent problems with independent
    # fixes, and treating them as one either/or status hid real information
    # in both directions -- flagged 2026-09-05 twice, on opposite ends:
    #
    #   "01 Laura - Outpaint.json" showed BLOCKED because two small
    #   (OK-sized) models were missing, with no signal that its largest model
    #   was ALSO too big for TravelBeast's VRAM once copied.
    #
    #   "OneNode - FaceSwap - FLUX2 Klien 9b.json" showed a flat BLOCKED for
    #   a 16.9GB missing model -- reading as "go copy this and it'll work",
    #   when copying it would NOT work: it doesn't fit either machine's VRAM
    #   regardless. BLOCKED alone actively hid the more important fact.
    #
    # So a workflow now carries a SET of tags per machine, not one status --
    # BLOCKED and a size verdict are independent axes and both apply when
    # both are true. Only when nothing is missing AND nothing is oversized
    # does a machine collapse to the single tag READY.
    def wf_status_tags_for_host(missing_here: bool, largest_gb: float, host: str) -> list[str]:
        tags = []
        if missing_here:
            tags.append("BLOCKED")
        verdict = vram_verdict(largest_gb, *vram_thresh.get(host, (vram_ok, vram_maybe)))
        size_tag = {"BIG": "NOT COMPATIBLE", "MAYBE": "MARGINAL"}.get(verdict)
        if size_tag:
            tags.append(size_tag)
        return tags or ["READY"]

    workflows = []
    needed_models = defaultdict(lambda: {"wfs": set()})
    needed_nodes = defaultdict(lambda: {"wfs": set(), "host_status": {}})
    for wf, d in sorted(wf_data.items()):
        missing_models = set()
        per_host_model_miss = {h: False for h in replica_hosts}
        missing_models_by_host = {h: set() for h in replica_hosts}
        for m in sorted(d["models"]):
            ml = m.lower()
            miss_here = [h for h in replica_hosts if not on_bare(ml, h)]
            if miss_here:
                missing_models.add(m)
                needed_models[m]["wfs"].add(wf)
                for h in miss_here:
                    per_host_model_miss[h] = True
                    missing_models_by_host[h].add(m)
        missing_nodes = set()
        per_host_node_miss = {h: False for h in replica_hosts}
        missing_nodes_by_host = {h: set() for h in replica_hosts}
        for pkg in sorted(d["node_types"]):
            miss = node_missing_hosts(pkg)
            if miss:
                missing_nodes.add(pkg)
                needed_nodes[pkg]["wfs"].add(wf)
                for h, st in miss:
                    needed_nodes[pkg]["host_status"][h] = st
                    per_host_node_miss[h] = True
                    missing_nodes_by_host[h].add(pkg)

        total_gb = largest_gb = 0.0
        for m in d["models"]:
            ml = m.lower()
            row = models[source_host].get(ml) or models[rep_host].get(ml)
            sz = float(row["size_gb"]) if row else 0.0
            total_gb += sz
            largest_gb = max(largest_gb, sz)

        host_status = {
            h: wf_status_tags_for_host(per_host_model_miss[h] or per_host_node_miss[h], largest_gb, h)
            for h in replica_hosts
        }
        all_tags = sorted({t for tags in host_status.values() for t in tags})

        workflows.append({
            "name": wf, "png": d["png"],
            "models": sorted(d["models"]), "missing_models": sorted(missing_models),
            "node_types": sorted(d["node_types"]), "missing_nodes": sorted(missing_nodes),
            "missing_models_by_host": {h: sorted(v) for h, v in missing_models_by_host.items()},
            "missing_nodes_by_host": {h: sorted(v) for h, v in missing_nodes_by_host.items()},
            "host_status": host_status, "all_tags": all_tags,
            "runnable": all(tags == ["READY"] for tags in host_status.values()),
            "total_gb": total_gb, "largest_gb": largest_gb,
        })

    # Counts by tag -- NOT mutually exclusive any more (a workflow can be
    # both BLOCKED and NOT COMPATIBLE: a missing model that's also too big
    # to fit even once copied -- see wf_status_tags_for_host's docstring for
    # why collapsing those into one status actively hid that fact). A
    # workflow tagged with more than one problem counts in every card it
    # applies to, so these four numbers can sum to more than total_count.
    total_count = len(workflows)
    runnable_count = sum(1 for w in workflows if w["runnable"])
    blocked_count = sum(1 for w in workflows if "BLOCKED" in w["all_tags"])
    incompatible_count = sum(1 for w in workflows if "NOT COMPATIBLE" in w["all_tags"])
    marginal_count = sum(1 for w in workflows if "MARGINAL" in w["all_tags"])

    # --- Needed-model rows: copy (exact match on source) / guess (fuzzy match
    #     only) / download (no match anywhere, by name or family) ---
    need_rows = []
    for m, info in needed_models.items():
        ml = m.lower()
        src_row = models[source_host].get(ml)
        on_source = src_row is not None
        guesses = None if on_source else guess_for(m)
        if on_source:
            size_gb, category = float(src_row["size_gb"]), src_row.get("category", "")
        elif guesses:
            g_row = models[source_host].get(guesses[0].lower())
            size_gb, category = (float(g_row["size_gb"]), g_row.get("category", "")) if g_row else (0.0, "")
        else:
            size_gb, category = 0.0, ""
        need_rows.append({
            "model": m, "on_source": on_source, "guesses": guesses,
            "size_gb": size_gb, "category": category, "unblocks": len(info["wfs"]),
            "verdict_tb": vram_verdict(size_gb, *vram_thresh.get("TRAVELBEAST", (vram_ok, vram_maybe))),
            "verdict_cwh": vram_verdict(size_gb, *vram_thresh.get("CHATWORKHORSE", (vram_ok, vram_maybe))),
        })
    need_rows.sort(key=lambda x: (-x["unblocks"], -x["size_gb"]))

    copy_rows = [r for r in need_rows if r["on_source"]]
    guess_rows = [r for r in need_rows if not r["on_source"] and r["guesses"]]
    download_rows = [r for r in need_rows if not r["on_source"] and not r["guesses"]]
    copy_gb = sum(r["size_gb"] for r in copy_rows)

    # --- Needed-node rows, with the same real-vs-guess distinction: a package
    #     "off" everywhere gets checked against every OTHER installed package
    #     name on the replicas/source for a close-spelling variant (a fork, a
    #     manual rename, capitalization drift) -- also a guess, not a fact. ---
    all_known_pkgs = set()
    for h in machines_cfg:
        all_known_pkgs |= node_folders[h]["nodes"]

    _PKG_PREFIX_RE = re.compile(r"^comfyui[-_]?", re.IGNORECASE)

    def pkg_compare_key(name: str) -> str:
        """Almost every package here starts with 'comfyui-' or 'comfyui_', so
        raw string similarity on the full name is dominated by that shared
        boilerplate and produces nonsense matches -- confirmed 2026-09-05:
        'comfyui-angelo' vs 'comfyui-manager' scored 0.83 (comfortably over a
        0.72 cutoff) on the full names, but 0.61 once the common prefix is
        stripped, which is what actually distinguishes them. Compare on the
        stripped form; a cutoff that would pass unrelated packages sharing
        only the prefix should fail here."""
        return _PKG_PREFIX_RE.sub("", name.lower())

    node_rows = []
    for pkg, info in needed_nodes.items():
        host_status = info["host_status"]
        fully_off = all(st == "off" for st in host_status.values())
        guesses = None
        if fully_off:
            key = pkg_compare_key(pkg)
            candidates = {other: pkg_compare_key(other) for other in all_known_pkgs if other != pkg}
            close_keys = difflib.get_close_matches(key, set(candidates.values()), n=3, cutoff=0.8)
            guesses = sorted({o for o, k in candidates.items() if k in close_keys}) or None
        node_rows.append({
            "package": pkg, "unblocks": len(info["wfs"]), "guesses": guesses,
            "status_tb": host_status.get("TRAVELBEAST", "on") if "TRAVELBEAST" in machines_cfg else "?",
            "status_cwh": host_status.get("CHATWORKHORSE", "on") if "CHATWORKHORSE" in machines_cfg else "?",
        })
    node_rows.sort(key=lambda x: -x["unblocks"])

    # --- Thumbnails: only for PNGs actually referenced by a workflow below ---
    si_dir = Path(config.get("prime_starting_images_dir", ""))
    thumb_map = {}
    if si_dir.exists():
        wanted = {w["png"] for w in workflows if w["png"]}
        for png_name in wanted:
            src = si_dir / png_name
            if not src.exists():
                continue
            dst = thumbs_dir / png_name
            if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
                make_thumbnail(src, dst)
            if dst.exists():
                thumb_map[png_name] = f"thumbs/{png_name}"

    # ---------------------------------------------------------------------
    # Render
    # ---------------------------------------------------------------------
    def verdict_badge(v):
        color = {"OK": "#2ecc71", "MAYBE": "#f39c12", "BIG": "#e74c3c", "?": "#888"}[v]
        return f'<span style="background:{color};color:white;padding:2px 8px;border-radius:4px;font-size:0.85em">{v}</span>'

    def node_status_badge(st):
        color = {"on": "#2ecc71", "disabled": "#f39c12", "installed-not-loaded": "#c0392b", "off": "#e74c3c"}.get(st, "#888")
        text = {"on": "OK", "disabled": "DISABLED", "installed-not-loaded": "NOT LOADED", "off": "MISSING"}.get(st, st)
        return f'<span style="background:{color};color:white;padding:2px 8px;border-radius:4px;font-size:0.85em">{text}</span>'

    def guess_note(guesses, label="model"):
        if not guesses:
            return ('<span style="background:#e74c3c;color:white;padding:2px 8px;border-radius:4px">'
                    f'NOT FOUND — no {label} on the fleet by this name or a close variant</span>')
        shown = ", ".join(esc(g) for g in guesses[:3])
        return (f'<span style="background:#f39c12;color:white;padding:2px 8px;border-radius:4px">GUESS — unconfirmed</span> '
                f'<span style="color:#888;font-size:0.85em">closest match on {source_host}: <strong>{shown}</strong> '
                f'— not proven to be the same {label}, verify by hand</span>')

    # id maps -- the link the click-to-highlight JS below walks in every direction.
    model_slug = {r["model"]: f"m-{slug(r['model'])}" for r in need_rows}
    node_slug = {r["package"]: f"n-{slug(r['package'])}" for r in node_rows}
    wf_slug = {w["name"]: f"w-{slug(w['name'])}" for w in workflows}

    rows_html = ""
    for r in need_rows:
        if r["on_source"]:
            source_badge = '<span style="color:#2ecc71">on ImageBeast — copy</span>'
        else:
            source_badge = guess_note(r["guesses"], "model")
        unblocked_wfs = [w["name"] for w in workflows if r["model"] in w["missing_models"]]
        wf_ids = " ".join(wf_slug[n] for n in unblocked_wfs)
        rows_html += (
            f'<tr id="{model_slug[r["model"]]}" class="model-row" data-wfs="{esc(wf_ids)}" '
            f'onclick="selectItem(\'{model_slug[r["model"]]}\')" style="cursor:pointer">'
            f'<td style="font-family:monospace">{esc(r["model"])}</td>'
            f'<td>{esc(r["category"])}</td>'
            f'<td>{r["size_gb"]:.2f} GB{" (guess)" if r["guesses"] and not r["on_source"] else ""}</td>'
            f'<td>{source_badge}</td>'
            f'<td>{verdict_badge(r["verdict_tb"])}</td>'
            f'<td>{verdict_badge(r["verdict_cwh"])}</td>'
            f'<td>{r["unblocks"]} workflow(s)</td></tr>'
        )

    node_rows_html = ""
    for r in node_rows:
        unblocked_wfs = [w["name"] for w in workflows if r["package"] in w["missing_nodes"]]
        wf_ids = " ".join(wf_slug[n] for n in unblocked_wfs)
        guess_html = ""
        if r["guesses"]:
            guess_html = (f'<br><span style="color:#f39c12;font-size:0.8em">GUESS — unconfirmed, close spelling to: '
                          f'{", ".join(esc(g) for g in r["guesses"])}</span>')
        node_rows_html += (
            f'<tr id="{node_slug[r["package"]]}" class="node-row" data-wfs="{esc(wf_ids)}" '
            f'onclick="selectItem(\'{node_slug[r["package"]]}\')" style="cursor:pointer">'
            f'<td style="font-family:monospace">{esc(r["package"])}{guess_html}</td>'
            f'<td>{node_status_badge(r["status_tb"])}</td>'
            f'<td>{node_status_badge(r["status_cwh"])}</td>'
            f'<td>{r["unblocks"]} workflow(s)</td></tr>'
        )

    wf_html = ""
    _severity = {"BLOCKED": 0, "NOT COMPATIBLE": 1, "MARGINAL": 2, "READY": 3}
    for w in sorted(workflows, key=lambda x: (min(_severity[s] for s in x["all_tags"]), x["name"].lower())):
        thumb = thumb_map.get(w["png"])
        img_html = (f'<img src="{esc(thumb)}" style="width:110px;border-radius:4px;vertical-align:middle;margin-right:10px">'
                    if thumb else
                    '<span style="display:inline-block;width:110px;height:80px;background:#eee;border-radius:4px;'
                    'vertical-align:middle;margin-right:10px;text-align:center;line-height:80px;color:#999;font-size:0.75em">'
                    'no PNG</span>')
        wf_status_colors = {"READY": "#2ecc71", "MARGINAL": "#f39c12", "NOT COMPATIBLE": "#8e44ad", "BLOCKED": "#e74c3c"}
        host_abbrev = {"TRAVELBEAST": "TB", "CHATWORKHORSE": "CWH"}
        status = " ".join(
            # A host with more than one tag (e.g. BLOCKED + NOT COMPATIBLE)
            # gets one compound badge, colored by the worse of the two, so
            # "missing AND too big" reads as one fact, not a hidden second one.
            f'<span style="background:{wf_status_colors[min(tags, key=lambda t: _severity[t])]};'
            f'color:white;padding:2px 8px;border-radius:4px;font-size:0.85em">'
            f'{host_abbrev.get(h, h)}: {" + ".join(tags)}</span>'
            for h, tags in w["host_status"].items()
        )
        tags_attr = " ".join(t.replace(" ", "_") for t in w["all_tags"])
        # Missing items are shown PER HOST, not as one combined list -- a
        # package/model missing only on CWH (say) explains only CWH's
        # BLOCKED badge, and a flat shared list can't say that. Flagged
        # 2026-09-06 on "Edit Angelo...": the single line "node: comfyui-
        # angelo" gave no hint that TravelBeast already has it and only
        # ChatWorkhorse is missing it, so TB's plain MARGINAL (vs CWH's
        # BLOCKED + MARGINAL) looked unexplained.
        missing_lines_by_host = {}
        for h in replica_hosts:
            items = []
            for m in w["missing_models_by_host"].get(h, []):
                mid = model_slug.get(m, "")
                items.append(
                    f'<span class="need-link" onclick="event.stopPropagation(); selectItem(\'{mid}\')" '
                    f'style="font-family:monospace;font-size:0.85em;color:#e74c3c;cursor:pointer;text-decoration:underline dotted">'
                    f'model: {esc(m)}</span>'
                )
            for n in w["missing_nodes_by_host"].get(h, []):
                nid = node_slug.get(n, "")
                items.append(
                    f'<span class="need-link" onclick="event.stopPropagation(); selectItem(\'{nid}\')" '
                    f'style="font-family:monospace;font-size:0.85em;color:#c0392b;cursor:pointer;text-decoration:underline dotted">'
                    f'node: {esc(n)}</span>'
                )
            if items:
                missing_lines_by_host[h] = items
        missing_html = "<br>".join(
            f'<span style="color:#555;font-size:0.85em">{host_abbrev.get(h, h)} missing:</span> ' + ", ".join(items)
            for h, items in missing_lines_by_host.items()
        )
        need_ids = " ".join(
            [model_slug[m] for m in w["missing_models"] if m in model_slug] +
            [node_slug[n] for n in w["missing_nodes"] if n in node_slug]
        )
        wf_html += (
            f'<div id="{wf_slug[w["name"]]}" class="wf-row" data-need="{esc(need_ids)}" '
            f'data-tags="{tags_attr}" '
            f'onclick="selectItem(\'{wf_slug[w["name"]]}\')" '
            'style="display:flex;align-items:center;padding:8px 4px;border-bottom:1px solid #eee;cursor:pointer">'
            f'{img_html}'
            f'<div style="flex:1"><strong>{esc(w["name"])}</strong> {status}<br>'
            f'<span style="color:#888;font-size:0.85em">{len(w["models"])} model(s) · '
            f'{w["total_gb"]:.1f} GB total · {w["largest_gb"]:.1f} GB largest single model · '
            f'{len(w["node_types"])} node package(s)</span>'
            f'{"<br>" + missing_html if missing_html else ""}'
            '</div></div>'
        )

    pct = round(100 * runnable_count / total_count) if total_count else 0
    color = "#2ecc71" if pct >= 90 else "#f39c12" if pct >= 70 else "#e74c3c"

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Needed in Bare</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 24px;
          background: #f7f8fa; color: #222; }}
  h1 {{ margin: 0 0 4px; }}
  .timestamp {{ color: #888; font-size: 0.85em; }}
  .ts {{ color: #888; font-size: 0.85em; margin-bottom: 20px; }}
  .summary {{ display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }}
  .card {{ background: white; border-radius: 8px; padding: 16px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  .big {{ font-size: 2em; font-weight: bold; }}
  h2 {{ margin-top: 32px; }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden;
           box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  th, td {{ text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 0.92em; }}
  th {{ background: #2c3e50; color: white; }}
  .note {{ color: #888; font-size: 0.85em; }}
  .model-row:hover, .wf-row:hover, .node-row:hover {{ background: #f5f7fa; }}
  .model-row.selected, .wf-row.selected, .node-row.selected {{ background: #fff8e1 !important; box-shadow: inset 3px 0 0 #f39c12; }}
  .model-row.highlighted, .wf-row.highlighted, .node-row.highlighted {{ background: #fffbea; }}
  .model-row.dimmed, .wf-row.dimmed, .node-row.dimmed {{ opacity: 0.35; }}
  .clear-btn {{ padding: 4px 12px; border-radius: 14px; border: 1px solid #ccc; background: white;
                color: #666; cursor: pointer; font-size: 0.85em; }}
  .clear-btn:hover {{ border-color: #e74c3c; color: #e74c3c; }}
  .info-bar {{ position: sticky; top: 0; background: #2c3e50; color: white; padding: 8px 16px;
               border-radius: 6px; margin-bottom: 12px; font-size: 0.88em; display: flex;
               justify-content: space-between; align-items: center; z-index: 10; }}
  .filter-bar {{ display: flex; align-items: center; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }}
  .filter-chip {{ padding: 4px 12px; border-radius: 14px; border: 1.5px solid #ccc; background: white;
                 cursor: pointer; font-size: 0.85em; opacity: 0.4; }}
  .filter-chip.active {{ opacity: 1; font-weight: 600; }}
  .wf-row.filtered-out {{ display: none; }}
</style>
</head>
<body>
<h1>Needed in Bare</h1>
<p class="timestamp">Generated: {timestamp} &nbsp;|&nbsp; Year filter: {year_filter}</p>
<p class="ts">What to copy/download, and what custom nodes to install, to make the prime workflow set —
root-level <code>workflows\\*.json</code>, excluding ImageBeast-only <code>(i)</code> files — run on
Models_bare (shared by {", ".join(replica_hosts)}). Click any model, node, or workflow to see how they connect.</p>

<div class="info-bar" id="infoBar">
  <span id="infoText">Click a model, a custom node, or a workflow to see what connects to what.</span>
  <button class="clear-btn" onclick="clearSelection()">Clear</button>
</div>

<div class="summary">
  <div class="card"><div class="big" style="color:{color}">{pct}%</div><div>{runnable_count}/{total_count} prime workflows ready on both machines</div></div>
  <div class="card"><div class="big" style="color:{'#8e44ad' if incompatible_count else '#2ecc71'}">{incompatible_count}</div><div>NOT COMPATIBLE — everything needed is present, but won't fit even then; copying more won't help</div></div>
  <div class="card"><div class="big" style="color:{'#f39c12' if marginal_count else '#2ecc71'}">{marginal_count}</div><div>MARGINAL — nothing missing, but the largest model needs RAM offload to run</div></div>
  <div class="card"><div class="big" style="color:{'#e74c3c' if blocked_count else '#2ecc71'}">{blocked_count}</div><div>BLOCKED — something is actually missing (models and/or nodes)</div></div>
  <div class="card"><div class="big">{len(copy_rows)}</div><div>models to copy from {source_host} ({copy_gb:.1f} GB)</div></div>
  <div class="card"><div class="big" style="color:{'#f39c12' if guess_rows else '#2ecc71'}">{len(guess_rows)}</div><div>models — no exact match, only a fuzzy guess</div></div>
  <div class="card"><div class="big" style="color:{'#e74c3c' if download_rows else '#2ecc71'}">{len(download_rows)}</div><div>models genuinely not found anywhere</div></div>
  <div class="card"><div class="big" style="color:{'#c0392b' if node_rows else '#2ecc71'}">{len(node_rows)}</div><div>custom node package(s) to install/fix</div></div>
</div>
<p class="note" style="margin-bottom:20px"><strong style="color:#e74c3c">BLOCKED</strong> = something needed isn't present/loaded — fixable by copying a model or
installing a node. <strong style="color:#8e44ad">NOT COMPATIBLE</strong> = everything needed IS present, but the largest model
exceeds that machine's own VRAM — copying more won't help, only a smaller/quantized variant will.
<strong style="color:#f39c12">MARGINAL</strong> = fits, but ComfyUI would need to offload to system RAM.</p>

<h2>Models needed</h2>
<p class="note">Ordered by how many workflows each unblocks. VRAM verdict is per-model size only —
a workflow's <em>total</em> model footprint (shown below) is what actually has to fit, and ComfyUI can
offload to system RAM, so "BIG" often means slow rather than impossible.
<strong style="color:#f39c12">Amber "GUESS" entries are unconfirmed</strong> — the exact filename referenced
isn't found anywhere on the fleet, but something with the same base name (quant/precision suffix stripped)
is on {source_host}. That's a hint the workflow may just need re-pointing at a renamed file, not proof —
verify before assuming it's the same model.</p>
<table>
<tr><th>Model</th><th>Category</th><th>Size</th><th>Source</th><th>TravelBeast (8GB)</th><th>ChatWorkhorse (12GB)</th><th>Unblocks</th></tr>
{rows_html}
</table>

<h2>Custom nodes needed</h2>
<p class="note">Node packages used by the prime workflow set (from every node in the graph, not just
model-loading ones) that are missing, disabled, or installed-but-failing-to-load on a replica.
<strong style="color:#f39c12">Amber GUESS entries</strong> are a close-spelling match to a DIFFERENT installed
package name — a possible fork/rename, not confirmed to provide the same nodes.</p>
<table>
<tr><th>Package</th><th>TravelBeast</th><th>ChatWorkhorse</th><th>Unblocks</th></tr>
{node_rows_html if node_rows_html else '<tr><td colspan="4" style="color:#2ecc71">All node packages needed by the prime set are loaded on both replicas.</td></tr>'}
</table>

<h2>Workflows</h2>
<p class="note">Thumbnail is the matching Starting Images PNG when one exists by name (machine-tag-insensitive
match) — most blocked workflows don't have one, since Starting Images only covers workflows that already work.</p>
<div class="filter-bar" id="filterBar">
  <span style="color:#888;font-size:0.85em;margin-right:4px">Show:</span>
  <button class="filter-chip active" data-tag="READY" style="border-color:#2ecc71;color:#2ecc71" onclick="toggleFilter(this)">Ready</button>
  <button class="filter-chip active" data-tag="BLOCKED" style="border-color:#e74c3c;color:#e74c3c" onclick="toggleFilter(this)">Blocked</button>
  <button class="filter-chip active" data-tag="MARGINAL" style="border-color:#f39c12;color:#f39c12" onclick="toggleFilter(this)">Marginal</button>
  <button class="filter-chip active" data-tag="NOT_COMPATIBLE" style="border-color:#8e44ad;color:#8e44ad" onclick="toggleFilter(this)">Not Compatible</button>
  <button class="clear-btn" style="margin-left:8px" onclick="resetFilters()">Show all</button>
  <span id="filterCount" style="color:#888;font-size:0.85em;margin-left:10px"></span>
</div>
{wf_html}

<script>
let selected = null;
const ALL_SEL = '.model-row, .wf-row, .node-row';

function clearSelection() {{
  selected = null;
  document.querySelectorAll(ALL_SEL).forEach(el => el.classList.remove('selected', 'highlighted', 'dimmed'));
  document.getElementById('infoText').textContent =
    'Click a model, a custom node, or a workflow to see what connects to what.';
}}

function applyHighlight(sourceId, targetIds, infoText) {{
  document.querySelectorAll(ALL_SEL).forEach(el => el.classList.remove('selected', 'highlighted', 'dimmed'));
  const source = document.getElementById(sourceId);
  if (source) source.classList.add('selected');
  const targetSet = new Set(targetIds.filter(Boolean));
  document.querySelectorAll(ALL_SEL).forEach(el => {{
    if (el.id === sourceId) return;
    if (targetSet.has(el.id)) el.classList.add('highlighted');
    else el.classList.add('dimmed');
  }});
  document.getElementById('infoText').textContent = infoText;
  if (targetIds.length) {{
    const first = document.getElementById(targetIds[0]);
    if (first) first.scrollIntoView({{behavior: 'smooth', block: 'nearest'}});
  }}
}}

// One entry point for models, nodes, AND workflows -- a model/node row links
// forward to the workflows it unblocks (data-wfs); a workflow row links
// forward to the models+nodes it needs (data-need). Same click handler either
// way, since both are just "this id's data attribute names the other side".
function selectItem(id) {{
  if (selected === id) {{ clearSelection(); return; }}
  selected = id;
  const row = document.getElementById(id);
  if (!row) return;
  const isWf = row.classList.contains('wf-row');
  const ids = (isWf ? row.dataset.need : row.dataset.wfs || '').split(' ').filter(Boolean);
  const label = isWf ? row.querySelector('strong').textContent : row.querySelector('td').textContent;
  const kind = isWf ? 'needs' : 'unblocks';
  applyHighlight(id, ids,
    ids.length ? `"${{label}}" ${{kind}} ${{ids.length}} item(s) — highlighted.`
               : `"${{label}}" — nothing on the other side to show.`);
}}

let activeTags = new Set(['READY', 'BLOCKED', 'MARGINAL', 'NOT_COMPATIBLE']);

function applyFilters() {{
  let visible = 0, total = 0;
  document.querySelectorAll('.wf-row').forEach(el => {{
    total++;
    const tags = (el.dataset.tags || '').split(' ').filter(Boolean);
    const show = tags.some(t => activeTags.has(t));
    el.classList.toggle('filtered-out', !show);
    el.style.display = show ? '' : 'none';  // inline style="display:flex" on the row beats a CSS class rule, so set it directly
    if (show) visible++;
  }});
  const countEl = document.getElementById('filterCount');
  if (countEl) countEl.textContent = visible === total ? `${{total}} workflow(s)` : `showing ${{visible}} of ${{total}} workflow(s)`;
}}

function toggleFilter(btn) {{
  const tag = btn.dataset.tag;
  if (activeTags.has(tag)) {{ activeTags.delete(tag); btn.classList.remove('active'); }}
  else {{ activeTags.add(tag); btn.classList.add('active'); }}
  applyFilters();
}}

function resetFilters() {{
  activeTags = new Set(['READY', 'BLOCKED', 'MARGINAL', 'NOT_COMPATIBLE']);
  document.querySelectorAll('.filter-chip').forEach(b => b.classList.add('active'));
  applyFilters();
}}

applyFilters();
</script>

</body>
</html>"""

    out_path = output_dir / f"Needed_In_Bare_{timestamp}.html"
    out_path.write_text(html)
    latest_path = output_dir / "Needed_In_Bare_latest.html"
    shutil.copy2(out_path, latest_path)
    print(f"Written: {out_path}")
    print(f"Written: {latest_path}")
    print(f"  {runnable_count}/{total_count} prime workflows runnable on Models_bare ({pct}%)")
    print(f"  models: {len(copy_rows)} to copy ({copy_gb:.2f} GB), {len(guess_rows)} guess-only, {len(download_rows)} not found at all")
    print(f"  nodes: {len(node_rows)} package(s) needing install/fix")
    print(f"  thumbnails: {len(thumb_map)}/{len({w['png'] for w in workflows if w['png']})}")


if __name__ == "__main__":
    main()
