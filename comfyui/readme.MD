# ComfyUI Fleet Management

Scan, document, and cross-reference models / custom nodes / workflows across a
three-machine ComfyUI fleet, then answer the questions that actually matter:
**what can each machine run, what is it missing, and what is it storing for no reason.**

Everything runs from the Mac. The Windows machines are scanned over SSH (Tailscale);
their ComfyUI instances are queried live over HTTP. Output is a set of CSVs, an HTML
report, an interactive explorer, and ready-to-run `.bat` scripts.

---

## Goals

These are the reasons this project exists — read them before changing anything, since
most design decisions trace back to one of them.

**1. Get TravelBeast ready for travel.**
TravelBeast (8GB VRAM laptop) has to work *standalone and offline*, away from
ImageBeast. Everything else here is ultimately in service of answering: "if I close the
lid and get on a plane, what breaks?" ChatWorkhorse gets the same treatment as a
secondary target.

**2. Make sure models / workflows / nodes are well documented and captured.**
The fleet's state should be inspectable without RDP-ing into three machines and
eyeballing folders. Every model file, every custom node package, every workflow →
model reference, and every node class-type used in every workflow gets captured to CSV
on a repeatable schedule.

**3. Identify what is *not* being used — and reclaim it.**
Disk fills up with models downloaded once for an experiment and never touched again.
The pipeline distinguishes "on disk but nothing references it" from "referenced but
never actually run" and generates cleanup scripts for both.

**4. Identify what *is* being used, and where.**
The inverse, and the harder half: prove a model or node package is genuinely in use by
pointing at real generated output, not at a file's modification date. That evidence is
what makes the gap lists and the deletion lists trustworthy.

### The core principle: output evidence beats every other signal

Repeatedly through this project, the intuitive signal turned out to be wrong:

- **A workflow file's edit date** doesn't mean it was run. Templates sit untouched for
  months while being executed daily.
