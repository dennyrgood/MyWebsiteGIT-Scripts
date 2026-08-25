# Fleet — Off-Site Backup (Immich → restic → s3g)

Created: 2026-08-25 UTC
Companion to: Fleet — Next-Level Plan (Q3/Q4 2026), Workstream A1
Status: **built and running.** Initial seed to s3g in progress.

---

## Purpose

Supersedes Workstream A1 of the Next-Level Plan (Google Drive + rclone + restic).
That plan assumed Google Drive had "hundreds of GB free"; the real figures killed it:

- Google Drive: 47.12 GB used of 200 GB → ~153 GB free. Too tight for a growing library.
- OneDrive: ~800 GB free, but ruled out — its client handles ~100,000 small files
  (the raw image tree) poorly: throttling, slow reconciliation, and no way to tell
  "done" from "still churning".

**Decision:** no cloud. restic for versioned, integrity-checked backups on wbu,
replicated off-site to Gran Canaria via Syncthing.

### Why this exists at all

wbu already mirrors to FleetNAS nightly and Mac Mini weekly. Those are
`rsync --delete` **mirrors**: a bad deletion or a corrupted file propagates to
them within 24 h and the previous good state is gone. `--max-delete=500` catches
mass deletion, not the slow kind.

This adds the two things a mirror cannot give:

1. **Point-in-time rollback** — snapshots.
2. **Integrity verification** — proof that what was stored is what was read.

Geographic separation is the third gain, and the reason for the Syncthing leg.

---

## What is actually backed up

| Path | Size | In backup? |
|---|---|---|
| `images/upload` | 85 GiB | **yes** — the originals, irreplaceable |
| `images/profile` | 124 KiB | **yes** |
| `images/library` | 8 KiB | **yes** |
| `postgres-dumps-latest/` | 4.2 GiB | **yes** — `pg_dumpall` of the whole cluster |
| `images/thumbs` | 20 GiB | no — Immich regenerates |
| `images/encoded-video` | 1.9 GiB | no — Immich regenerates |
| `images/backups` | 8.4 GiB | no — Immich's own DB dump, redundant with the above |
| `export_flat/` | 83 GiB | no — derived by `export_archive.py` |
| `export_multi/` | 116 GiB | no — derived by `export_archive.py` |

**Backup set: ~89 GiB.** (The original doc said ~118 GB; that predated the
exclusions below.)

### Why the exclusions

`thumbs/` and `encoded-video/` are derived data. Including them would add ~22 GiB
to the repo and — the real cost — ~22 GiB to the initial over-the-wire seed and to
every prune-driven re-replication after it. Price on a restore day: Immich
regenerates thumbnails and transcodes for ~280k assets. Hours, unattended, nothing
irreplaceable at stake.

`images/backups/` is Immich's own DB dump. `postgres-dumps-latest/` already holds a
`pg_dumpall` of the entire cluster, which is strictly more complete.

`export_flat/` and `export_multi/` are 199 GiB of reorganised copies of the same
photos, regenerable from the library plus the DB, and already pushed to Mac Mini and
AmsterdamDesktop. They are also the space release valve: deleting them frees 199 GiB
on `/mnt/immich-data`.

To include the derived data anyway, set `BACKUP_DERIVED="yes"` in
`backup_immich_to_restic.sh`.

---

## Where the repo lives

**`/mnt/immich-backup/restic`** — on `nvme0n1p3`, reclaimed from Windows.

| | |
|---|---|
| Device | `/dev/nvme0n1p3`, 248.7 GiB, ext4, label `immich-backup` |
| Usable | 244 GB (`-m 0` — no root reserve on a data volume) |
| Repo ID | `3866241e02`, format version 2, compression `auto` |
| Repo size | 84.25 GiB for 89.2 GiB of source |
| fstab | `UUID=5217f4ed-… /mnt/immich-backup ext4 defaults,nofail,x-systemd.device-timeout=5 0 2` |

`nofail` is deliberate: a problem on the backup volume must never block boot of the
Immich host.

### The repo is a subdirectory, not the mount root

If the repo sat at the mount root and the volume failed to mount,
`/mnt/immich-backup` would fall back to an empty directory on `/` (37 GB free) and
restic would build a second repo there, quietly filling the root filesystem. One
level down, that path simply does not exist when unmounted, so restic fails loudly.
`backup_immich_to_restic.sh` also guards with `mountpoint -q` on both volumes.

### Reclaiming p3 from Windows

The 596 GB `/mnt/immich-data` had 249 GB free, but sharing a partition with the
source was unappealing. `nvme0n1p3` held a live, bootable Windows 11 install using
99 GB of 249 GB. Contents were surveyed and confirmed expendable: Windows itself,
two embedded Python distributions (`OpenWebUI`, `Misc`), CUDA DLLs
(`OllamaBackup`), a GitHub checkout of this repo, 26 GB of `$Recycle.Bin`, and
868 MB of Downloads.

