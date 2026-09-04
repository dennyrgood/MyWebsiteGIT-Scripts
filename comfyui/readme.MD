# ComfyUI Fleet Management

Scan, document, and cross-reference models / custom nodes / workflows across a
three-machine ComfyUI fleet, then answer the questions that actually matter:
**what can each machine run, what is it missing, and what is it storing for no reason.**

Everything runs from the Mac. The Windows machines are scanned over SSH (Tailscale);
their ComfyUI instances are queried live over HTTP. Output is a set of CSVs, an HTML
report, an interactive explorer, and ready-to-run `.bat` scripts.

---

> **✅ 2026-09-04 — the review's findings are fixed.** The full review is in
> **`report_deep_dive.MD`**; the plan and what was done is in **`action_plan.MD`**.
> Fixed the same day: the `cleanup_*.bat` false positives (background-loaded models are
> now a separate, never-scripted tier), the quarantine filename collision (paths are
> mirrored now), the Readiness denominator (counts prime workflows, not PNG outputs),
> the two fatal bugs that stopped the daily scan from ever completing, and the
> installed-but-not-loading node blind spot. One change of direction: the prime set is
> now **root-level `workflows/*.json`**, not `000 Starting Images` — see below.

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
each, then runs the Mac-side analysis. **Budget ~5–20 min** (sequential, 3 machines; 5 min observed 2026-09-04, ~20 min when output folders have grown).

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

### The prime set: root-level `workflows/*.json`
The fleet's **special group** — what travel-readiness is measured against — is every
`.json` sitting *directly* in `workflows\`, no subfolder. That deliberately keeps
`999 TRY THIS - foo.json` (a root file) and drops the whole `999 Other\` experiments
subtree (a folder). 124 files today, 70 excluding `(i)`-tagged. Same predicate the
Explorer's "Root Only" filter already used; implemented as `is_prime_row()`.

> **Changed 2026-09-04 — this used to be `000 Starting Images`.** That set scored 100%
> on Travel/Chat precisely because it was *curated to*: it measured "did I remember to
> prepare the demo PNGs," not "can this machine run my work." Root-level templates are
> ~2× the size and immediately surfaced **11 genuinely broken workflows** the 100% was
> hiding — Outpaint, Remove Background, both OneNode FaceSwap/Merge, and more.

### `000 Starting Images` (secondary)
`workflows/000 Starting Images/` holds curated PNGs with embedded workflows — one per
prime `tb` workflow. Drag onto the ComfyUI canvas to load. Still scanned, still real
output evidence (`OUTPUT_EVIDENCE_SOURCES`), still reported — as a **secondary check**.
Demoted from headline, not removed.

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
      └─► python3 mirror ─► fleet-output-local/ ─► http.server :5050 ──────┘
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

### ⚠ The launchd agent has no shell access to the OneDrive folder (macOS TCC)

**Read this before touching `scheduled_scan.sh`.** Probed directly on 2026-09-04 from a
real launchd-launched process, against `comfy-reports/fleet-output/`:

```
ls   : DENIED          cp  : DENIED
cmp  : DENIED          rsync: DENIED   ("Operation not permitted")
/opt/homebrew/bin/python3 : OK
```

macOS grants Full Disk Access **per binary**. The Homebrew `python3` has it; the system
shell utilities do not. **This is invisible to every manual test**, because a Terminal
shell inherits Terminal's own grant — run the exact same line by hand and it works.

Consequences, all confirmed the hard way:

- The daily agent had **never once completed** — 10 runs, 0 successes, no error in the
  log. Every "current" report had actually come from a manual run.
- Three bugs stacked here, each masking the next: (1) `ls -t … | head -1` under
  `set -euo pipefail` died of SIGPIPE; (2) the bare glob matched
  `fleet_report_latest.html` itself, so `cp X X` failed; (3) underneath both, `ls`/`cp`/
  `cmp`/`rsync` were being denied the whole time. "Fixing" (1) with `|| true` made it
  *worse* — the failing `ls` returned an empty variable, so the guarded `cp` silently
  never ran and the staleness looked like success.

**Rule: any step that touches `$OUTPUT_DIR` from the agent must run inside
`/opt/homebrew/bin/python3`.** The post-scan block (publish `_latest`, mirror, verify)
is one python heredoc for exactly this reason. Don't "simplify" it back to shell
utilities — it will appear to work when you test it and silently do nothing at 05:00.

An `ERR` trap reports the failing line number, and the housekeeping verifies the served
file byte-for-byte rather than trusting an exit code. Both exist because absence of an
error here was never evidence of success.

### Scheduling & serving

| Agent | What |
|---|---|
| `com.dennis.comfy-fleet-scan` | Daily 05:00, runs `scheduled_scan.sh`. `ProcessType Interactive` (avoids launchd throttling network I/O). Log: `~/Library/Logs/comfy_fleet_scan.log`. Verify with `grep 'scan complete'` — see the TCC warning above |
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
>
> **Second bug, same eight lines, same day:** a bare `fleet_report_*.html` glob also
> matches `fleet_report_latest.html` itself, which — having just been written — is the
> newest file by mtime on the *next* run. `ls -t | head -1` then returns `latest.html`,
> `cp latest.html latest.html` fails with "are identical (not copied)", exit 1, script
> dead. Fixed by narrowing the glob to `fleet_report_[0-9]*.html`; only timestamped
> reports should ever be copy sources.
>
> **Neither fix has yet survived a real scheduled run.** As of 2026-09-04 the log holds
> 7 `scan starting` lines (Aug 29 – Sep 4) and **0** `scan complete` lines, and
> `launchctl list | grep comfy` reports last exit status **1** for
> `com.dennis.comfy-fleet-scan`. Every timestamped report and every `*_latest.html` to
> date came from a manual run. Verify after the next 05:00 firing before trusting
> anything downstream of it.
>
> Structurally, the problem is that `set -e` truncates the run *silently*. Two fatal
> bugs in eight lines of housekeeping, the first hidden for a week, argues for a
> `trap 'echo "FAILED at line $LINENO"' ERR` and a staleness check on the "scan
> complete" line in `mb-health-monitor.sh` (which already watches this project's HTTP
> server) rather than relying on remembering to grep.

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
relative_path, size_gb`. *Why:* the strongest *graph-reference* signal available —
nothing in any workflow graph has ever named this file. Feeds the cleanup scripts'
first tier.