- **A model/node folder's mtime** means "installed or updated," not "used."
- **A hand-curated priority list** goes stale and gets forgotten. (There used to be a
  `priority_custom_nodes` list in the config. When real usage data finally existed, it
  showed 5 of its 6 entries had *zero* usage evidence, while genuinely hot packages
  weren't on it at all. It was removed.)
- **Folder location** ("this lives in `999 Other/Experiments`, so it must be junk")
  hides real usage. An `ideogram4` model filed under Experiments had 18 real outputs.

The signal that holds up: **did this thing appear in the workflow embedded inside an
actual generated output PNG, and when.** That is `OUTPUT_EVIDENCE_SOURCES`
(`png-outputs`, `starting_images`, `workflows-png`) and it is the basis for every
"recently used" / "never used" claim in the reports. `STALE_OUTPUT_DAYS = 90` is the
default "recent" window (~3 months).

---

## TL;DR — Running It

```bash
~/repos/scripts/comfyui/comfy_fleet.sh
```
SSHes into all three machines over Tailscale, runs three PowerShell scan scripts on
each, then runs the Mac-side analysis. **Budget 15–45 min** (sequential, 3 machines).

```bash
comfy_fleet.sh --local-only          # skip SSH scan, re-analyze already-synced CSVs (fast, ~30s)
comfy_fleet.sh tb                    # scan only TravelBeast, then analyze
comfy_fleet.sh ib cwh                # scan a subset
comfy_fleet.sh --local-only --year 2025
```
Aliases: `ib`=ImageBeast, `cwh`=ChatWorkhorse, `tb`=TravelBeast.

**Re-running just the analysis** (no scan) is the normal loop while iterating on
`comfy_fleet.py` — all inputs are already on disk:
```bash
/opt/homebrew/bin/python3 comfy_fleet.py --config "$HOME/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports/fleet_config.json"
```
> Use the **Homebrew** interpreter explicitly. Apple's `/usr/bin/python3` (3.9) chokes
> on this file's PEP 604 `str | None` type hints.

**Read the output:** http://mb.ldmathes.cc:5050/fleet_report_latest.html
(Tailscale/LAN only — see *Serving* below), or open
`fleet-output/fleet_report_latest.html` directly.

**Housekeeping** (dry-run unless `--confirm-prune`; keeps newest 3 runs):
```bash
python3 comfy_fleet.py --prune-output                    # show what's stale
python3 comfy_fleet.py --prune-output --confirm-prune
python3 comfy_fleet.py --prune-output --confirm-prune --keep-runs 5
```

---

## The Fleet

| Machine       | GPU  | VRAM | Role                                        |
|---------------|------|------|---------------------------------------------|
| IMAGEBEAST    | 5090 | 32GB | **Source of truth.** Runs everything.       |
| CHATWORKHORSE | 3060 | 12GB | Shares `Models_bare` with TravelBeast       |
| TRAVELBEAST   | 5060 |  8GB | **The travel target.** Must work offline.   |

**Asymmetry that matters:** ImageBeast holds the only copy of most models. Chat and
Travel are *replicas* — they share one OneDrive `Models_bare` folder, junctioned into
ComfyUI on both. Deleting a model on Travel is reversible (re-sync from IB); deleting
one on ImageBeast is not. The cleanup scripts encode exactly this difference.

All three machines' `ComfyUI\models` is a **directory junction** to their real model
store, so ComfyUI's own `folder_paths.models_dir` and the external store are the same
place. (ImageBeast was migrated to this layout in Sept 2026 — before that it used
`extra_model_paths.yaml`, which only covers ~28 "official" categories and is invisible
to custom nodes that hardcode `folder_paths.models_dir`. That mismatch nearly caused
real data loss; junctions removed the class of problem.)

**SSH hosts (Tailscale):** `imagebeast`, `chatworkhorse`, `travelbeast` — all land in
PowerShell, which `remote_scan.sh` depends on.

**ComfyUI HTTP:** port `8188` on each, reachable over Tailscale, queried live during
analysis (see *object_info* below). Reported as up ~99% of the time.

### Workflow naming convention
`Function - model (machine).json`

| Tag | Meaning |
|-----|---------|
| `(i)` / `(ib)` | ImageBeast only — large models, high VRAM |
| `(tb)` | TravelBeast variant |
| `(c)`  | ChatWorkhorse variant |
| `(bare)` | Runs on TravelBeast **and** ChatWorkhorse (they share `Models_bare`) |
| *(none)* | Universal / untagged |

Parsed by `MACHINE_TAG_RE`; `(i)` normalizes to `ib`. The `(i)` tag is load-bearing —
models referenced *only* by `(i)` workflows are deliberately excluded from "copy to
Travel/Chat" gap lists.

### `000 Starting Images`
`workflows/000 Starting Images/` holds curated PNGs with embedded workflows — one per
prime `tb` workflow. Drag onto the ComfyUI canvas to load. These are the **definitive
travel-readiness check**: if every model referenced by these PNGs is present on
TravelBeast, it can run the set.

---

## The Capture → Report Cycle

```
      ┌─── daily 05:00, launchd ───────────────────────────────────────────┐
      │                                                                    │
      ▼                                                                    │
  scheduled_scan.sh                                                        │
      │                                                                    │
      ├─► comfy_fleet.sh ─► remote_scan.sh ──SSH──► [3 Windows machines]   │
      │                                              Get-Models.ps1        │
      │                                              Get-CustomNodes.ps1   │
      │                                              Get-WorkflowModelMap.ps1
      │                                                    │               │
      │                                       writes CSV/TXT to OneDrive   │
      │                                                    ▼               │
      │                                       comfy-reports/  ◄── OneDrive sync
      │                                                    │               │
      │                └─► comfy_fleet.py ◄────────────────┘               │
      │                        │  ▲                                        │
      │                        │  └── live HTTP GET :8188/object_info ─────┤
      │                        │      (all 3 machines, cached on failure)  │
      │                        ▼                                           │
      │                   fleet-output/                                    │
      │                     fleet_report_<TS>.html                         │
      │                     fleet_explorer_<TS>.html                       │
      │                     summary_<TS>.txt                               │
      │                     sync_*.bat / cleanup_*.bat                     │
      │                        │                                           │
      ├─► copy to *_latest.html                                            │
      ├─► prune to newest 3 runs                                           │
      └─► rsync ──► fleet-output-local/ ──► http.server :5050 ─────────────┘
```

**Why the local mirror exists:** the HTTP server used to serve OneDrive's live
`fleet-output/` directly, and OneDrive's sync churn kept invalidating the long-running
process's cached directory handle — `ls` worked fine while the server returned "No
permission to list directory" for hours. It now serves a plain local copy that
OneDrive never touches, refreshed at the end of each scheduled run.

**Transport note:** the Windows scan scripts write into a OneDrive-synced folder;
that's how results reach the Mac. Expect a lag of seconds-to-minutes after a scan
before the CSVs appear locally. (OneDrive is otherwise being retired fleet-wide; this
and ComfyUI workflow/image sharing are its last jobs.)

### Scheduling & serving

| Agent | What |
|---|---|
| `com.dennis.comfy-fleet-scan` | Daily 05:00, runs `scheduled_scan.sh`. `ProcessType Interactive` (avoids launchd throttling network I/O). Log: `~/Library/Logs/comfy_fleet_scan.log` |
| `com.dennis.comfy-fleet-http` | `python3 -m http.server 5050 --bind 0.0.0.0`, `WorkingDirectory` = `fleet-output-local/`. `KeepAlive`. Log: `~/Library/Logs/comfy_fleet_http.log` |

Installed via `~/repos/scripts/launchagents/install.sh` (host-aware — matches on
`scutil --get ComputerName`). A tile on the personal dashboard
(`dennyrgood.github.io`) links to the report. **LAN + Tailscale only, not public.**

Verify a scheduled run actually finished:
```bash
grep "scan complete" ~/Library/Logs/comfy_fleet_scan.log | tail -3
```
> **2026-09-04:** every scheduled run since installation had been dying silently right
> after `comfy_fleet.py` finished — `set -euo pipefail` plus `ls … | head -1` meant
> `ls` died of SIGPIPE and took the script with it, so `*_latest.html` was never
> refreshed, nothing was pruned, and the served mirror went stale. Fixed with `|| true`
> on those two assignments. **If you touch `scheduled_scan.sh`, check for the
> "scan complete" line afterward** — absence of an error is not evidence of success.

---

## The Data: What Each File Captures and Why

### Per machine, written by the PowerShell scanners

**`<HOST>-Models-<TS>.csv`** — *the disk inventory.* One row per model file found.
```
category, sub_folder, filename, extension, size_gb, size_mb, size_bytes,
file_date, full_path, relative_path
```
*Why:* ground truth for "what does this machine physically have," and the source of
size/path data for every copy or delete command generated later. `category` = the
top-level folder under the models root (`checkpoints`, `loras`, `text_encoders`, …),
which is what ComfyUI's loader dropdowns key on.

**`<HOST>-CustomNodes-<TS>.txt`** — *the installed node packages.* Numbered list of
directory names under `custom_nodes/`, each with the folder's mtime:
```
  3. cocotools_io || 2026-01-20
```
*Why:* the fleet node comparison. The `|| <date>` suffix is a weak recency signal
("installed/updated then"), used only as a fallback when real usage evidence doesn't
exist. **ComfyUI Manager disables a node by renaming its folder to `<name>.disabled`**
— the parser strips that suffix and tracks disabled state separately, so a disabled
package doesn't masquerade as a second, permanently-missing package.

**`<HOST>-WorkflowMap-<TS>-full_map.csv`** — *the core cross-reference.* One row per
(workflow, model reference) pair, from both JSON templates and PNGs with embedded
workflows.
```
source, workflow_file, workflow_dir, workflow_modified,
node_label, model_ref, model_filename, model_category, model_path,
model_size_gb, on_disk
```
*Why:* this is the file everything else is built on. Key columns:
- **`source`** — `workflows` (JSON template), `png-outputs` (a real generated image),
  `starting_images` / `workflows-png` (the curated set). The three non-template values
  are `OUTPUT_EVIDENCE_SOURCES` — **rows tagged with those are proof of actual use**,
  and `workflow_modified` on them is the output's own timestamp.
- **`model_ref`** vs **`model_filename`** — what the workflow *asked for* vs what was
  actually resolved on disk (`(not found on disk)` when unresolvable). Paths in
  workflows are inconsistent (`FLUX2\model.safetensors` vs bare filename), so these
  differ often and legitimately.
- **`on_disk`** — YES / NO / `N/A` (background models, below).
- **Background-model rows** carry `model_category = "background-model"` and a synthetic
  `model_ref` like `[background-model:JC]`. These are nodes that load a model
  *internally* with no filename widget (JoyCaption, RMBG, InsightFace, PuLID…).
  Before they were captured, a workflow using only such nodes was skipped entirely and
  its usage was invisible. **They must be filtered out of every "is this model on
  disk" calculation** — they're a feature marker, not a resolvable file.

**`<HOST>-WorkflowMap-<TS>-node_types.csv`** — *every node class-type per workflow.*
```
source, workflow_file, workflow_dir, workflow_modified, class_type
```
*Why:* `full_map` only records nodes that touch a model file, so the majority of
installed custom nodes (image ops, string utils, compositing) never appeared there and
had **no usage signal at all**. This captures every node in every workflow graph,
regardless. Combined with `object_info` (below) to map `class_type` → owning package,
and filtered to `OUTPUT_EVIDENCE_SOURCES` rows, this is what produces real per-package
"last actually used" dates.

**`<HOST>-WorkflowMap-<TS>-model_usage.csv`** — one row per model, with how many
workflows reference it and their names. *Why:* quick "how load-bearing is this model"
lookup.

**`<HOST>-WorkflowMap-<TS>-unused_models.csv`** — models on disk that **no workflow of
any kind references**, including outputs. `filename, category, full_path,
relative_path, size_gb`. *Why:* the strongest deletion signal available — nothing has
ever pointed at this file. Feeds the cleanup scripts' first tier.

**`<HOST>-WorkflowMap-<TS>-missing_models.csv`** — referenced but not on disk:
`model_ref, workflow_file, node_label`. *Why:* per-machine gap detail with the
specific workflow to blame.

**`<HOST>-WorkflowMap-<TS>-summary.txt`** — the scanner's own human-readable summary.

**`<HOST>-ObjectInfo-cache.json`** — *not* from the PowerShell scan. Written by
`comfy_fleet.py` after a live `GET http://<host>:8188/object_info`, with a
`fetched_at` stamp. *Why:* ComfyUI's own authoritative registry of every `class_type`
currently loaded, including `python_module` (`custom_nodes.<package>` for custom nodes,
`nodes` for built-ins). This is the **only reliable way to map a class-type back to its
package** — parsing custom node source for `NODE_CLASS_MAPPINGS` is fragile, and
ComfyUI already did the work. Nodes that failed to import simply don't appear, which is
more accurate than any file-based check. The cache is the fallback if a machine is
unreachable at scan time; the report always shows per-machine freshness
(live / cached-from-date / unavailable) so stale data never silently masquerades as
current.

### Fleet-wide, written by `comfy_fleet.py` into `fleet-output/`

| File | Purpose |
|---|---|
| `fleet_report_<TS>.html`, `fleet_report_latest.html` | **The main report.** Sections below. |
| `fleet_explorer_<TS>.html`, `fleet_explorer_latest.html` | **Interactive** 3-panel cross-reference tool. |
| `summary_<TS>.txt` | Plain-text version of the same analyses — greppable, good for diffing runs. |
| `custom_nodes_<TS>.txt` | Node matrix, `Y` = enabled / `D` = installed-but-disabled / blank = absent. |
| `sync_ModelsBase_MIN.bat` | **Copy** to Models_bare: models ≤8GB (safe for 8GB VRAM). |
| `sync_ModelsBase_MAYBE.bat` | **Copy**: 8–12GB, marginal — test before trusting. |
| `cleanup_unused_IMAGEBEAST.bat` | **Move** deletion candidates to `C:\models_unused` (quarantine — IB's copy is the only one). |
| `cleanup_unused_CHATWORKHORSE.bat` / `..._TRAVELBEAST.bat` | **Delete** outright — replicas, re-syncable from IB. |
| `fix_subdir_structure.bat` | Robocopy models sitting at wrong relative paths vs IB. |
| `subdir_mismatches_<TS>.txt` | Detail for the above. |
| `history/snapshot-*.json` | Per-run snapshot, used for drift detection ("what changed since last run"). |

> Generated `.bat` files are **written, never executed** by this tooling. Copy to the
> target machine and run there. `robocopy` always uses `/COPY:DAT`, never `/COPYALL`
> (which needs audit privileges even admins lack by default).

---

## HTML Report Sections

| Section | What it answers |
|---|---|
| **Next Actions** | Prioritized to-do, including stale-scan warnings (>3 days). |
| **Travel / Workflow Readiness** | % of current-year workflows runnable per machine. |
| **Starting Images — Travel Readiness** | Per-PNG readiness for the curated `tb` prime set. The definitive travel check. |
| **Model Gaps — Travel Readiness (Recently Used)** | **Models with real output evidence in the last 90 days that are missing here.** Evidence-based; the list to act on before a trip. |
| **Custom Node Gaps — Travel Readiness** | Same, for node packages. Shows per-machine `object_info` freshness. |
| **Model Gaps (VRAM-Sorted Sync Lists)** | The same gaps bucketed OK / MAYBE / BIG against each machine's VRAM — because "missing" ≠ "would actually run." Drives `sync_*.bat`. |
| **Model Deletion Candidates** | Per host, two tiers: *unused* (zero references anywhere) and *referenced but never run*. Drives `cleanup_*.bat`. |
| **Subdir Structure Mismatches** | Models at wrong relative paths vs IB's structure. |
| **Model Drift (vs Last Run)** | Added/removed since the previous snapshot. |
| **Current Year Workflow Coverage** | Per machine: confirmed / missing-evidenced / likely-renamed / unconfirmed. |
| **Model Usage — By Actual Output** | Recent (90d) / no output this year / stale, split by "used earlier, gone quiet" vs "never seen." |
| *Unused Models on ImageBeast* (collapsed) | Raw unused list. |
| *Custom Nodes — Fleet Matrix* (collapsed) | Full per-node × per-machine grid. |

### Two distinctions the report leans on constantly

- **"Missing (evidenced)"** — not on disk, no same-family rename on disk, **and** it has
  appeared in a real output somewhere on the fleet. A genuine, proven gap.
- **"Unconfirmed / no output evidence"** — not on disk, and never seen in any output.
  Might be a template that was never run. Verify before chasing.

Same idea for nodes (`USED ★` vs `??`) and for deletion tiers.

---

## Fleet Explorer (`fleet_explorer_*.html`)

Three panels — **WORKFLOWS | MODELS | CUSTOM NODES** — with click-to-cross-reference in
every direction. Self-contained HTML, all data inlined as JS; no server needed.

- **Click a workflow** → highlights its models *and* its node packages.
- **Click a model** → highlights the workflows using it.
- **Click a node package** → highlights the workflows using it.
- Colored dots per machine: green = present/enabled, yellow = fuzzy-renamed match,
  orange = installed-but-disabled, red = missing, grey = present nowhere.

| Panel | Filters |
|---|---|
| Workflows | tabs (Starting Images / PNG Outputs / All); Status; machine tag; Root Only; Recency; Sort Name/Date |
| Models | Selected Workflow, No Workflows, On/Missing per machine, **+ Evidenced Only** (composable with any of them) |
| Custom Nodes | Selected Workflow, Used ★ (evidence), On All, Disabled Anywhere, Missing Anywhere, On/Missing per machine, Recency, Sort Name/Date |

"Missing c" / "Missing tb" mean **"on ImageBeast AND missing there"** — the pre-travel
checklist shape — not merely "absent."

**Known limitation:** subgraph / group-node style packages are invisible to output
evidence. ComfyUI expands them into their constituent primitive nodes before saving the
output, so the wrapper's own class-type never appears in any PNG. Confirmed with
`one-node-flux-2-klein`: real recent use, zero recorded evidence. Not fixable by
scanning harder. Spot these by date-sorting the node list and sanity-checking.

---

## `fleet_config.json`

Lives in the OneDrive `comfy-reports/` folder (**not** in git).

| Key | Purpose |
|---|---|
| `reports_dir` / `output_dir` / `history_dir` | Mac-side paths |
| `prime_workflows_dir` / `prime_starting_images_dir` | Readiness scoring inputs |
| `workflow_year_filter` | Current-year cutoff (`"2026"`) |
| `machines.<HOST>` | `vram_gb`, `is_source`, `models_root`, `models_bare`, `comfy_root`, `png_dir`, **`tailscale_host`**, **`comfy_port`** (default 8188) |
| `vram_thresholds` | `ok` / `maybe` GB cutoffs for sync bucketing |
| `sync` | robocopy source/dest for generated sync scripts |

`priority_custom_nodes` **was removed** — replaced by real usage evidence. Don't
reintroduce a hand-maintained list.

---

## Files

### Mac — `~/repos/scripts/comfyui/`
| File | Purpose |
|---|---|
| `comfy_fleet.sh` | **Entry point.** SSH-scan + analyze. |
| `remote_scan.sh` | SSHes each machine, runs the three `.ps1` scanners |
| `comfy_fleet.py` | **All analysis + report/explorer/script generation** (~3k lines) |
| `scheduled_scan.sh` | launchd wrapper: scan → latest copies → prune → mirror |
| `fleet-output-local/` | Local mirror served on :5050 (rsync target; don't edit) |
| `fleet_config_reference.md` | Config field reference |
| `audit_tb_c_pairs.py` | One-off: compare `(tb)`/`(c)` workflow pairs |

### Each Windows machine — `C:\repos\scripts\comfyui\`
| File | Purpose |
|---|---|
| `Get-Models.ps1` | Model disk inventory → CSV |
| `Get-CustomNodes.ps1` | `custom_nodes/` listing + mtimes → TXT |
| `Get-WorkflowModelMap.ps1` | Workflow/PNG → model + node-type mapping → 5 CSVs + summary |
| `Run-FleetScan-<MACHINE>.bat` | Manual/RDP fallback — double-click |
| `backup-comfyui-install.ps1`, `relink-comfyui-dirs.ps1`, `update-comfyui.ps1` | Install maintenance |
| `junction_migrate.ps1`, `merge_to_external.ps1`, `restore_embedded.ps1`, `manifest_*.ps1`, `check_*.ps1`, `cleanup_embedded_dupes.ps1`, `scan_node_usage.ps1`, `find_png_examples.ps1` | One-off scripts from the Sept 2026 junction migration. Kept for reference; not part of the cycle. |

Keep the Mac copy and the Windows copies of the `.ps1` scanners **in sync** — deploy
with `scp` after editing, and note that they're also tracked in git on each machine,
so a raw `scp` creates uncommitted local drift there.

---

## Gotchas

**Scanning / SSH**
- Windows OpenSSH runs exec commands through `cmd.exe`; a multi-line `-Command` string
  gets mis-split. `remote_scan.sh` keeps PowerShell commands on **one line** — don't
  reintroduce breaks.
- `cd` before a relative script arg is unreliable over SSH exec — pass roots explicitly.
- Complex quoting (`$_`, nested quotes) fails through `ssh host "powershell -Command …"`.
  For anything non-trivial: write a `.ps1` locally, `scp` it, run `powershell -File`.
  (`-Command -` stdin piping also fails.)
- PS1 encoding: `GetEncoding(28591)`, not `Latin1`.
- `.ps1` won't run on double-click (Windows security) — use the `.bat` wrappers.
- `.cache` access-denied on ImageBeast is harmless (HF cache inside `dreamomni2`).

**Analysis**
- Chat and Travel show **identical model counts by design** — same `Models_bare` folder.
- Everything is keyed by **filename**, not full path. Two different files sharing a
  generic name (e.g. sharded `model-00002-of-00004.safetensors`) collapse in the
  filename-keyed dicts. Row-level data (`unused_models.csv`) has correct per-row paths —
  use those when generating file operations, don't re-look-up by filename.
- Background-model rows must be excluded from disk/coverage math (they have no file).
- `clip`/`text_encoders` and `diffusion_models`/`unet` are interchangeable for their
  loaders; **`unet` vs `checkpoints` is not.**
- Starting Images PNGs with no model refs (resize / bg-removal) are correctly skipped in
  coverage — they run regardless.

**Python**
- Use `/opt/homebrew/bin/python3` (3.10+ required for `str | None`).
- `STALE_OUTPUT_DAYS` as a default arg is evaluated at def-time — keep constants defined
  above any function that defaults to them, or use a literal.

---

## Where to Pick Up

Ideas discussed and deliberately **not** built:

- **Git commit-hash tracking per node package** — repeatedly deferred. Fragile (not all
  installs are clones), high maintenance, and usage evidence answers "is this stale"
  more directly.
- **Arbitrary as-of-date gap report** — "show everything needed to re-run anything since
  Feb 23." The computation exists (`analyze_model_gaps` / `analyze_node_gaps` take a
  `recent_days` param); what's missing is a date picker in the explorer plus client-side
  aggregation. The current single-select highlight is the wrong mechanism for a
  many-to-many aggregate.
- **`CreationTime` on node folders** — distinguish "just installed" from "installed long
  ago, recently updated." Cheap; not done.
- **Installed-vs-loaded node cross-reference** — a package present in `custom_nodes/` but
  absent from that machine's `object_info` either failed to import or registers nothing.
  Both signals are already collected; nothing compares them yet. Would catch broken
  installs that currently look fine.
