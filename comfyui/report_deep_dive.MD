# ComfyUI Fleet Management — Deep Dive Review

**Date:** 2026-09-04
**Scope:** every file in `~/repos/scripts/comfyui/`, the live data in
`~/OneDrive/.../comfy-reports/`, the generated output in `fleet-output-local/`,
and the two launchd agents.
**Question asked:** are the programs/processes sound, and are they meeting the
goals stated in `readme.MD`?

**Method note:** every claim below is backed by a quoted line, a file path, or a
computation I ran against the live scan data. Where I inferred rather than
verified, I say so.

---

## 1. Verdict

The architecture is sound and unusually well-reasoned. The evidence-based design
principle ("output evidence beats every other signal") is correct, it is applied
consistently in `comfy_fleet.py`, and the documentation is genuinely excellent —
most non-obvious decisions carry a dated comment explaining the failure that
caused them.

But three defects sit directly on the project's stated goals, and two of them are
in the **destructive** path:

| # | Severity | Finding | Goal hit |
|---|---|---|---|
| **A** | **High — data loss** | Deletion candidates systematically include background-loaded models the tool itself has usage evidence for. Confirmed false positives include `pulid_flux_v0.9.1.safetensors` (19 outputs) and all 8 `vae_approx/taesd*` files. | Goal 3, 4 |
| **B** | **High — data loss** | ImageBeast's quarantine `move` collides on 4 pairs of identical shard filenames into one flat folder — the "recoverable" promise fails for those 8 files. | Goal 3 |
| **C** | **High — wrong headline metric** | "Travel Readiness 45%" is computed over a denominator that is 80% historical PNG outputs, not workflows. Template-only readiness is 72%; Starting Images readiness is **100%**. | Goal 1 |
| **D** | Medium | The daily scheduled run has **never once completed** — 7 runs, 0 `scan complete` lines, launchd last exit status **1**. A fix is in the working tree but uncommitted and unproven. | Goal 2 |
| **E** | Medium | TravelBeast has 3 custom-node packages installed but **failing to import**. The report shows them green. | Goal 1 |
| **F** | Low | The two "delete" `.bat` files target the *same* shared OneDrive folder via two different user paths. | Goal 3 |
| **G** | Low | Config is duplicated across three places; adding a machine silently breaks pruning. | maintainability |

Goal 2 (documentation/capture) is met in substance — the CSV capture is thorough
and correct. Goal 1 is *actually* met (100% Starting Images coverage on
TravelBeast) but the report's own headline number hides it.

---

## 2. Finding A — the deletion lists are biased against exactly the models the tool knows are used

### The mechanism

`Get-WorkflowModelMap.ps1:550` defines "unused" as *no workflow graph mentions
this filename*:

```powershell
$unusedModels = @($modelInventory.Values | Where-Object {
    $fn = $_.filename.ToLower()
    -not ($allModelRefs | Where-Object { $_ -like "*$fn" })
} | Sort-Object category, filename)
```

The same script already knows this test is invalid for a whole class of models.
At `Get-WorkflowModelMap.ps1:410` it deliberately keeps them *out* of
`allModelRefs`:

> `# Not a real filename -- don't resolve it and don't feed it into`
> `# allModelRefs (that set drives unused-model detection by`
> `# filename match, which this synthetic marker would corrupt).`

Correct, as far as it goes. But the consequence was never followed through:
**a model loaded by a node with no filename widget can never appear in
`allModelRefs`, so it is guaranteed to land in `unused_models.csv`.** That CSV is
tier 1 of `build_deletion_candidates()` (`comfy_fleet.py:734`), described in the
readme as *"the strongest deletion signal available."* It is, for these
categories, the weakest.

### The proof, from the live data

The `background-model` rows on IMAGEBEAST record real output usage:

```
[background-model:RMBG]                       50
[background-model:IPAdapterInsightFaceLoader] 30
[background-model:PulidFluxInsightFaceLoader] 19
[background-model:PulidFluxModelLoader]       19
[background-model:ApplyPulidFlux]             19
[background-model:PulidFluxEvaClipLoader]     19
[background-model:JC*]                         6
```

And the same run's `IMAGEBEAST-...-unused_models.csv` marks these for quarantine:

```
pulid              1.064 GB  pulid_flux_v0.9.1.safetensors      <- PulidFluxModelLoader: 19 outputs
clip_vision        3.674 GB  open_clip_pytorch_model.bin        <- PulidFluxEvaClipLoader: 19 outputs
clip_vision        3.674 GB  open_clip_model.safetensors
clip_vision        0.789 GB  ip-adapter-plus_sdxl_vit-h.safetensors
ipadapter - Copy   1.385 GB  ip-adapter-faceid-plusv2_sdxl.bin  <- IPAdapterInsightFaceLoader: 30 outputs
facexllib          0.102 GB  detection_Resnet50_Final.pth
vae_approx         0.002 GB  taesd_decoder.safetensors  (x8)    <- ComfyUI's built-in latent previewer
```

`vae_approx/taesd*` is the clearest case: those are ComfyUI's own live-preview
decoders. They are never referenced from a workflow graph *by design*, on any
install, ever. All 8 are on the delete list for all three machines.

Category breakdown of the unused lists:

| Category | IB | CWH/TB | Background-loaded? |
|---|---|---|---|
| vae_approx | 8 | 8 | yes — built-in previewer |
| liveportrait | 5 | 5 | yes — node-internal |
| ultralytics | 3 | 1 | yes — detector auto-discovery |
| clip_vision | 3 | – | yes — PuLID/IPAdapter |
| facexllib | 3 | – | yes — face restore |
| ipadapter - Copy | 3 | – | yes |
| pulid | 1 | – | yes |
| grounding-dino | – | 2 | yes |
| sams | – | 1 | yes |
| LLM | 10 | – | shards, see Finding B |
| loras / checkpoints / clip | 11 | 2 | legitimately checkable |

**On ChatWorkhorse/TravelBeast, 17 of the 19 "unused" files are in
background-loaded categories.** The `.bat` for those machines is a straight
`del`. On ImageBeast, 11.63 GB of the 55.99 GB unused list (21%) is in these
categories.

### Recommendation

Add a category denylist to `build_deletion_candidates()` — a model in
`vae_approx`, `liveportrait`, `ultralytics`, `sams`, `grounding-dino`,
`facexllib`, `insightface`, `clip_vision`, `pulid`, `ipadapter*` is
*unverifiable*, not *unused*. Emit it as a third, commented-out tier
("cannot be verified by graph reference — check manually") rather than as `del`
lines. This is cheap and it uses data the pipeline already has.

Stronger version: for each `[background-model:X]` marker seen in real output,
mark the categories that node family is known to load as protected. The marker
already carries the node name.

---

## 3. Finding B — the quarantine `move` silently destroys half of each shard pair

`generate_cleanup_script()` (`comfy_fleet.py:805`) emits, for the source machine:

```bat
move "C:\ComfyUI_Models\models\LLM\llama-joycaption-alpha-two\model-00002-of-00004.safetensors" "%QUARANTINE%\"
move "C:\ComfyUI_Models\models\LLM\llama-joycaption-beta-one\model-00002-of-00004.safetensors"  "%QUARANTINE%\"
```

Destination is a **flat** folder. In the current
`cleanup_unused_IMAGEBEAST.bat` (61 `move` lines), four basenames appear twice:

```
2  model-00001-of-00004.safetensors
2  model-00002-of-00004.safetensors
2  model-00003-of-00004.safetensors
2  model-00004-of-00004.safetensors
```

cmd's `move` onto an existing file either prompts (script hangs on a
double-click run) or, with `/Y`, overwrites. Either way the whole point of
quarantine — *"so a wrong call is recoverable"*, per the function's own
docstring — is defeated for 8 files.

This is the same filename-collapse class of bug the code already fixed once
elsewhere; the comment at `comfy_fleet.py:~760` documents catching it in the
lookup path on 2026-09-02 for these exact JoyCaption shards. The fix landed on
the *lookup*, not on the *destination*.

**Fix:** mirror the relative path into quarantine —
`%QUARANTINE%\<category>\<subfolder>\` — creating the directory first. Cheap,
and it also makes restoring a file a copy-back rather than a guess.

---

## 4. Finding C — the readiness percentage measures the wrong thing

`compute_readiness()` (`comfy_fleet.py:407`) builds its workflow set from **every
row** in `full_map` whose `workflow_modified` starts with the year filter. It
filters out `(ib)`-tagged files and it correctly ignores `on_disk == "N/A"`
background rows — but it does **not** filter by `source`.

`build_workflow_model_data()` (`comfy_fleet.py:281`), 120 lines earlier, does
exactly that filtering and explains why:

> `# Only JSON workflows drive the prime/gap analysis.`
> `# png-outputs = historical ImageBeast output folder, not executable.`

