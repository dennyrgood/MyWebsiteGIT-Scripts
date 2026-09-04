# ComfyUI Fleet — Action Plan

**Date:** 2026-09-04
**Status: ALL PHASES EXECUTED 2026-09-04.** Outcomes recorded inline per phase.
**Inputs:** (1) `report_deep_dive.MD` findings A–G; (2) decision to move the
"special / prime group" from `000 Starting Images` to **root-level files in
`workflows/`**.

---

## How the two inputs interact

They collide on exactly one point, and the decision wins:

> **Deep dive, Finding C:** *"The Starting Images figure should be the headline;
> it is the one the readme argues for."*

**Superseded.** Finding C correctly diagnosed the bug — the readiness denominator
is 80% historical `png-outputs`, so Travel/Chat are scored on ImageBeast's back
catalogue rather than on runnable workflows. Its *diagnosis* stands and still
gets fixed. Its *recommended remedy* (promote Starting Images) is replaced by:
**root-level `workflows/*.json` becomes the prime group.**

Why the decision is the better call, from the live data:

| Prime set | Items (excl. `(i)`) | TB / CWH ready |
|---|---|---|
| Starting Images (current) | 36 | **100%** |
| Root-level `workflows/*.json` (new) | 70 | **84%** |

Starting Images reports 100% because it is a *curated, deliberately-satisfiable*
set — it measures "did I remember to prepare the demo PNGs," not "can Travel run
my work." The root-level set is ~2× larger and surfaces **11 genuinely broken
workflows** that the 100% currently hides:

```
01 Laura - Outpaint.json                              ema_vae_fp16, seedvr2_ema_7b_sharp-Q4_K_M
03 Laura - kv fredy styles.json                       flux-2-klein-9b-kv-Q3_K_M
04 Laura - Remove background.json                     birefnet
Change Background Advanced - ...-fp8 (tb).json        flux-2-klein-9b-kv-Q3_K_M
Change Background Advanced - ...-fp8.json             flux-2-klein-9b-kv-Q3_K_M
Create - z-image-turbo-bf16 (bare).json               z_image-Q5_K_S
Edit Outpaint w Lora Plus - flux2-klein-4b-fp8 (tb)   flux-2-klein-4b
OneNode - FaceSwap - FLUX2 Klien 9b.json              flux-2-klein-9b, qwen_3_8b, bfs_head_v1_...
OneNode - Merge Images - FLUX 2 Klien 9b.json         flux-2-klein-9b, qwen_3_8b
OneNode - Remove Background - Birefnet.json           birefnet
zzz TRY THIS - flux_img2img_1_3_HighresFix.json       t5xxl_fp16
```

Blocking models, ranked: `flux-2-klein-9b-kv-Q3_K_M` (3 workflows), `birefnet`
(2), `qwen_3_8b` (2), `flux-2-klein-9b` (2), then one each for `ema_vae_fp16`,
`seedvr2_ema_7b_sharp-Q4_K_M`, `z_image-Q5_K_S`, `flux-2-klein-4b`.

**That list is the actual answer to "what breaks on the plane" — and today's
report does not show it.**

### What the transition does *not* require

Verified: **no PowerShell change, no rescan, no schema change.** Root-level JSONs
are already captured as `source=workflows` with the full relative path in
`workflow_file`; "root-level" is simply *"no backslash after the source label."*
The Explorer already implements this exact predicate in its `Root Only` filter
(`locFilter==='root'`). Everything below is Mac-side `comfy_fleet.py` work.

`000 Starting Images` **stays scanned and stays in `OUTPUT_EVIDENCE_SOURCES`** —
it is real generated output and therefore real usage evidence. It is demoted from
*headline metric* to *secondary check*, not deleted.

---

## Phase 1 — Stop the destructive path (do before anything else)

The generated `cleanup_*.bat` files are **unsafe as they stand**. Nothing else
matters until this is true again.

### 1.1 Category denylist for deletion candidates — *Finding A*
`build_deletion_candidates()` (`comfy_fleet.py:734`) treats
`unused_models.csv` as "the strongest deletion signal." For background-loaded
models it is the *weakest*: a model loaded by a node with no filename widget can
never enter `allModelRefs`, so it is **guaranteed** to be marked unused.

Confirmed false positives on the current lists: `pulid_flux_v0.9.1.safetensors`
(19 outputs), all 8 `vae_approx/taesd*` (ComfyUI's own live previewer — never
graph-referenced on any install, by design), `open_clip_*` (PuLID EVA-CLIP, 19),
`ip-adapter-faceid-plusv2_sdxl.bin` (30). On CWH/TB, **17 of 19 "unused" files
are background-loaded categories — and that script is a straight `del`.**