p3 sits immediately *before* p4 on disk, so its space could not be merged into
`/mnt/immich-data` without relocating 317 GB. It was reformatted as its own
filesystem instead — which is also better isolation: filesystem corruption or a
fat-fingered `rm -rf` on `immich-data` no longer takes the repo with it. Same
physical NVMe, so a device failure still kills both; that is what the s3g copy is
for.

**The Win 11 Pro licence was deliberately not salvaged.** It was not an OEM
firmware licence — no `MSDM` or `SLIC` ACPI table — so it did not survive the wipe.

### Two pieces of boot drift found and fixed on the way

- **The EFI System Partition was never mounted** and had no fstab entry (p1 carries
  the GPT *no-automount* attribute). The boot stack on it was intact, but
  `grub-efi`/`shim` updates had nowhere to write. Now pinned in fstab.
- **`shim-signed` was not installed at all**, despite `shimx64.efi` sitting on the
  ESP from the original install. Now package-managed.

Secure Boot is disabled and the platform is in Setup Mode.

---

## Schedule

| Time | Job |
|---|---|
| 03:30 | `dump_immich_db_for_cwhu.sh` → `postgres-dumps-latest/` |
| **04:00** | **`backup_immich_to_restic.sh`** — backup, forget, (monthly prune), check |
| 05:00 / 05:20 | FleetNAS DB and image mirrors |
| **06:25** | **`syncthing_offsite_status.sh`** — off-site replication check |
| 06:30 | `nightly_summary.sh` — email |

04:00 sits after the DB dump, so every snapshot contains that morning's fresh
`pg_dumpall`, and finishes well before the FleetNAS sync. Nightly deltas take
seconds — the first full backup took 137 s at ~450 MB/s; an unchanged run takes 12 s.

---

## Retention and pruning

```
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 24
```

Two years of rollback, ~46 snapshots. Chosen over the original 7/4/6 draft because
snapshots of a mostly append-only photo library dedupe almost completely — the only
data retained is what was later changed or deleted — so a longer horizon costs
little disk. The threat model is a bad deletion during dedup/face-grouping cleanup
propagating to FleetNAS unnoticed, and that can go unspotted for months.

### Prune runs monthly, not nightly

`PRUNE_DAY="01"`.

`forget` only deletes small snapshot metadata files — invisible to replication.
**`prune` rewrites pack files**, and every repacked pack must cross the link to
Gran Canaria again. Pruning nightly would keep the off-site transfer permanently
churning. With 244 GB of volume for a ~85 GB repo there is no space pressure
forcing the issue.

---

## Integrity checking

```
restic check --read-data-subset=1/30
```

Structure check every night, plus a rotating thirtieth of the pack data re-hashed,
so the entire repo is byte-verified over a month. Reads only — no Syncthing traffic.

This is what turns "a backup I have never verified" into a checked fact, and it
earned its place before it was ever scheduled (see the RAM fault below).

---

## Transport: Syncthing → s3g

**Correction to the original doc**, which stated Syncthing was "already deployed
across the relevant nodes" and "already running". It was **not installed on wbu at
all**. It was already running on s3g, paired with mmm.

| | |
|---|---|
| wbu | Syncthing 1.30.0, upstream apt repo, runs as `dhm` (not root) |
| s3g | Syncthing 2.1.3 — different major, interoperating fine |
| Folder ID | `immich-restic` |
| wbu path | `/mnt/immich-backup/restic` — **Send Only** |
| s3g path | `D:\immich-restic` — **Receive Only** |
| Versioning | off on both — restic already versions |
| Ignore permissions | on — the far end is Windows |
| wbu device ID | `VUU2OPZ-YSV3GJW-USASOK4-V5AEZUR-EKHZ22Q-OVPUUF6-54NVRPI-2EJWFQA` |
| s3g device ID | `2U2VAWO-KDK4BX5-2W37CAZ-FA7R7BK-TTM3X4H-74YNQCQ-5JEV6RN-OHE2PQB` |

**Send Only / Receive Only** means nothing at the far end — a stray edit, a
filesystem fault, ransomware — can propagate back into the repo depended on here.

### `.stignore` excludes `/locks`

restic takes a lock for every operation. A replicated stale lock would obstruct a
restore at the far end, precisely when an obstacle is least welcome. Everything else
in the repo is immutable packs, which suits Syncthing well.

### The daemon runs unprivileged

Syncthing runs as `dhm`, not root, because **the repo is encrypted** — an
unprivileged reader gets ciphertext. `keys/` holds the master key wrapped with
scrypt, inert without the passphrase, which lives at `/root/.restic-passphrase`,
root-only, and deliberately **outside** the synced tree. `keys/` and `config` must
replicate or the s3g copy would be undecryptable packs.