`compute_readiness` never got the same treatment. Decomposing
CHATWORKHORSE's 2026 denominator by source:

```
workflows        123   <- actual JSON templates
workflows-png     58
starting_images   38
png-outputs      739   <- 80% of the total
                 ---
total distinct   920
```

Because all three machines' `png_dir` is the same OneDrive-synced output folder,
TravelBeast and ChatWorkhorse are being scored on **every image ImageBeast has
ever generated**. The metric answers "could Travel reproduce ImageBeast's back
catalogue," not "can Travel run its workflows."

Recomputed against the live data with the same missing-model logic, varying only
the source filter:

| Machine | Current (all sources) | Templates only | Starting Images |
|---|---|---|---|
| IMAGEBEAST | 95% (934/983) | 89% (158/178) | **100%** (44/44) |
| CHATWORKHORSE | 45% (410/920) | **72%** (89/123) | **100%** (38/38) |
| TRAVELBEAST | 45% (410/920) | **72%** (89/123) | **100%** (38/38) |

The readme names the Starting Images set *"the definitive travel-readiness
check."* By that measure TravelBeast is **fully ready** — Goal 1 is met. The
headline number says 45% and the Next Actions block rationalises it away:

> `[ ! ]  TRAVELBEAST readiness 45% — expected for lower-VRAM machine`

That line is doing damage: it teaches you to ignore a number that is both wrong
*and* the one thing on the report labelled "readiness."

**Fix:** filter `compute_readiness` to `source == "workflows"`, or report the
three figures side by side. The Starting Images figure should be the headline;
it is the one the readme argues for.

Related, smaller: `compute_readiness` also doesn't apply the `999 Other`
exclusion that `build_workflow_model_data` applies, so experiment/tutorial
templates count toward readiness too. Worth aligning at the same time.

---

## 5. Finding D — the scheduled run has never completed

The readme documents a SIGPIPE bug found today and says it is fixed. Current
state:

```
$ grep -c "scan complete" ~/Library/Logs/comfy_fleet_scan.log
0
$ grep -c "scan starting" ...   -> 7   (Aug 29 – Sep 4, one per day)
$ launchctl list | grep comfy
-	1	com.dennis.comfy-fleet-scan       <- last exit status 1
95310	0	com.dennis.comfy-fleet-http
```

The log ends mid-run at `comfy_fleet.py`'s final line, exactly as the readme
describes. So: **seven scheduled runs, seven silent failures, zero successes.**
Today's 09:42 output (`fleet_report_latest.html`, the pruned dir, the refreshed
mirror) came from a *manual* run, not the agent.

The fix in the working tree is uncommitted:

```diff
-latest_report=$(ls -t "$OUTPUT_DIR"/fleet_report_*.html   2>/dev/null | head -1) || true
+latest_report=$(ls -t "$OUTPUT_DIR"/fleet_report_[0-9]*.html 2>/dev/null | head -1) || true
```

The `[0-9]` reasoning is right and the bug it fixes is real and subtle (a bare
glob matches `fleet_report_latest.html`, which after the first successful run is
the newest by mtime, making `cp X X` fail with exit 1 and kill the script under
`set -e`). But note this is the *second* fatal bug found in eight lines of
housekeeping, and the first one hid for a week.

**Recommendation:** the structural fix is to stop letting `set -e` silently
truncate the run. Either add a `trap 'echo "FAILED at line $LINENO"' ERR`, or
wrap the housekeeping block in a function whose failure is logged and
non-fatal. And add the log check to a monitor rather than to your memory — the
readme's own advice, *"absence of an error is not evidence of success,"* is
correct and currently unenforced. `mb-health-monitor.sh` already exists and
already watches this project's HTTP server; a `grep "scan complete" | tail -1`
staleness check belongs there.

Verify after tomorrow's 05:00 run before trusting anything downstream.

---

## 6. Finding E — three TravelBeast node packages are installed but not loading