- Add a protected-category set: `vae_approx`, `liveportrait`, `ultralytics`,
  `sams`, `grounding-dino`, `facexllib`, `insightface`, `clip_vision`, `pulid`,
  `ipadapter*`, `LLM`.
- Emit those as a **third tier**, commented out in the `.bat` and labelled
  *"cannot be verified by graph reference — check manually."* Never as live
  `del`/`move` lines.
- Stretch (better, still cheap): derive protection dynamically from
  `[background-model:X]` markers already present in `full_map` — the marker
  carries the node family name, so the categories it loads can be inferred rather
  than hardcoded.

### 1.2 Quarantine path collision — *Finding B*
`generate_cleanup_script()` (`comfy_fleet.py:805`) moves everything into a flat
`C:\models_unused\`. Four basenames appear twice in the current IB script
(`model-0000{1,2,3,4}-of-00004.safetensors`, from `llama-joycaption-alpha-two`
and `-beta-one`). `move` onto an existing file prompts (hangs an unattended run)
or overwrites — either way **8 files lose their "recoverable" guarantee**, which
is the entire justification for quarantine-instead-of-delete on the source
machine.

- Mirror the relative path: `%QUARANTINE%\<category>\<subfolder>\`, `mkdir` first.
- Makes restore a copy-back rather than a guess.

### 1.3 Merge the replica cleanup scripts — *Finding F*
`cleanup_unused_CHATWORKHORSE.bat` and `..._TRAVELBEAST.bat` have **identical
filename sets** and both resolve to the same shared OneDrive `Models_bare` — via
`C:\Users\pc\...` and `C:\Users\DrDen\...`. Two scripts that must never both run.

- Emit one `cleanup_unused_ModelsBase.bat` per `sync_group` (the grouping
  `main()` already does for sync scripts), with a header naming both machines.

### 1.4 Fail loudly on partial scans
`load_all_machines()` skips a machine only if `files` is *entirely* empty. A
machine with `Models` but no `full_map` proceeds with `full_map = []`, which reads
downstream as "references nothing" — i.e. **its entire disk becomes deletion
candidates.** Given 1.1, make a missing `full_map` fatal for that machine rather
than a printed warning.

**Verify Phase 1:** regenerate, then confirm `taesd*`, `pulid_flux_v0.9.1`,
`open_clip_*` no longer appear as live `del`/`move` lines; confirm no duplicate
basenames among quarantine destinations; confirm one `ModelsBase` script replaces
the two replica scripts.

---

## Phase 2 — The prime-group transition + readiness fix

Fixes Finding C's real bug and implements the decision in one pass.

### 2.1 Define the prime set centrally
Add one predicate — root-level template workflows — and use it everywhere the
"special group" is meant:

```
source == "workflows"  AND  no subfolder in workflow_file  AND  tag != "ib" (for replicas)
```
Note it deliberately *includes* `999 TRY THIS - ...` files that sit at root, and
excludes the `999 Other/` subtree, which is a folder. Mirrors the Explorer's
existing `Root Only` semantics.

### 2.2 Fix `compute_readiness()` — *Finding C*
It builds its denominator from **every** `full_map` row for the year, never
filtering by `source`. CWH's 2026 denominator: 123 templates + 58 workflows-png +
38 starting_images + **739 png-outputs** = 920.

- Filter to the 2.1 prime set. Headline readiness becomes **84% (59/70)** for
  TB/CWH, **92% (65/70)** for IB.
- Apply the `999 Other` exclusion that `build_workflow_model_data()` already
  applies and `compute_readiness()` does not (root-only makes this mostly moot,
  but align them so they can't drift).
- Report all three figures side by side — prime (headline), all-templates,
  Starting Images — so the change in the number is self-explaining rather than
  mysterious.
- Delete the "expected for lower-VRAM machine" rationalisation in Next Actions
  once the number is honest; it currently trains you to ignore the one field
  labelled "readiness."

### 2.3 Re-point the report's headline section
- Rename **"Starting Images — Travel Readiness"** → **"Prime Workflows — Travel
  Readiness"**, driven by the 2.1 set, listing per-workflow status and the exact
  missing models (the 11-workflow list above is the target output).
- Keep a smaller **"Starting Images"** subsection as a secondary check.
- Update `build_actions()` so the top action becomes *"copy N models to make M
  prime workflows runnable on TravelBeast"* — sorted by workflows-unblocked, which
  the data above already supports (`flux-2-klein-9b-kv-Q3_K_M` unblocks 3).

### 2.4 Config
Rename `prime_starting_images_dir` → keep (still scanned), and add nothing new —
the prime set is derived, not configured. If a config key is wanted for
overridability, `prime_source: "root_workflows"` with the old behaviour still
selectable is the cheap version.

**Verify Phase 2:** headline readiness reads 84/84/92; the prime section lists
exactly the 11 workflows and their blocking models; Starting Images still shows
100% in its own subsection; `sync_ModelsBase_MIN.bat` now prioritises
`flux-2-klein-9b-kv-Q3_K_M` and `birefnet`.

---

## Phase 3 — Close the Goal-1 blind spot

### 3.1 Installed-vs-loaded node cross-reference — *Finding E*
Highest value-per-line in the whole review, and it directly answers the founding
question. Both inputs are already in `main()` scope.

TravelBeast has **3 packages installed but not loading**:
`comfyui-nunchaku`, **`comfyui-rmbg`** (a background-model family with 50
recorded output uses), **`seedvr2_videoupscaler`** (the consumer of the SEEDVR2
models `sync_ModelsBase_MIN.bat` is about to copy there). All three show
**green** today, because `node_status()` (`comfy_fleet.py:447`) reads folder
presence only.

- Add a `loaded` state: folder present **and** package appears in that machine's
  `object_info`. New status `installed-not-loaded`, rendered distinctly (suggest
  red-orange) in the fleet matrix and Explorer dots.
- Ignore `comfyui-manager` (registers no nodes by design; present on all three).
- Add a Next Actions entry — this is a "your plane workflow will fail" class of
  problem.
- Only trust it when that machine's `object_info` is **live**; if cached/stale,
  say so rather than reporting a false negative.

---

## Phase 4 — Make the pipeline's failures visible

### 4.1 Confirm the scheduled fix — *Finding D*
Two fatal bugs were found in eight lines of housekeeping; the first hid for a
week (7 scheduled runs, 0 completions). Both are fixed in the working tree and a
**manual** full run passed end-to-end (2026-09-04 09:42: 3 machines scanned, 354
files pruned, latest copies + mirror refreshed, `scan complete` logged).
The *agent* has still never succeeded.

- Check tomorrow's 05:00: `grep "scan complete" ~/Library/Logs/comfy_fleet_scan.log | tail -1`.
- Add `trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR` to
  `scheduled_scan.sh` so a `set -e` death is never silent again.
- Add a staleness check to the existing `mb-health-monitor.sh` (it already watches
  this project's HTTP server): alert if the newest `scan complete` is >36h old.
  The readme's own rule — *"absence of an error is not evidence of success"* — is
  currently unenforced.

### 4.2 Config consolidation — *Finding G*
Topology is declared three times: `fleet_config.json`, `remote_scan.sh:37-70`
(hardcoded `case`), and the prune regex at `comfy_fleet.py:1984`. Adding a
machine and missing #3 means its inputs accumulate forever, silently.

- `remote_scan.sh` reads roots from `fleet_config.json` (`python3 -c` or `jq`).
- Derive the prune regex from `config["machines"].keys()`.

### 4.3 Small items
- `remote_scan.sh:106` uses bare `python3` — pin `/opt/homebrew/bin/python3` like
  the other two call sites (latent: only fires without `--no-analyze`).
- Pass `--config` explicitly in `comfy_fleet.sh` (removes a cwd dependency).
- `SyntaxWarning` at `comfy_fleet.py:2928` — `\(` in a non-raw f-string.
- Comment `find_latest()`'s lexicographic sort — correct *only* because the PS
  timestamp is `yyyy-MM-dd_HHmm`.
- `fleet-output-local/` carries a stale 2.2 MB `.fleet_explorer_manual.html.swp`
  and `.DS_Store`, mirrored in from the OneDrive side and served over HTTP.
- Confirm `__pycache__/` is gitignored.

---

## Sequence and rationale

| Phase | Why here |
|---|---|
| **1** | Destructive path is live and wrong. Nothing else is safe to act on first. |
| **2** | Implements the decision; fixes the one metric you actually steer by. |
| **3** | Closes a real "breaks on the plane" gap; ~15 lines; data already loaded. |
| **4** | Reliability + maintainability; nothing downstream depends on it. |

Phases 1–3 are all `comfy_fleet.py` changes in areas that already have the data.
None needs new scanning, a schema change, or a Windows-side deployment.

## Decisions taken here (flag if wrong)

1. **Starting Images is demoted, not removed** — still scanned, still usage
   evidence, still shown as a secondary 100% check.
2. **`(i)`/`(ib)`-tagged root workflows stay excluded** from replica readiness —
   consistent with existing gap logic.
3. **Root-level includes `999 TRY THIS - *.json`** (they sit at root) and excludes
   the `999 Other/` subtree (a folder). Say so if the intent differs.
4. **Protected categories are hardcoded first**, dynamic derivation second — ships
   the safety fix sooner.


---

## Execution record (2026-09-04)

| Phase | Outcome |
|---|---|
| **1.1** protected categories | Replica delete lists **20 → 3** live commands. `taesd*`, `pulid_flux_v0.9.1`, `open_clip_*`, `ip-adapter-faceid-plusv2_sdxl.bin` all diverted to the commented-out `unverifiable` tier. Static set + dynamic derivation from `[background-model:X]` markers with real evidence. |
| **1.2** quarantine paths | Mirrors `<category>\<subfolder>\`, `mkdir`'d first. **0** colliding destinations (was 4 shard pairs / 8 files). |
| **1.3** replica script merge | One `cleanup_unused_ModelsBase.bat`; old per-machine names regenerate as no-op stubs pointing at it (they held live `del` lines otherwise). |
| **1.4** partial-scan guard | Missing `full_map` now skips the machine entirely with an ERROR, instead of turning its whole disk into deletion candidates. |
| **2.1–2.4** prime group | `is_prime_row()` added. Readiness **45% → 84%** (TB/CWH) and **95% → 91%** (IB) — now measuring 70 prime workflows instead of a 920-row denominator that was 80% png-outputs. New "Prime Workflows — Travel Readiness" headline section lists all **11** blocked workflows and orders missing models by workflows-unblocked (`flux-2-klein-9b-kv-Q3_K_M` = 3, `birefnet`/`qwen_3_8b`/`flux-2-klein-9b` = 2 each). "expected for lower-VRAM machine" excuse removed. Starting Images demoted to secondary. |
| **3.1** installed-vs-loaded | Fourth node state `installed-not-loaded`. Caught exactly the predicted 3 on TravelBeast (`comfyui-nunchaku`, `comfyui-rmbg`, `seedvr2_videoupscaler`) + `comfyui-imgloader` on IB. `comfyui-manager` exempt. High-priority Next Action. Falls back to presence-only if `object_info` is unavailable *and* uncached. |
| **4.1** silent failures | `ERR` trap in `scheduled_scan.sh` (verified firing — it caught 4.1b within minutes). `COMFY_SCAN` freshness check added to `mb-health-monitor.sh`, keyed on the *completion* marker and distinguishing "a run died" from "no run yet"; all 4 states tested. |
| **4.1b** *(found by 4.1)* **macOS TCC** | The trap immediately exposed why the agent had **never completed in 10 runs**: from launchd, `ls`/`cp`/`cmp`/`rsync` are all DENIED on the OneDrive folder (`Operation not permitted`); only `/opt/homebrew/bin/python3` has Full Disk Access. Invisible to manual testing, which inherits Terminal's grant. Two wrong diagnoses first ("vanished-file race", then "rsync specifically") before probing from launchd directly. Entire post-scan block moved into one python heredoc; served file now verified byte-for-byte. **First-ever `scan complete`, launchd exit 0, alert self-cleared.** |
| **4.2** config duplication | Prune regex now derived from `config["machines"]` (was a third hardcoded copy; missing it meant inputs accumulated silently forever). `remote_scan.sh` **not** rewritten — see below — but now warns loudly if a config machine has no `case` entry. |
| **4.3** small items | Homebrew python pinned at the third call site; `SyntaxWarning` fixed (identical JS output); `find_latest()` sort assumption documented; `__pycache__` confirmed gitignored. |

### Judgment call worth knowing about

**`remote_scan.sh` keeps its hardcoded paths.** Finding G rated this Low, and the
rewrite would touch the `ssh` + PowerShell quoting that the readme explicitly warns
about — in the one script that captures all fleet data. The failure mode that actually
bites (add a machine, it silently never gets scanned) is now caught by a cross-check
against `fleet_config.json`. Tidiness deferred; the silent half is closed.

### Not done

`CreationTime` on node folders, git commit-hash tracking, and the arbitrary as-of-date
gap report remain deferred — see readme "Where to Pick Up."