The repo was initially created root-only (`init-restic-repo.sh` ran under
`umask 077` to protect the passphrase file, and restic inherited it). Fixed with
`chmod -R a+rX`; `backup_immich_to_restic.sh` now sets `umask 022` explicitly so
cron cannot recreate the problem.

### Connectivity

Discovery found nothing for s3g — the address was empty and nothing connected until
it was pinned. Device address is set to `dynamic, tcp://100.72.84.84:22000`: still
attempts discovery and hole-punching, but always has a known-good Tailscale fallback
so a dropped connection cannot leave it silently disconnected for days.

Tailscale upgraded from DERP(mad) to a **direct** path once traffic started, so the
seed runs peer-to-peer. ufw allows 22000/tcp and 22000/udp; without that, Syncthing
falls back to its own shared relay.

GUI is on `0.0.0.0:8384` with TLS and a password, restricted by ufw to the tailnet
(`100.64.0.0/10`) and LAN (`192.168.178.0/24`).

---

## Monitoring

Both layers report into the nightly summary email with purpose-built TLDR lines.

```
  restic backup:  [2h ago] snapshots retained: 2   repo size on disk: 85G ✓
  off-site (s3g): ⏳ [5m ago] 5.67%, 79.49GiB outstanding, ETA ~5.5h — no complete copy yet
```

### The restic marker means the backup is good, not that the script finished

`RESTIC BACKUP VERIFIED OK` is emitted only after backup **and** forget **and** the
integrity check all succeed. A corrupted blob or a failed `check` can never read as
success. This follows the convention already established for `$FLEETNAS_IMG` in
`nightly_summary.sh`.

### The off-site line has three states, not two

| Glyph | Meaning | Subject line |
|---|---|---|
| `✓` | a complete off-site copy exists and is current | unaffected |
| `⏳` | healthy, but not there yet — seeding or catching up | **unaffected** |
| `⚠️` | broken — needs action | goes red, with the reason |

A tick would overstate the protection in place: at 5% seeded there is no off-site
backup at all. A warning would cry wolf nightly during a legitimate seed and hijack
the subject. The hourglass says "not there yet, and that is known".

It further distinguishes **initial seed** (no complete copy has ever existed — the
current state) from **catching up** (a copy exists and is briefly behind, shown as
`last complete Nh ago`). Same percentage, very different exposure.

### What turns the subject red, and how fast

| Failure | Detected |
|---|---|
| s3g unreachable > 24 h (`LAST_SEEN_MAX_H`) | next morning |
| folder reports errors | next morning |
| zero progress since the previous check | next morning |
| backlog persists > 3 days (`BACKLOG_MAX_DAYS`) | at 3 days |

The last one is the backstop against a transfer that creeps along forever without
ever technically stalling. 3 days against an 8-hour seed ETA is ~9× margin. Raise it
only if a genuine large import repeatedly trips it.

Backlog age is measured from a recorded start timestamp in
`/var/lib/syncthing-offsite.state`, not by counting runs, so running the script by
hand does not distort it.

---

## The RAM fault (found by this work, unrelated to its design)

The very first backup failed:

```
Detected data corruption while saving blob 807d43ac… : hash mismatch
```

restic hashes each blob when chunking, then re-verifies after compress+encrypt
before writing. A mismatch means the data changed **in memory**, not on disk.

Diagnosis: three cold reads of the source file (caches dropped) hashed identically,
ruling out the NVMe. A rerun failed at a **different file and a different blob**,
ruling out a restic bug or a bad file — non-deterministic, therefore hardware. Both
runs died after ~35–40 GB processed, i.e. a roughly fixed error rate per byte.

Cause: **four mismatched DIMMs across all four slots** on an ASRock B450 Steel
Legend with a Ryzen 5 5500 — Crucial 2133, Kingston HyperX 2400 ×2, G.Skill 2666,
all clocked down to 2133. Not an overclock; AM4's memory controller is simply weak
with four heterogeneous modules, and fails under sustained all-core memory pressure.
No ECC, so nothing in the OS was ever going to report it.

Fix: removed the Crucial and G.Skill sticks, leaving the matched Kingston pair
(16 GB) already in A2/B2. The backup then ran 137 seconds — well past the 80–100 s
failure point — and has verified clean since.

**Open consequence:** bad memory was in play while `--delete` mirrors ran nightly to
FleetNAS and Mac Mini. rsync compares size and mtime, not content, so corruption
would have propagated silently. An `rsync -ainc` checksum dry-run against FleetNAS
would settle it — expensive (85 GB read at both ends), worth doing, not urgent.
Note also that restic verifies faithfully what it *stored*; it cannot tell you a
photo was already damaged on disk when it read it.