> **Fixed 2026-09-04 — was NOT safe to run as-is.** "Unused" here means *no workflow
> graph names the file*, and a background-loaded model can never satisfy that test by
> construction — it has no filename widget, which is exactly why
> `Get-WorkflowModelMap.ps1` deliberately keeps its synthetic marker out of
> `allModelRefs`. That consequence hadn't been followed through to the deletion side, so
> **every background-loaded model was guaranteed to land on the delete list** —
> `pulid_flux_v0.9.1.safetensors` (19 real outputs), `open_clip_*` (19),
> `ip-adapter-faceid-plusv2_sdxl.bin` (30), all 8 `vae_approx/taesd*` (ComfyUI's own
> live previewer). On the replicas, 17 of 19 entries were background-loaded — and that
> script is a straight `del`.
>
> Now: `PROTECTED_CATEGORIES` (plus any category a `[background-model:X]` marker with
> real output evidence implicates) diverts these into an **`unverifiable` tier** that is
> listed in the report and emitted **commented-out** in the `.bat`, never as live
> commands. Replica delete lists dropped 20 → 3.

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
| `cleanup_unused_IMAGEBEAST.bat` | **Move** to `C:\models_unused\<category>\<subfolder>\` — quarantine with the source path mirrored, since IB's copy is the only one. |
| `cleanup_unused_ModelsBase.bat` | **Delete** outright — **one** script covering CHATWORKHORSE **+** TRAVELBEAST, which share the folder. Run once, on either. |
| `cleanup_unused_<REPLICA>.bat` | Superseded no-op stubs, regenerated to point at the ModelsBase script. |
| `fix_subdir_structure.bat` | Robocopy models sitting at wrong relative paths vs IB. |
| `subdir_mismatches_<TS>.txt` | Detail for the above. |
| `history/snapshot-*.json` | Per-run snapshot, used for drift detection ("what changed since last run"). |

> Generated `.bat` files are **written, never executed** by this tooling. Copy to the
> target machine and run there. `robocopy` always uses `/COPY:DAT`, never `/COPYALL`
> (which needs audit privileges even admins lack by default).

**Both `cleanup_*.bat` generator defects found on 2026-09-04 are fixed:**

1. **The candidate list is now filtered.** Background-loaded models go to a separate
   `unverifiable` tier, emitted commented-out — see the `unused_models.csv` note above.
2. **Quarantine mirrors the source path.** It used to move everything into a *flat*
   `%QUARANTINE%`, where 4 basenames collided among the 61 `move` lines (the JoyCaption
   `model-0000N-of-00004.safetensors` shards from `alpha-two` and `beta-one`). `move`
   onto an existing file either prompts — hanging a double-clicked `.bat` — or
   overwrites, defeating the entire point of quarantining instead of deleting. Now
   `%QUARANTINE%\<category>\<subfolder>\`, `mkdir`'d first, so a restore is a copy-back
   rather than a guess.
3. **One script per shared folder.** CHATWORKHORSE and TRAVELBEAST resolve different
   user paths to the same OneDrive `Models_bare`, so the two per-machine scripts held
   identical filename sets and must never both have been run. They're now a single
   `cleanup_unused_ModelsBase.bat`; the old per-machine names regenerate as no-op stubs
   pointing at it.


---

## HTML Report Sections

| Section | What it answers |
|---|---|
| **Next Actions** | Prioritized to-do, including stale-scan warnings (>3 days). |
| **Travel / Workflow Readiness** | % of **prime** (root-level) workflows runnable per machine. Denominator fixed 2026-09-04. |
| **Prime Workflows — Travel Readiness** | **The headline.** Blocked workflows, and the missing models ordered by how many each unblocks. |
| **Starting Images — Secondary Check** | Per-PNG readiness for the curated set. Demoted from headline 2026-09-04 — it scored 100% because it was curated to. |
| **Model Gaps — Travel Readiness (Recently Used)** | **Models with real output evidence in the last 90 days that are missing here.** Evidence-based; the list to act on before a trip. |
| **Custom Node Gaps — Travel Readiness** | Same, for node packages. Shows per-machine `object_info` freshness. |
| **Model Gaps (VRAM-Sorted Sync Lists)** | The same gaps bucketed OK / MAYBE / BIG against each machine's VRAM — because "missing" ≠ "would actually run." Drives `sync_*.bat`. |
| **Model Deletion Candidates** | Per host, **three** tiers: *unused*, *referenced but never run*, and *cannot be verified* (background-loaded — listed, never scripted). Drives `cleanup_*.bat`. |
| **Subdir Structure Mismatches** | Models at wrong relative paths vs IB's structure. |
| **Model Drift (vs Last Run)** | Added/removed since the previous snapshot. |
| **Current Year Workflow Coverage** | Per machine: confirmed / missing-evidenced / likely-renamed / unconfirmed. |
| **Model Usage — By Actual Output** | Recent (90d) / no output this year / stale, split by "used earlier, gone quiet" vs "never seen." |
| *Unused Models on ImageBeast* (collapsed) | Raw `unused_models.csv` view, split into *genuinely unreferenced* vs *background-loaded / cannot be verified* — the headline "reclaimable" figure counts only the former (fixed 2026-09-04; it used to claim all 48 / 55.99 GB). Shows the relative path, since generic shard names repeat across model folders. |
| *Custom Nodes — Fleet Matrix* (collapsed) | Full per-node × per-machine grid. |

### The Readiness percentage: fixed, and re-pointed at the prime set (2026-09-04)

`compute_readiness()` used to build its workflow set from **every** `full_map` row in
the filter year. It correctly dropped `(ib)`-tagged files and `on_disk = N/A` background
rows, but — unlike `build_workflow_model_data()` 120 lines above it, which filters on
`source` and explains why — it never excluded `png-outputs`. Since all three machines'
`png_dir` is the same OneDrive-synced output folder, **Chat and Travel were being scored
on every image ImageBeast had ever generated.** It answered "could Travel reproduce
ImageBeast's back catalogue," not "can Travel run its workflows."

CHATWORKHORSE's old 2026 denominator, decomposed:

```
workflows        123   <- actual JSON templates
workflows-png     58
starting_images   38
png-outputs      739   <- 80% of the total
                 ---
