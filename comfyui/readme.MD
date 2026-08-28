# ComfyUI Fleet Management Scripts

Scripts for managing a multi-machine ComfyUI setup — scanning models, custom nodes,
and workflow dependencies across the fleet, then running cross-machine gap analysis on macOS.

---

## TL;DR — Running It

**One command, fully automated (default):**
```bash
~/repos/scripts/comfyui/comfy_fleet.sh
```
SSHes into ImageBeast, ChatWorkhorse, and TravelBeast over Tailscale, runs the scan
scripts on each, then runs the analysis. No RDP, no double-clicking `.bat` files.
Budget 15–45 min (3 machines × 5–15 min each, sequential). Requires Tailscale
connectivity and working SSH (already set up for `imagebeast` / `chatworkhorse` /
`travelbeast`).

**Variants:**
```bash
~/repos/scripts/comfyui/comfy_fleet.sh --local-only          # skip SSH scan, analyze whatever's already synced
~/repos/scripts/comfyui/comfy_fleet.sh tb                    # SSH-scan only TravelBeast, then analyze
~/repos/scripts/comfyui/comfy_fleet.sh ib cwh                # scan a subset
~/repos/scripts/comfyui/comfy_fleet.sh --local-only --year 2025   # override year filter
```
Machine aliases: `ib`=ImageBeast, `cwh`=ChatWorkhorse, `tb`=TravelBeast.

**After it finishes**, open the newest report from the shared OneDrive folder:
```
~/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI/Work/comfy-reports/fleet-output/fleet_report_<timestamp>.html
fleet-output/fleet_explorer_<timestamp>.html   # interactive cross-reference tool
```

**If a sync/fix `.bat` was generated** (`sync_ModelsBase_MIN.bat`, `fix_subdir_structure.bat`,
etc.), it lands in that same `fleet-output/` folder — copy it to ImageBeast and run it there.
OneDrive syncs the result to ChatWorkhorse and TravelBeast automatically.