The readme lists this cross-reference under *"Where to Pick Up — not built"*:

> **Installed-vs-loaded node cross-reference** — a package present in
> `custom_nodes/` but absent from that machine's `object_info` either failed to
> import or registers nothing. Both signals are already collected; nothing
> compares them yet.

I ran the comparison against the cached `object_info` (all three fetched
2026-09-04 09:42) and the same run's `CustomNodes` listings:

| Machine | Folders | Loaded pkgs | Installed but NOT loaded |
|---|---|---|---|
| IMAGEBEAST | 51 (1 disabled) | 49 | `comfyui-imgloader`, `comfyui-manager` |
| CHATWORKHORSE | 32 | 32 | `comfyui-manager` |
| **TRAVELBEAST** | 29 | 26 | `comfyui-manager`, **`comfyui-nunchaku`**, **`comfyui-rmbg`**, **`seedvr2_videoupscaler`** |

`comfyui-manager` registers no nodes — expected, ignore it. The other four are
real: **`comfyui-rmbg` is one of the background-model node families with 50
recorded output uses fleet-wide**, and `seedvr2_videoupscaler` is the consumer of
the SEEDVR2 models the current `sync_ModelsBase_MIN.bat` is about to copy to
TravelBeast. Both currently show green in the fleet matrix and the explorer,
because the matrix is built purely from folder presence
(`node_status()`, `comfy_fleet.py:447`).

This is precisely the Goal 1 failure mode — *"if I close the lid and get on a
plane, what breaks?"* — and it is invisible in the report today.

**This is the highest value-per-line change available.** The data is already
loaded in `main()` (`object_info` and `nodes_data` are both in scope); it needs
~15 lines to add a `loaded` state to `node_status()` and a Next Actions entry.
It should be promoted from "Where to Pick Up" to the top of the list.

---

## 7. Finding F — the two delete scripts hit one shared folder

`cleanup_unused_CHATWORKHORSE.bat` and `cleanup_unused_TRAVELBEAST.bat` contain
20 `del` lines each. The filename sets are **identical**; only the user path
differs (`C:\Users\pc\...` vs `C:\Users\DrDen\...`), and both resolve to the same
OneDrive-synced `Models_bare`.

That is correct given the shared-folder design, but the generated header is
misleading:

```
REM  Cleanup candidates on CHATWORKHORSE
REM  Action: DELETE
```

It reads as a per-machine operation. Running it deletes for **both** replicas and
propagates through OneDrive. The readme's framing — *"worst case is re-running
the sync script"* — is true but understates that there is no second chance on the
replica side, only on ImageBeast's.

**Fix:** for machines sharing a `sync_group`, emit **one** `cleanup_unused_ModelsBase.bat`
(the same grouping `main()` already does for the sync scripts) with a header
stating it affects both machines. Two scripts that must never both be run is a
foot-gun for no benefit.

---

## 8. Finding G — configuration lives in three places

Fleet topology is declared three times, with no cross-checking:

1. `fleet_config.json` — the Mac-side analysis (VRAM, roots, tailscale hosts).
2. `remote_scan.sh:37-70` — the Windows-side paths, hardcoded in a `case`.
3. `comfy_fleet.py:1984` — the prune regex:
   `^(IMAGEBEAST|CHATWORKHORSE|TRAVELBEAST)-...`

Adding a fourth machine means editing all three; miss #3 and its scan inputs
accumulate forever with no error. Miss #2 and it never gets scanned. The paths in
#2 duplicate `models_root` / `models_bare` / `png_dir` / `comfy_root` that
already exist in #1.

**Fix (low effort, real payoff):** have `remote_scan.sh` read the roots out of
`fleet_config.json` (via `python3 -c` or `jq`), and derive the prune regex from
`config["machines"].keys()`. The config already carries every field
`remote_scan.sh` hardcodes.

---

## 9. Smaller observations

- **`remote_scan.sh:106` uses bare `python3`.** Both `comfy_fleet.sh` and
  `scheduled_scan.sh` carry long dated comments explaining why the Homebrew
  interpreter must be pinned (Apple's 3.9 can't parse the PEP 604 hints — I
  confirmed: `/usr/bin/python3 -c "import comfy_fleet"` dies at line 50). The
  third call site was missed. It only fires on `remote_scan.sh` run *without*
  `--no-analyze`, which the normal path never does — so it's latent, not
  currently broken.
