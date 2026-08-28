#!/usr/bin/env python3
"""
audit_tb_c_pairs.py
One-time audit: for every workflow that exists as both a (tb) and a (c)
variant of the same base name, determine whether they're actually
identical or genuinely different -- to inform collapsing the (tb)/(c)
tag distinction into a single (bare) tag (TravelBeast and ChatWorkhorse
share Models_bare, so in principle they should need the same models).

Not part of the standing report/explorer pipeline -- run manually, once,
review the output, then decide what to rename/merge/delete.

Usage:
    python3 audit_tb_c_pairs.py [workflows_dir]
    (defaults to the workflows dir from fleet_config.json's prime_workflows_dir)
"""

import json
import re
import sys
from pathlib import Path
from collections import Counter, defaultdict

MODEL_EXT = (".safetensors", ".gguf", ".pth", ".pt", ".bin", ".ckpt")
MODEL_KEYS = {"ckpt_name", "unet_name", "vae_name", "clip_name", "clip_name1",
              "clip_name2", "clip_name3", "lora_name", "control_net_name",
              "model", "upscale_model_name", "ipadapter", "pulid_file",
              "gguf_name", "model_name", "bg_removal_name"}

TAG_RE = re.compile(r"\s*\(\s*(tb|c|ib|i)\s*\)\s*$", re.IGNORECASE)


def strip_tag(stem: str):
    """Return (base_name, tag) -- tag is 'tb'/'c'/'ib'/None."""
    m = TAG_RE.search(stem)
    if not m:
        return stem.strip(), None
    tag = m.group(1).lower()
    tag = "ib" if tag == "i" else tag
    return stem[: m.start()].strip(), tag


def load_workflow(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception as e:
        return None


def extract_signature(wf: dict):
    """
    Returns (model_refs: set[str], node_type_counts: Counter, node_count: int)
    Handles both UI export format ({"nodes":[...]}) and API/prompt format
    (dict keyed by node id, each with class_type/inputs).
    """
    models = set()
    type_counts = Counter()

    if isinstance(wf, dict) and "nodes" in wf:
        for node in wf.get("nodes", []):
            t = node.get("type", "")
            type_counts[t] += 1
            wv = node.get("widgets_values", [])
            if isinstance(wv, list):
                for v in wv:
                    if isinstance(v, str) and v.lower().endswith(MODEL_EXT):
                        models.add(v.replace("\\", "/").split("/")[-1].lower())
            inputs = node.get("inputs", {})
            if isinstance(inputs, dict):
                for k, v in inputs.items():
                    if k in MODEL_KEYS and isinstance(v, str) and v:
                        models.add(v.replace("\\", "/").split("/")[-1].lower())
    elif isinstance(wf, dict):
        # API/prompt format: dict of node_id -> {class_type, inputs}
        for node_id, node in wf.items():
            if not isinstance(node, dict):
                continue
            t = node.get("class_type", "")
            type_counts[t] += 1
            inputs = node.get("inputs", {})
            if isinstance(inputs, dict):
                for k, v in inputs.items():
                    if isinstance(v, str) and v.lower().endswith(MODEL_EXT):
                        models.add(v.replace("\\", "/").split("/")[-1].lower())
                    elif k in MODEL_KEYS and isinstance(v, str) and v:
                        models.add(v.replace("\\", "/").split("/")[-1].lower())

    node_count = sum(type_counts.values())
    return models, type_counts, node_count


def classify(sig_tb, sig_c):
    models_tb, types_tb, n_tb = sig_tb
    models_c, types_c, n_c = sig_c

    if models_tb == models_c and types_tb == types_c:
        return "IDENTICAL", "Same models, same node graph."

    if models_tb == models_c:
        # same models, different node structure -- likely VRAM/bypass tweaks
        diff_types = set(types_tb.keys()) ^ set(types_c.keys())
        common_diff = {t: (types_tb.get(t, 0), types_c.get(t, 0))
                        for t in (set(types_tb) | set(types_c))
                        if types_tb.get(t, 0) != types_c.get(t, 0)}
        detail = f"Same {len(models_tb)} models; node-count differs on: " + \
                  ", ".join(f"{t} (tb={a} c={b})" for t, (a, b) in list(common_diff.items())[:6])
        return "SAME MODELS, DIFFERENT GRAPH", detail

    only_tb = models_tb - models_c
    only_c = models_c - models_tb
    detail_parts = []
    if only_tb:
        detail_parts.append(f"only in (tb): {', '.join(sorted(only_tb))}")
    if only_c:
        detail_parts.append(f"only in (c): {', '.join(sorted(only_c))}")
    return "DIFFERENT MODELS", "; ".join(detail_parts)


def main():
    if len(sys.argv) > 1:
        wf_dir = Path(sys.argv[1])
    else:
        import glob
        cfg_candidates = glob.glob(str(Path.home() / "OneDrive/**/fleet_config.json"), recursive=True) or \
                          glob.glob(str(Path.home() / "Library/CloudStorage/OneDrive-Personal/**/fleet_config.json"), recursive=True)
        if not cfg_candidates:
            print("Could not find fleet_config.json automatically. Pass the workflows dir explicitly.")
            sys.exit(1)
        cfg = json.loads(Path(cfg_candidates[0]).read_text())
        wf_dir = Path(cfg["prime_workflows_dir"])

    print(f"Scanning: {wf_dir}\n")

    # Only root-level workflows (matches how prime coverage scoring works) --
    # skip "999 Other" experiments/archives.
    groups = defaultdict(dict)  # base_name -> {tag: path}
    for jf in sorted(wf_dir.glob("*.json")):
        base, tag = strip_tag(jf.stem)
        if tag in ("tb", "c"):
            groups[base][tag] = jf

    pairs = {base: g for base, g in groups.items() if "tb" in g and "c" in g}
    print(f"Found {len(pairs)} (tb)/(c) pairs (out of {len(groups)} tb/c-tagged base names)\n")
    print("=" * 100)

    results = Counter()
    for base in sorted(pairs):
        g = pairs[base]
        wf_tb = load_workflow(g["tb"])
        wf_c = load_workflow(g["c"])
        if wf_tb is None or wf_c is None:
            print(f"[SKIP - bad JSON] {base}")
            continue
        sig_tb = extract_signature(wf_tb)
        sig_c = extract_signature(wf_c)
        verdict, detail = classify(sig_tb, sig_c)
        results[verdict] += 1
        print(f"[{verdict}] {base}")
        print(f"    tb: {g['tb'].name}")
        print(f"    c : {g['c'].name}")
        print(f"    {detail}")
        print()

    print("=" * 100)
    print("SUMMARY")
    for verdict, count in results.most_common():
        print(f"  {verdict}: {count}")

    # Orphans -- only one side of a would-be pair exists
    orphans_tb = sorted(base for base, g in groups.items() if "tb" in g and "c" not in g)
    orphans_c = sorted(base for base, g in groups.items() if "c" in g and "tb" not in g)
    print(f"\n  (tb)-only, no (c) counterpart: {len(orphans_tb)}")
    print(f"  (c)-only, no (tb) counterpart: {len(orphans_c)}")


if __name__ == "__main__":
    main()
