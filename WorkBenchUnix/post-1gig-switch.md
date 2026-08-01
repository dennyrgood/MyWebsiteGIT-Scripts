# Post-1GbE-Switch: Finishing the WBU → FleetNAS Immich Backup

**Written 2026-07-31.** Everything here was blocked on the network, not on the scripts.
The two backup scripts are written, tested against the real NAS, and working — the DB
half ran clean end-to-end twice. What remains is: get the link to gigabit, run the
one-time 111GB image load, put it on cron, and teach the nightly checker to watch it.

Work through the sections in order. Sections 1 and 2 must happen before 3.

---

## State as of 2026-07-31

| Thing | Status |
|---|---|
| `backup_immich_db_to_fleetnas.sh` | Written, **validated twice** end-to-end |
| `backup_immich_images_to_fleetnas.sh` | Written, syntax-checked, **never run** |
| SSH key `~/.ssh/id_ed25519_fleetnas` | Installed on NAS, working, no password anywhere |
| WBU `~/.ssh/config` | Created; `ssh fleetnas` / `ssh 192.168.178.123` work keyless |
| WBU link speed | Autonegotiates **100 Mb/s** correctly — no `ethtool` override active, nothing to undo |
| NAS `/volume1/immich/postgres-dumps/` | Holds `immich-dump_2026-07-31_0330.sql` |
| NAS `/volume1/immich/images/` | **Empty — the 111GB has not been pushed** |
| Crontab entries | **Not added** |
| Nightly checker integration | **Not added** |
| Scripts committed to git | **No** |
| Btrfs snapshots on NAS | **Not configured** |

### Why the network was the blocker

- The LAN was capped at 100 Mbit by a **D-Link DES-1024D, a 24-port 10/100 unmanaged
  switch** — WBU, Mac Mini and FleetNAS all negotiated below their hardware. That's the
  device being replaced.

  > **Terminology fix (2026-08-01):** earlier drafts of this runbook called it a *hub*.
  > It is a **switch**, and the difference matters beyond pedantry — a hub floods every
  > frame to every port, a switch does not. See `network-analyzer.md`, where that
  > distinction decides whether LAN-wide traffic capture is possible at all.

- Separately, **WBU alone negotiated 10 Mb/s** where the others got 100. **Resolved
  2026-08-01** by moving WBU to a different switch port with a different cable — with
  the full 10/100/1000 advertisement restored it then negotiated 100 Mb/s immediately.
  So it was the cable or the port, *not* the NIC, the `r8169` driver, EEE, or switch
  interop. Error counters after the swap: `tx_errors: 3`, `rx_errors: 1`,
  `align_errors: 1`, all static — a clean link.
- Measured throughput: **1.17 MB/s at 10 Mbit**, **6.77 MB/s at 100 Mbit**. The latter
  is ~54 Mbit against a 100 Mbit link — that was contention from concurrent SMB pushes,
  not retransmits, as the flat error counters confirm.

---

## 1. Network settings — do this first

**Nothing to undo — this section is now just verification.** As of 2026-08-01 WBU is
advertising all modes (10/100/1000) and autonegotiating 100 Mb/s correctly against the
old DES-1024D. There is no `ethtool` override in place, and none is needed. *(Earlier drafts
of this runbook told you to revert one. That override is gone; ignore any such
instruction.)*

> **Replacement ordered 2026-08-01: TP-Link `TL-SG1024`** (24-port gigabit, unmanaged) —
> the correct part, nothing to reconsider. A separate LAN traffic-capture project briefly
> raised whether a smart-managed `TL-SG1024DE` was needed instead (for port mirroring);
> **that project was archived the same day**, so plain unmanaged is right. Don't return or
> exchange it. See `network-analyzer.md` for why the capture idea was dropped.

After swapping in the new switch, just check:

```bash
cat /sys/class/net/enp9s0/speed
```

`/sys/.../speed` reads `-1` for a few seconds mid-renegotiation — that is normal, re-read
before concluding anything.

If it doesn't come up on its own, force a clean renegotiation rather than reaching for
an override:

```bash
sudo ethtool -r enp9s0
```

### Expected: `1000`

Then confirm the rest of the fleet, since the old switch was capping **every** machine on
the LAN, not just WBU:

```bash
ssh fleetnas 'cat /sys/class/net/eth0/speed'
ssh -i ~/.ssh/id_ed25519_macmini dennishmathes@mathes-mac-mini 'networksetup -getmedia Ethernet | grep -i active'
ssh amsterdamdesktop 'powershell -NoProfile -Command "Get-NetAdapter | Where-Object {$_.Status -eq \"Up\"} | Select-Object Name,LinkSpeed"'
```