- **`main()` config discovery** checks cwd then script dir. `comfy_fleet.sh`
  `cd`s to the reports dir to make that work rather than passing `--config`,
  which `scheduled_scan.sh` does pass. Passing it explicitly in both would remove
  a cwd dependency for no cost.
- **`find_latest()`** (`comfy_fleet.py:120`) sorts glob results lexicographically.
  That is correct *only* because the PowerShell timestamp format is
  `yyyy-MM-dd_HHmm`. Fine today; worth a one-line comment, since a format change
  would silently select the wrong file rather than error.
- **`load_all_machines()`** skips a machine only when `files` is entirely empty.
  A partial scan (say, `Models` present but `full_map` missing) proceeds with an
  empty `full_map`, which reads downstream as "this machine references nothing"
  — i.e. everything on its disk becomes a deletion candidate. The per-key
  `WARNING: No <key> file found` is printed but not escalated. Given Finding A,
  a missing `full_map` should be fatal for that machine, not a warning.
- **SyntaxWarning** at `comfy_fleet.py:2928` — `\(` in a non-raw f-string. Cosmetic;
  will become an error in a future Python.
- **`fleet-output-local/` has junk under version control's nose:** a 2.2 MB
  `.fleet_explorer_manual.html.swp` from April and a `.DS_Store`. They're
  mirrored from `fleet-output/` by `rsync -a --delete`, so they came from the
  OneDrive side. Harmless, but the `.swp` is a stale vim crash artifact and the
  local mirror is served over HTTP. (Not deleting anything — flagging only.)
- **Uncommitted working tree:** `readme.MD` and `scheduled_scan.sh` both modified,
  including the Finding D fix. Left as-is.
- **`__pycache__/` is present in the repo directory** (140 KB, built today by my
  import). Check whether it's gitignored.

---

## 10. What is genuinely good, and should not be touched

Worth stating explicitly, because the findings above are all negative by nature:

- **The evidence principle is right and consistently applied.** Every "used /
  unused" claim traces to `OUTPUT_EVIDENCE_SOURCES`, and the code never quietly
  falls back to mtime. The `priority_custom_nodes` deletion — a hand-curated list
  where 5 of 6 entries had zero real usage — is exactly the right call, and the
  readme's instruction not to reintroduce it should be obeyed.
- **`object_info` as the class-type→package oracle** is the correct design.
  Parsing `NODE_CLASS_MAPPINGS` would have been fragile; asking ComfyUI is not.
  The live-fetch-with-dated-cache-fallback, surfacing freshness per machine
  rather than silently serving stale data, is textbook.
- **The `background-model` synthetic-row concept** is a genuinely clever solution
  to an invisible-usage problem. Finding A is not a criticism of the concept — it
  is that the concept was applied to the *evidence* side but not to the
  *deletion* side.
- **`.bat` files are generated and never executed.** Correct separation. Keep it.
- **`/COPY:DAT` not `/COPYALL`** — right, and the reason is documented.
- **Quarantine-on-source, delete-on-replica** asymmetry correctly encodes the one
  irreversibility in the fleet. (Finding B is an implementation bug in it, not a
  flaw in the idea.)
- **The comment discipline** is the best thing here. Nearly every non-obvious line
  carries the dated incident that produced it. Three of my findings above were
  found *because* a comment told me where to look.

---

## 11. Recommended order of work

1. **Finding A** — category denylist in `build_deletion_candidates()`. Do this
   before running any `cleanup_*.bat`. The current scripts should be considered
   unsafe as generated.
2. **Finding B** — mirror relative paths into `%QUARANTINE%`.
3. **Finding E** — installed-vs-loaded cross-reference. ~15 lines, and it is the
   one finding that directly answers the project's founding question.
4. **Finding D** — confirm tomorrow's 05:00 run logs `scan complete`; add an
   `ERR` trap and a staleness check to `mb-health-monitor.sh`.
5. **Finding C** — filter `compute_readiness` by source; promote the Starting
   Images figure to the headline.
6. **Findings F, G** and the smaller items as cleanup.

Items 1–3 are all changes to `comfy_fleet.py` in areas the code already has the
data for; none requires new scanning or a schema change.