**Manual fallback** (SSH/Tailscale down): RDP into each machine, double-click
`Run-FleetScan-<MACHINE>.bat` in `C:\repos\scripts\comfyui\`, then on the Mac run
`~/repos/scripts/comfyui/comfy_fleet.sh --local-only` once all three are done.

**Housekeeping** (dry-run by default, keeps the last 3 runs per machine — inputs,
`fleet-output/`, and `history/` snapshots):
```bash
python3 ~/repos/scripts/comfyui/comfy_fleet.py --prune-output                     # lists what's stale
python3 ~/repos/scripts/comfyui/comfy_fleet.py --prune-output --confirm-prune     # actually deletes
python3 ~/repos/scripts/comfyui/comfy_fleet.py --prune-output --confirm-prune --keep-runs 5   # keep more
```

---

## When To Run This

- Before/after adding new models to any machine
- Before a trip (check TravelBeast readiness)
- Monthly to track drift
- After installing new custom nodes

The report itself will tell you when it's overdue: any machine whose scan is more
than 3 days old gets flagged in the "Next Actions" list and the readiness table.

---

## The Fleet

| Machine       | GPU  | VRAM | Role                             |
|---------------|------|------|-----------------------------------|
| IMAGEBEAST    | 5090 | 32GB | Source of truth, runs everything |
| CHATWORKHORSE | 3060 | 12GB | Shares Models_bare w/ Travel     |
| TRAVELBEAST   | 5060 |  8GB | Shares Models_bare w/ Chat       |

**Models_bare** is an OneDrive folder junctioned into ComfyUI on both Chat and Travel:
- `C:\Users\pc\...\0ComfyUI\Models_bare` (ChatWorkhorse)
- `C:\Users\DrDen\...\0ComfyUI\Models_bare` (TravelBeast)
- Same OneDrive folder, different local paths. Adding a model to one adds it to both.

**Workflow naming convention:** `Function - model (machine).json`
- `(tb)` — TravelBeast variant (uses Models_bare paths)
- `(c)`  — ChatWorkhorse variant (uses Models_bare paths)
- `(i)`  — ImageBeast only (large models, high VRAM)
- no suffix — universal / no machine tag

**000 Starting Images folder** (`workflows/000 Starting Images`):
- Curated PNGs with an embedded workflow, one per prime `tb` workflow
- Drag onto ComfyUI canvas to load it
- Used by the fleet report as the definitive travel readiness check

**SSH fleet hosts (Tailscale):**

| Alias | SSH Host          | Type    |
|-------|--------------------|---------|
| ib    | imagebeast         | Windows |
| cwh   | chatworkhorse      | Windows |
| cwhu  | chatworkhorseunix  | Ubuntu  |
| tb    | travelbeast        | Windows |

Windows SSH lands in PowerShell by default — `remote_scan.sh` relies on that.

---

## All Files and Where They Live

### On Mac — `~/repos/scripts/comfyui/`

| File | Purpose |
|------|---------|
| `comfy_fleet.sh` | **Entry point.** Bare call = SSH-scan all 3 machines + analyze. |
| `remote_scan.sh` | SSHes into each machine, runs the 3 scan scripts remotely |
| `comfy_fleet.py` | Main analysis script — reads CSVs, writes reports/sync scripts |
| `fleet_config_reference.md` | Config file field reference |

### On Each Windows Machine — `C:\repos\scripts\comfyui\`

| File | Purpose |
|------|---------|
| `Get-CustomNodes.ps1` | Scans `custom_nodes` directory |
| `Get-Models.ps1` | Scans models directory, outputs CSV |
| `Get-WorkflowModelMap.ps1` | Maps workflows and PNGs to model references |
| `Run-FleetScan-IMAGEBEAST.bat` | Manual/RDP fallback — double-click to run |
| `Run-FleetScan-CHATWORKHORSE.bat` | Manual/RDP fallback — double-click to run |
| `Run-FleetScan-TRAVELBEAST.bat` | Manual/RDP fallback — double-click to run |

`remote_scan.sh` invokes these same three `.ps1` scripts directly over SSH with
identical parameters — the `.bat` files stay in place for whenever you're at the
machine and don't want to use the Mac at all.

### On OneDrive (shared, all machines) — `0ComfyUI\Work\comfy-reports\`

| File/Folder | Purpose |
|-------------|---------|
| `fleet_config.json` | Machine config, paths, VRAM settings, priority custom nodes |
| `IMAGEBEAST-*.csv / .txt` | Latest scan reports from ImageBeast |
| `CHATWORKHORSE-*.csv / .txt` | Latest scan reports from ChatWorkhorse |
| `TRAVELBEAST-*.csv / .txt` | Latest scan reports from TravelBeast |
| `fleet-output/fleet_report_*.html` | **Open this in browser** |
| `fleet-output/fleet_explorer_*.html` | Interactive workflow/model cross-reference tool |
| `fleet-output/summary_*.txt` | Plain text summary |
| `fleet-output/custom_nodes_*.txt` | Node comparison matrix |
| `fleet-output/sync_ModelsBase_MIN.bat` | Copy to ImageBeast and run |
| `fleet-output/sync_ModelsBase_MAYBE.bat` | Optional — larger marginal models |
| `fleet-output/subdir_mismatches_*.txt` | Models in wrong subdirs vs ImageBeast |
| `fleet-output/fix_subdir_structure.bat` | Robocopy to fix subdir mismatches |
| `history/snapshot-*.json` | Drift detection history |

`fleet-output/`, `history/`, and the per-machine input files are all auto-pruned
down to the newest 3 runs when you ask (`--prune-output --confirm-prune`) — nothing
is deleted automatically on a normal run.

---

## fleet_config.json — Key Fields

- `reports_dir` / `output_dir` / `history_dir` — Mac-side OneDrive paths
- `prime_workflows_dir` / `prime_starting_images_dir` — for readiness scoring
- `workflow_year_filter` — controls "Current Year" tab and readiness %
- `machines` — per-machine `vram_gb`, `is_source`, model root paths
- `vram_thresholds` — `ok` / `maybe` cutoffs for sync categorization (GB)
- `priority_custom_nodes` — nodes flagged as high-value if missing on TravelBeast
- `sync` — robocopy source/dest for the generated sync scripts

---

## HTML Report Sections Explained

| Section | What it shows |
|---------|---------------|
| **Next Actions** | Prioritized to-do list — includes stale-scan warnings (>3 days old) |
| **Travel / Workflow Readiness** | % of current-year workflows runnable per machine, plus scan age |
| **Starting Images — Travel Readiness** | Per-PNG readiness for the curated tb prime set |
| **Model Usage — By Actual Output** | Per machine: models with no 2026 output, and no output in 90+ days — based on real output PNG evidence, not workflow-file edit dates |
| **Model Gaps** | What's missing from Models_bare vs ImageBeast |
| **Subdir Structure Mismatches** | Models at wrong paths vs ImageBeast structure |
| **Model Drift** | What changed since last run (models added/removed) |
| **Current Year Workflow Coverage** | All current-year workflows across fleet, all machines |
| **Unused Models on ImageBeast** | Models on disk never referenced in any workflow |
| **Custom Nodes — Fleet Matrix** | Which nodes are on which machines |

---

## Known Issues / Notes

- **robocopy flag**: always `/COPY:DAT`, never `/COPYALL` — `/COPYALL` requires audit
  privileges even admin accounts don't have by default.
- **PS1 encoding**: `GetEncoding(28591)`, not `Latin1`, for special characters.
- **Windows OpenSSH runs exec commands through cmd.exe**: a multi-line `-Command`
  string gets mis-split. `remote_scan.sh` keeps its PowerShell command on one line
  for this reason — don't reintroduce line breaks there.
- **`cd` before a relative script arg is unreliable over SSH exec**: `remote_scan.sh`
  passes the ComfyUI root explicitly to `Get-CustomNodes.ps1` rather than `cd`-ing
  into it and passing `.`.
- **`.cache` access denied on ImageBeast**: harmless — Hugging Face cache folder
  inside `dreamomni2`. Models still found correctly.
- **Chat and Travel show identical model counts**: by design — same OneDrive
  `Models_bare` folder via Windows junction (`mklink /j`).
- **"Missing models" count can look large on ImageBeast**: mostly path-format
  variants (e.g. `FLUX2\model.safetensors` vs `model.safetensors`), not genuine gaps.
- **PS1 files won't open on double-click**: Windows security feature — use the
  `.bat` wrappers, or SSH via `remote_scan.sh`.
- **Starting Images PNGs with no model refs** (resize/remove-background workflows):
  skipped in coverage scoring — correct, they'll always run regardless of model state.
- **clip/text_encoders and diffusion_models/unet are interchangeable** for their
  respective loader nodes; **unet vs checkpoints is NOT** — different node types,
  different dropdowns.