FleetNAS has **dual 10GbE**, so on a 1GbE switch it will report `1000` — that's the
switch's ceiling, not a fault. Mac Mini was measured at `100baseTX` on 2026-07-31, so it
should change. AmsterdamDesktop was never measured (SSH key auth from WBU was refused)
— check it, since it owns the largest pending transfer of all.

### What else gets faster — worth verifying, not just assuming

The Immich→NAS backup is not the main beneficiary. Everything below shares the same wire:

- **CWHU's nightly warm-sync.** `restore_from_wbu.sh` rsyncs the latest dump, and since
  the dump gets a fresh datestamped filename daily, that is a **full 2.25GB transfer
  every night**, not an incremental one. Measured at 10 Mbit that step alone is ~32
  minutes; at gigabit it's under a minute. Worth confirming CWHU's job actually got
  shorter — its ceiling is chatworkhorse's physical NIC, since CWHU is a VM.
- **Mac Mini Friday pushes** (`backup_immich_db_to_macmini.sh` 05:00,
  `backup_immich_images_to_macmini.sh` 05:05) — capped at 100 today.
- **AmsterdamDesktop → NAS `photo_legacy`, ~975GB one-time.** Roughly 22 hours at 100
  Mbit versus ~2.5 at gigabit. This is the single biggest win, and a good reason to have
  the switch in before starting it.
- **Mac Mini → NAS Plex library** — same story, also still pending.

### If WBU comes back at 100, not 1000

This is the plausible failure, and it has a specific cause. **10BASE-T and 100BASE-TX
use 2 pairs; 1000BASE-T needs all 4.** The run is proven good for 2 pairs (that's what
the 100 Mbit test established) but the other two pairs are unproven. Check what the
switch is offering:

```bash
ethtool enp9s0 | grep -A4 "Link partner advertised link modes"
```

- **Partner advertises `1000baseT/Full` but you're linked at 100** → the far pairs are
  bad. Replace the cable with a known-good Cat5e/Cat6. A "brand new" cable can still be
  CCA, Cat5, or simply faulty.
- **Partner does not advertise `1000baseT/Full`** → the switch port isn't offering
  gigabit. Try a different port; check for a power-saving/"green mode" setting.

### If WBU comes back at 10 again

That's the old fault returning, and 2026-08-01 established what causes it: **the cable
or the port**, not the NIC. Swap both again before touching `ethtool` — that is what
fixed it last time, and forcing the speed only masks it.

Only if a swap genuinely isn't possible, pin it to 100 as a stopgap and accept ~2.5h for
the initial sync instead of ~20min:

```bash
sudo ethtool -s enp9s0 advertise 0x00c    # 100baseT Half+Full only — MASKS the fault
sudo ethtool -s enp9s0 advertise 0x02f    # undo: back to 10/100/1000
```

Remember `0x00c` removes 1000baseT from the advertisement, so leaving it in place caps
you at 100 even on a gigabit switch.

### Persistence

No `ethtool` setting here survives a reboot — a restart returns the card to
autoneg-everything, which is exactly what you want now that the cable fault is fixed. So
there is nothing to persist and nothing to re-apply after a reboot.

---

## 2. The one-time 111GB image load

Run this **by hand, once**, before it ever runs from cron. It is the only part of the
system that has never executed.

Expected duration:

| Link | Estimate |
|---|---|
| 1 Gb/s | ~20 minutes |
| 100 Mb/s | ~2.5 hours |
| 100 Mb/s, contended with SMB pushes | ~4.7 hours |

Run it detached so an SSH drop doesn't kill it partway:

```bash
nohup /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_images_to_fleetnas.sh \
  >> /home/dhm/.cache/fleetnas-sync/initial_load.log 2>&1 &
```

Watch it:

```bash
tail -f /home/dhm/.cache/fleetnas-sync/initial_load.log
ssh -i ~/.ssh/id_ed25519_fleetnas dhm@192.168.178.123 'du -sh /volume1/immich/images'
```

An interruption is cheap — rsync skips files already transferred, so a re-run picks up
where it left off. Only the in-flight file is lost.

### What a good run looks like

```
Image verification complete — FleetNAS matches WBU exactly (0 differences).
Source file count: NNNNN
=== Live image sync to FleetNAS complete ===
```

The verification is a second `rsync -ain --delete` dry run — a clean sync leaves nothing
for a re-run to do, so any output is real remaining difference. If it reports drift,
the differing paths are listed in the log and in
`/home/dhm/.cache/fleetnas-sync/verify-work-images/drift.txt`.