total distinct   920
```

Now it counts the **prime set** (root-level templates) only, and the headline moved with
it:

| Machine | Old (all sources) | Now (prime set) |
|---|---|---|
| IMAGEBEAST | 95% (934/983) | **91%** (106/117) |
| CHATWORKHORSE | 45% (410/920) | **84%** (59/70) |
| TRAVELBEAST | 45% (410/920) | **84%** (59/70) |

The old 45% also carried a Next Actions line rationalising it away — *"expected for
lower-VRAM machine"* — which trained you to ignore the one field on the report labelled
"readiness." That excuse is gone; a low prime score is now a real, actionable gap, and
the Prime Workflows section names the blocked workflows and orders the missing models by
how many each unblocks.

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
| `fleet-output-local/` | Local mirror served on :5050 (written by the scan's python3 mirror step; don't edit) |
| `fleet_config_reference.md` | Config field reference |
| `report_deep_dive.MD` | 2026-09-04 review: 7 findings + recommended order of work |
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
  **But excluding them from the evidence set does not make the models they load
  unused** — that inversion is the 2026-09-04 deletion-list defect. A background-loaded
  model is *unverifiable by graph reference*, never *proven unused*.
- Filename-collapse cuts both ways: the *lookup* side was fixed 2026-09-02, but the
  quarantine *destination* is still flat, so duplicate basenames overwrite each other.
- A partial scan degrades silently. `load_all_machines()` skips a machine only when
  **no** file of any type was found; a machine with a `Models` CSV but a missing
  `full_map` proceeds with an empty `full_map`, which reads downstream as "this machine
  references nothing" — i.e. its entire disk becomes deletion candidates. The per-key
  `WARNING: No <key> file found` is printed but never escalated. A missing `full_map`
  should be fatal for that machine.
- `clip`/`text_encoders` and `diffusion_models`/`unet` are interchangeable for their
  loaders; **`unet` vs `checkpoints` is not.**
- Starting Images PNGs with no model refs (resize / bg-removal) are correctly skipped in
  coverage — they run regardless.

**Config lives in three places, with no cross-checking**
Fleet topology is declared three times; adding a machine means editing all three.
1. `fleet_config.json` — Mac-side analysis (VRAM, roots, tailscale hosts).
2. `remote_scan.sh` `case` block — the Windows-side paths, hardcoded. Miss this and the
   machine is never scanned. These duplicate `models_root` / `models_bare` / `png_dir` /
   `comfy_root`, all of which already exist in #1.
3. `comfy_fleet.py` prune regex — `^(IMAGEBEAST|CHATWORKHORSE|TRAVELBEAST)-…`. Miss this
   and the new machine's scan inputs accumulate forever, with no error.

Low-effort fix: have `remote_scan.sh` read the roots out of `fleet_config.json`, and
derive the prune regex from `config["machines"].keys()`.

**Python**
- Use `/opt/homebrew/bin/python3` (3.10+ required for `str | None`). Pinned in
  `comfy_fleet.sh` and `scheduled_scan.sh` — but **`remote_scan.sh` still calls bare
  `python3`** in its own analysis branch. Latent, not currently broken: that branch only
  fires when `remote_scan.sh` is run *without* `--no-analyze`, which the normal path
  never does.
- `STALE_OUTPUT_DAYS` as a default arg is evaluated at def-time — keep constants defined
  above any function that defaults to them, or use a literal.
- `find_latest()` sorts glob matches lexicographically. Correct *only* because the
  PowerShell timestamp format is `yyyy-MM-dd_HHmm`; changing that format would silently
  select the wrong file rather than error.
- `comfy_fleet.py:2928` emits a `SyntaxWarning` — `\(` in a non-raw f-string. Cosmetic
  today, an error in a future Python.

---

## Where to Pick Up

### Installed-but-not-loading detection (added 2026-09-04)

A package can sit in `custom_nodes/` and still register nothing — a failed import from a
missing dependency, a version mismatch, a bad update. Folder presence alone used to be
reported as green, which hid three broken packages on TravelBeast:
`comfyui-nunchaku`, **`comfyui-rmbg`** (a background-model family with 50 recorded output
uses) and **`seedvr2_videoupscaler`** (the consumer of the SEEDVR2 models the sync script
was about to copy there). Exactly the "what breaks on the plane" failure this project
exists to catch.

`node_status()` now cross-references folder presence against that machine's live
`object_info` and returns a fourth state, `installed-not-loaded` — rendered `X` in the
text matrix, dark red in the report and Explorer, and raised as a **high**-priority Next
Action. `comfyui-manager` is exempt (it registers no nodes by design). If a machine's
`object_info` is unavailable *and* uncached, the check falls back to presence-only rather
than reporting a false negative.


### Ideas discussed and deliberately **not** built

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
*(The installed-vs-loaded cross-reference used to be listed here as a deferred
nice-to-have. It stopped being hypothetical on 2026-09-04 — it was already failing on
TravelBeast — and is now **built**. See "Installed-but-not-loading detection" above.)*

**Still open, from the 2026-09-04 review:**
- **`remote_scan.sh` still hardcodes the Windows-side paths** that `fleet_config.json`
  already carries. Deliberate: that script's `ssh` + PowerShell quoting is fragile (see
  the one-line `-Command` rule) and it is the single path that captures all fleet data,
  so it was not worth rewriting for tidiness. The *silent* half of the duplication is
  handled — it now warns loudly if a machine in the config has no `case` entry.