The two removed sticks are kept and untested. Worth memtesting before deciding
between a matched 32 GB kit and staying on 16 GB. Current usage is ~2 GB.

---

## Scripts

All in `~/repos/scripts/WorkBenchUnix/`.

| Script | Purpose |
|---|---|
| `backup_immich_to_restic.sh` | nightly backup, forget, monthly prune, check |
| `syncthing_offsite_status.sh` | off-site replication check for the summary |
| `restic-wbu` | wrapper — `sudo restic-wbu snapshots`, `… prune`, `… restore …` |
| `init-restic-repo.sh` | one-off: repo + passphrase file (passphrase never echoed) |
| `install-restic.sh` | restic 0.19.1 from upstream, checksum-verified |
| `install-syncthing.sh` | Syncthing from upstream apt, prepares the repo folder |
| `fix-restic-perms-for-syncthing.sh` | one-off: `a+rX` so the daemon can read |
| `mount-esp.sh` | one-off: pin the ESP in fstab |
| `add-restic-cron.sh`, `add-syncthing-cron.sh` | guarded crontab edits |
| `nightly_summary.sh` | modified: LOGS, EXPECTED, LABEL, staleness, TLDR lines |

Destructive and cron-touching scripts back up first and roll back on failure.

Five single-use scripts were deleted after the work was done, because each was
guarded against state that no longer exists and would now refuse to run:
`recon-sudo.sh` and `recon-p3.sh` (surveyed the Windows partition),
`reformat-p3-restic.sh` (required NTFS + the old UUID), `rename-restic-mount.sh`
(required `/mnt/restic`), and `diagnose-restic-corruption.sh` (hardcoded to the
one file and blob from the RAM incident). What they found and did is recorded
above, including the diagnostic method for the last one.

---

## Retrieving from the repo

All reads go *through* restic, never by opening the directory:

```
sudo restic-wbu snapshots                                  # list backups
sudo restic-wbu ls latest                                  # browse a snapshot
sudo restic-wbu restore latest --include <path> --target /tmp/out
sudo restic-wbu dump latest <path> > out                   # stream one file
sudo restic-wbu mount /mnt/restic-browse                   # FUSE, read-only
```

At the s3g end, `restic -r D:\immich-restic …` with the passphrase. FUSE mount is
Linux/macOS only.

---

## Open items

1. **Passphrase off-site copy — CRITICAL, unresolved.** `/root/.restic-passphrase`
   lives on the same machine as the source data. If Amsterdam is lost, the s3g copy
   is undecryptable without a passphrase record that is **not in Amsterdam**.
   Password manager that syncs off-site, and/or paper at the GC location. No script
   can fix this one. The chosen passphrase is under 12 characters — accepted
   deliberately, per the original decision that encryption here is mandatory rather
   than desired.
2. **Verify the s3g copy once seeded.** `restic -r D:\immich-restic check` from
   Windows. This is what turns "the copy finished" into "the copy is openable".
   Until it is done, the off-site copy is unproven.
3. **Additional nodes.** rws (Philly) is the strongest candidate — different
   continent, already in the mmm Syncthing mesh, needs ~100 GB. mb2 skipped: same
   city, and 85 GB on a MacBook Air duplicates what s3g holds. **Do not seed two
   remotes at once** — they share one uplink, halving both and extending the window
   with no completed off-site copy.
4. **`fleet-configs` snapshot.** fstab and root crontab both changed 2026-08-25.
5. **FleetNAS checksum audit** — see the RAM section.
6. **Memtest the two removed DIMMs.**
7. **Syncthing version skew** — wbu 1.30.0, s3g 2.1.3. Working; align eventually.

---

## Edit log

**2026-08-25 UTC — Created.** Off-site approach settled: restic on wbu + Syncthing
to s3g D: (→ sgc Jan 2027). Supersedes Next-Level Plan Workstream A1. Google Drive
too tight at ~153 GB free; OneDrive ruled out on 100k-small-file handling; restic
chosen for versioning + integrity despite mandatory encryption and repo opacity.

**2026-08-25 UTC — Built.** Repo location resolved (`/mnt/immich-backup/restic` on
p3, reclaimed from Windows). Retention set to 14/8/24. Derived data excluded,
dropping the backup set from ~118 GB to ~89 GiB. Prune set monthly to avoid
Syncthing churn. Cron at 04:00 and 06:25. Summary integration with three-state
off-site reporting. Syncthing installed on wbu — the original doc's claim that it
was already deployed there was wrong. Corrected the claim that the 1am backup-c job
was failing: it was deliberately disabled 2026-07-22. **A four-DIMM memory fault was
found and fixed during the first backup** — see above. Initial seed to s3g started
~21:00 local, ETA ~8 h.