### If it aborts on `--max-delete`

```
ABORTED: rsync hit --max-delete=500 ...
```

This cannot happen on the initial load (the destination is empty, so there is nothing to
delete). If it fires on a **later** run it means WBU is presenting 500+ deletions —
either a genuine bulk purge, or source corruption. **Do not just raise the limit.**
Confirm the deletions are intentional first; that guard exists because WBU's rcu-stall
I/O faults have corrupted a backup once already (backup-c).

---

## 3. Crontab entries

Only after section 2 has completed cleanly. These go in **`dhm`'s** crontab
(`crontab -e`), alongside the existing Friday Mac Mini entries:

```cron
# --- FleetNAS Immich backup — daily (added post-1GbE-switch) ---
0  5 * * * /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_db_to_fleetnas.sh >> /home/dhm/.cache/fleetnas-sync/cron.log 2>&1
20 5 * * * /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_images_to_fleetnas.sh >> /home/dhm/.cache/fleetnas-sync/cron.log 2>&1
```

**Why 5:00 / 5:20.** It lands after the 3:30am dump (`dump_immich_db_for_cwhu.sh`) and
after CWHU's 4:00am pull, so all three read a consistent dump. The 20-minute gap is
sized off a measured 5m35s DB push at 100 Mbit — roughly 4× headroom.

**Revisit the gap as the dump grows.** It went 1.23GB → 2.25GB in a single day
(2026-07-30 → 07-31, expected: ML process updated). At gigabit the push should drop to
under a minute, so 20 minutes stays ample — but if the dump keeps growing and the link
regresses to 100, re-time it:

```bash
time /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_db_to_fleetnas.sh
```

To force a *real* timing run, delete the NAS-side copy first — otherwise rsync sees
matching size and mtime and skips the transfer entirely, timing nothing:

```bash
ssh -i ~/.ssh/id_ed25519_fleetnas dhm@192.168.178.123 \
  'rm -f /volume1/immich/postgres-dumps/immich-dump_*.sql'
```

Safe to do: WBU keeps the last 2 dumps, and the NAS copy is a backup of a backup.

### Snapshot the config afterwards

Per `HOWTO_TWEAK_FLEET_TASKS.md`:

```bash
/home/dhm/repos/scripts/WorkBenchUnix/wbu-snapshot-fleet-configs.sh
```

Review `git status` in `fleet-configs` before committing — and never commit/push there
without asking. Note the root crontab can't be captured over a non-interactive SSH
session, so run the snapshot **locally on WBU**.

---

## 4. Nightly checker integration

`nightly_summary.sh` emails a daily health summary and flips the subject to NOT OK when
a backup didn't complete. It currently knows nothing about FleetNAS. Three edits:

### 4a. Newest-log variables

Alongside the existing `MACMINI_DB` / `MACMINI_IMG` lines (~line 27):

```bash
FLEETNAS_DB=$(ls -1t /home/dhm/.cache/fleetnas-sync/fleetnas_db_*.log 2>/dev/null | head -1)
FLEETNAS_IMG=$(ls -1t /home/dhm/.cache/fleetnas-sync/fleetnas_images_*.log 2>/dev/null | head -1)
```

### 4b. Add to the `LOGS` array

Puts them in the emailed body and gives each a TLDR line:

```bash
    "$FLEETNAS_DB"
    "$FLEETNAS_IMG"
```

### 4c. Add to `EXPECTED` / `LABEL` — the part that actually gates NOT OK

```bash
declare -A EXPECTED=(
    ["/var/log/immich-dump-for-cwhu.log"]="Dump for CWHU complete."
    ["$CWHU_SYNC"]="Warm-sync complete."
    ["$FLEETNAS_DB"]="Postgres dump sync to FleetNAS complete"
    ["$FLEETNAS_IMG"]="Live image sync to FleetNAS complete"
)
declare -A LABEL=(
    ["/var/log/immich-dump-for-cwhu.log"]="CWHU DB dump"
    ["$CWHU_SYNC"]="CWHU warm-sync"
    ["$FLEETNAS_DB"]="FleetNAS DB push"
    ["$FLEETNAS_IMG"]="FleetNAS image push"
)
```

**These belong in `EXPECTED`, unlike the Mac Mini logs.** The Mac Mini jobs are excluded
there because they're Friday-only and legitimately stale six days a week. The FleetNAS
jobs run **daily**, so a missing or incomplete run is always worth a NOT OK.

### Known nuance — the preflight skip

Both scripts abort early with **exit 0** when WBU is in I/O distress:

```
WBU looks like it's in I/O distress — skipping tonight's sync. FleetNAS is untouched.
```

That's deliberate (a distressed WBU must not run `--delete` against the backup-of-record),
but the log then lacks the success string, so the checker reports *"FleetNAS image push
did not complete"*. Arguably correct — a skipped backup **is** worth an alert — but the
wording misleads. If it proves noisy, either accept the skip line as a second success
string, or give it its own REASON so the subject reads "skipped, WBU under I/O distress"
rather than "did not complete".

### Verify without waiting a day

```bash
sudo /home/dhm/repos/scripts/WorkBenchUnix/nightly_summary.sh
```

It runs from **root's** crontab, so run it with sudo — that's the context where
`journalctl`, `nvme` and `/sys/fs/pstore` are readable. Confirm both FleetNAS logs
appear in the TLDR and that the subject is still OK.

---

## 5. Loose ends

### Commit the scripts

Neither script is in git yet:

```
WorkBenchUnix/backup_immich_db_to_fleetnas.sh
WorkBenchUnix/backup_immich_images_to_fleetnas.sh
WorkBenchUnix/post-1gig-switch.md
```

`sync-this` stages with **`git add -A`**, which sweeps everything untracked in the repo —
check `git status` first, since this directory already carries tracked `.bak.2026-07-*`
files.

### Btrfs snapshots on the NAS — the important one

**Still not configured, and it's what makes the push direction safe.** The image script
mirrors with `--delete`, so anything that destroys WBU's data propagates to the NAS.
`--max-delete=500` narrows that window; it doesn't close it.

Schedule UGOS snapshots on `/volume1/immich` and deletions become recoverable from
something the WBU key cannot reach. This matters more here than for any previous target:
with backup-a/b/c all retired, FleetNAS is becoming the backup of record.

### Tailscale on the NAS — three places to change, not one

Once Tailscale is installed (see the FleetNAS State of the Union — use
`--accept-dns=false`), the NAS address has to be updated in **three** places:

1. `backup_immich_db_to_fleetnas.sh` — `DEST_HOST`
2. `backup_immich_images_to_fleetnas.sh` — `DEST_HOST`
3. `/home/dhm/.ssh/config` on WBU — the `Host` alias line and `HostName`

The scripts pass `-i` explicitly and deliberately do **not** read `~/.ssh/config`, so
fixing the config alone will not change what the backups do. Add the Tailscale name to
the `Host fleetnas FleetNAS 192.168.178.123` alias list rather than replacing the IP, so
both keep working during the transition.

Note `~/.ssh/config` is on WBU only and is not in git — it is not part of the scripts
repo, and I have not checked whether `wbu-snapshot-fleet-configs.sh` captures it.

Also note Tailscale rides `enp9s0` too, so it never bypasses a link problem — it would
not have helped with any of the speed issues above.

### Mac Mini Friday cron spacing

`backup_immich_db_to_macmini.sh` (05:00) and `backup_immich_images_to_macmini.sh` (05:05)
are five minutes apart — the same too-tight spacing that made me widen the FleetNAS jobs
to twenty. The DB push measured 5m35s at 100 Mbit, so on a slow week the image job may
already be starting before the DB job finishes. Gigabit likely hides this rather than
fixing it. Worth widening to 05:00 / 05:20 for consistency while you are editing the
crontab anyway.

---

## Appendix — why the rsync syntax looks wrong

Both scripts push to `dhm@192.168.178.123:immich/images/`, **not**
`/volume1/immich/images/`. That is not a typo.

UGOS ships a **patched rsync** whose server side rejects absolute paths outright
(`invalid path: '/volume1/...'`, plus a UGREEN-added `not support path` string in the
binary). It addresses destinations by **share name with no `/volume1` prefix**. The share
names only resolve once **Control Panel → File Services → "Enable backup rsync service"**
is on with an authorized account — before that, every form fails, including the correct
one. Reference: <https://www.kevinhooke.com/2025/10/19/rsync-files-to-a-ugreen-nas/>

Plain `ssh` commands are unaffected and still need real absolute paths, which is why each
script carries both spellings (`DEST_RSYNC` and `DEST_PATH`). Don't "simplify" them into one.

Two alternatives were tried and rejected:

- **Daemon-over-SSH** (`host::module`) — broken in UGREEN's build; never sends a server
  greeting.
- **Plain rsync daemon on port 873** — works, but requires a stored password and sends
  111GB unencrypted. Rejected: a plaintext credential to the backup target is exactly the
  thing that lets a compromised WBU rewrite the backup.

The share-name-over-SSH form needs neither: existing key auth, no new secret, encrypted.
