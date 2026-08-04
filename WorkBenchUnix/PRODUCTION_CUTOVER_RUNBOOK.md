# WorkBenchUnix — Dual-Boot Teardown / Production Cutover Runbook

**Host:** `workbenchunix` (wbu) — Ubuntu, ex dual-boot (Win11 + Ubuntu)
**Written:** 2026-08-04
**Status:** not yet executed
**Goal:** retire every remnant of the Windows half of this box now that it is a
production host, and close the boot-path gap found while surveying it.

Phase 1 ends in a reboot. Physical access is *preferred* but — after the
2026-08-04 verification below — not required; Phase 1 writes bytes identical to
what is already on the ESP. Phase 3 does need you at the console.

---

## Before you start

**Have ready:**

- [ ] An Ubuntu live USB, tested and bootable on this box. Cheap insurance
      whenever the bootloader is in scope, even at this low risk level.
- [ ] The firmware boot-menu key for this board (usually `F12`/`F11`/`Del` at POST).
- [ ] ~30 min for Phases 1–2. Phase 3 is separate and can wait for another day.

**Do** run Phase 3 (partition changes) at the console, on a different day, and
only after Phase 1 is confirmed with a clean reboot.

---

## Why this runbook exists

The survey on 2026-08-04 found `/boot/efi` is an **empty directory, not a
mountpoint**, and the EFI System Partition (`nvme0n1p1`, 100M vfat) is **absent
from `/etc/fstab`**. Firmware boots `\EFI\UBUNTU\SHIMX64.EFI` from that ESP:

```
BootCurrent: 0001
Boot0001* Ubuntu  HD(1,GPT,cd27f065-…,0x800,0x32000)/File(\EFI\UBUNTU\SHIMX64.EFI)
```

### Verified 2026-08-04 — the ESP is current, nothing was missed

An earlier draft of this runbook claimed the boot binaries were "frozen" and
that security updates had not been reaching the box. **That was wrong.**
Measured on the mounted ESP:

```
a831af01…  /mnt/sdd1-check/EFI/ubuntu/grubx64.efi
a831af01…  /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
a831af01…  /mnt/sdd1-check/EFI/Boot/bootx64.efi
```

The ESP's grub is **byte-identical** to what the installed package ships. And
the package has been installed exactly once, never upgraded:

```
2026-05-23 18:13:51 install grub-efi-amd64-signed:amd64 <none> 1.202.5+2.12-1ubuntu7.3
```

So there have been **zero missed upgrades**. The ESP matches because nothing has
changed since install — not because anything is being maintained.

Two further findings that lower the stakes:

- **Secure Boot is disabled** — `SecureBoot` efivar reads `0`, `SetupMode`
  reads `1`. SBAT / shim-revocation concerns do not apply to this box.
- **`shim-signed` is not installed** — no `/usr/lib/shim`, nothing owns it per
  `dpkg -S`. The `shimx64.efi` on the ESP is an unmanaged leftover from the
  2026-05-19 install. With Secure Boot off it is just a passthrough loader.

ESP timeline, from file mtimes:

| Date | What happened |
|---|---|
| 2026-05-19 15:46 | Installer wrote `shimx64.efi`, `mmx64.efi`, `BOOTX64.CSV`, `fbx64.efi` |
| 2026-05-23 18:13 | `grub-efi-amd64-signed` installed |
| 2026-05-23 22:14 | A `grub-install` ran — wrote `grubx64.efi`, `bootx64.efi`, `grub.cfg` |
| since | ESP untouched; `/boot/efi` unmounted at some point after |

The ESP's `grub.cfg` stub points at `search.fs_uuid 7bbba983-…`, the *current*
root UUID (`p6`) — so that `grub-install` ran after the partition renumbering
that moved root from `p5` to `p6`.

### What is actually still wrong

`/boot/efi` is not mounted, so the **next** `grub-efi-amd64` upgrade will not
reach the ESP. That is a real latent defect and worth fixing — but it is a
future risk, not accumulated debt.

Practical consequences of that correction:

- This does **not** need a console session with a live USB standing by. It can
  be done calmly, and reasonably over SSH.
- The fix is provably low-risk: `grub-install` will write the same bytes that
  are already on the ESP (hash above). The content change is nil; only the
  fstab entry is new.
- Phase 1 is no longer urgent. It is still worth doing before the next
  `apt upgrade` that touches grub.

---

## Current state (surveyed 2026-08-04)

```
nvme0n1     953.9G  Lexar SSD NQ780 1TB
├─nvme0n1p1   100M  vfat   EFI System                    ← ESP, NOT MOUNTED
├─nvme0n1p2    16M         Microsoft reserved            ← dead
├─nvme0n1p3 248.7G  ntfs   Windows C:                    ← dead
├─nvme0n1p4 605.9G  ext4   immich-data  → /mnt/immich-data  LIVE (314G used)
├─nvme0n1p5   812M  ntfs   Windows recovery              ← dead
└─nvme0n1p6  97.7G  ext4   → /                           LIVE (58% full, 39G free)
```

Known UUIDs (from the survey — re-confirm before use, do not paste blind):

| Partition | Role | UUID |
|---|---|---|
| `nvme0n1p6` | `/` | `7bbba983-56ae-4bc2-878a-4f41b4a60347` |
| `nvme0n1p4` | `/mnt/immich-data` | `c10ca9cc-c875-480e-8c29-e48709455690` |
| (external) | `/mnt/backup-c` | `7c8f2b39-7b74-430b-8008-caad772d0805` |
| `nvme0n1p1` | ESP | `1A00-4C49` (PARTUUID `cd27f065-a240-43e7-96b4-5d794b0f4ea2`) — confirmed 2026-08-04 |

NVRAM boot entries:

```
BootOrder: 0001,0013,0012
Boot0001* Ubuntu                 → \EFI\UBUNTU\SHIMX64.EFI      keep
Boot0012* Hard Drive             → BBS fallback                 keep
Boot0013* Windows Boot Manager   → \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI   remove (Phase 2)
```

---

## Phase 0 — Capture rollback state — DONE 2026-08-04

Everything here is read-only against the disk. Save the output somewhere off-box.

**Paste one line at a time.** A wrapped multi-line block broke on first run: the
`lsblk … > lsblk.before` redirect split across lines and silently produced no
file. No trailing `#` comments either — a wrapped comment ran as a command.

```bash
OUT=~/wbu-cutover-$(date +%F); mkdir -p "$OUT"; cd "$OUT"; sudo -v
sudo cp -p /etc/fstab fstab.before
sudo cp -p /etc/default/grub default-grub.before
sudo efibootmgr -v > efibootmgr.before
sudo blkid > blkid.before
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT,PARTTYPENAME > lsblk.before
findmnt -A > findmnt.before
sudo sgdisk --backup=gpt-header.before /dev/nvme0n1
sudo sfdisk -d /dev/nvme0n1 > sfdisk-dump.before
sudo mount /dev/nvme0n1p1 /mnt/sdd1-check
sudo tar czf esp-backup.tar.gz -C /mnt/sdd1-check .
sudo umount /mnt/sdd1-check
sudo chown -R "$USER:$USER" "$OUT"
ls -la "$OUT"
```

Expect **9 files**. Verify rather than assume:

```bash
tar tzf esp-backup.tar.gz >/dev/null && echo "archive OK"
diff -q fstab.before /etc/fstab && echo "fstab captured correctly"
findmnt /mnt/sdd1-check || echo "ESP unmounted — good"
```

What each rollback artifact buys you:

| File | Restores | Limit |
|---|---|---|
| `gpt-header.before` | Partition table, via `sudo sgdisk --load-backup=gpt-header.before /dev/nvme0n1` | Table only, **not data** — useless once a new filesystem is written |
| `sfdisk-dump.before` | Same information, human-readable | Reference/verification, not a restore tool |
| `esp-backup.tar.gz` | Full ESP contents | Restore by mounting the ESP and untarring over it |
| `fstab.before`, `default-grub.before` | Config, by `cp` back | — |

`file gpt-header.before` reporting *"DOS/MBR boot sector"* is **correct**, not a
problem — sgdisk's backup begins with the protective MBR.

### Run results, 2026-08-04

All 9 artifacts verified present and intact:

```
blkid.before  1765      efibootmgr.before  2002     esp-backup.tar.gz  19,459,113 (205 entries, OK)
findmnt.before  16010   fstab.before  1119         gpt-header.before  17,920
default-grub.before  1605    lsblk.before  2821    sfdisk-dump.before  1202
```

`fstab.before` is byte-identical to the live `/etc/fstab`. The ESP tarball
contains `EFI/ubuntu/{shimx64.efi,grubx64.efi,grub.cfg}`. ESP left unmounted.

Preserved mtimes worth noting: `/etc/fstab` last modified **2026-07-27**,
`/etc/default/grub` **2026-05-24**.

- [x] Phase 0 complete
- [ ] Output copied off-box ← **still to do**

---

## Phase 1 — Restore the ESP to fstab

Low risk (see the verification section above), but it does end in a reboot, so
do it on its own and confirm before moving on.

> **Steps 1.1 and 1.2 were already completed on 2026-08-04.** The ESP was
> mounted at `/mnt/sdd1-check`, inspected, and hash-verified. If you are picking
> this up fresh, re-run them anyway — they are read-only. If the ESP is still
> mounted at `/mnt/sdd1-check` from that session, `umount` it before 1.3.
>
> Still outstanding from 1.2: **the ESP backup tarball was never taken.** Do
> that before 1.4.

### 1.1 Verify the finding — DONE 2026-08-04

Result: `findmnt /boot/efi` non-zero, `/boot/efi` empty, no efi line in fstab,
`blkid` → `UUID="1A00-4C49" TYPE="vfat"`. Finding confirmed; proceed.

To re-verify from scratch (all read-only):

```bash
findmnt /boot/efi ; echo "findmnt exit: $?"
ls -A /boot/efi
grep -n efi /etc/fstab
sudo blkid /dev/nvme0n1p1
```

| Result | Meaning | Action |
|---|---|---|
| `findmnt` non-zero, `/boot/efi` empty, no efi line in fstab | Finding confirmed *(this is what was observed)* | Continue to 1.2 |
| `findmnt` shows `/dev/nvme0n1p1 on /boot/efi` | ESP already mounted | **Stop Phase 1.** Skip to Phase 2. |
| `/boot/efi` non-empty but not a mountpoint | Files were written to root's disk instead of the ESP | Continue to 1.2, but see the note in 1.4 |

### 1.2 Inspect the ESP — DONE 2026-08-04 (except the backup)

```bash
sudo mount /dev/nvme0n1p1 /mnt/sdd1-check
ls -la --time-style=long-iso /mnt/sdd1-check/EFI/ubuntu/
df -h /mnt/sdd1-check
```

Observed:

```
EFI/  ├─ Boot/       bootx64.efi, fbx64.efi, mmx64.efi
      ├─ Microsoft/  32M — dead, removed in Phase 2.2
      └─ ubuntu/     4.3M — BOOTX64.CSV, grub.cfg, grubx64.efi, mmx64.efi, shimx64.efi

/dev/nvme0n1p1   96M  40M used  57M avail  41%
```

Abort condition **not** triggered — `EFI/ubuntu/shimx64.efi` is present, so the
box is booting from where we assumed.

The staleness check (this is what produced the correction in the section above):

```bash
sha256sum /mnt/sdd1-check/EFI/ubuntu/grubx64.efi \
          /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
```

Identical hashes ⇒ ESP grub is current, nothing missed. If a future run of this
runbook shows these **differing**, that genuinely means an upgrade was lost and
Phase 1 becomes urgent.

**Still outstanding — take the backup before proceeding:**

```bash
sudo tar czf ~/wbu-cutover-$(date +%F)/esp-backup.tar.gz -C /mnt/sdd1-check .
sudo umount /mnt/sdd1-check
```

- [x] ESP contents reviewed and hash-verified (2026-08-04)
- [ ] `esp-backup.tar.gz` saved
- [ ] `/mnt/sdd1-check` unmounted

### 1.3 Add the ESP to fstab

```bash
sudo vi /etc/fstab
```

Add this line, substituting the UUID from Step 1.1 — this is the stock Ubuntu
ESP entry:

```
UUID=<ESP-UUID-from-1.1>  /boot/efi  vfat  umask=0077  0  1
```

Write and quit: `:wq`

While you are in the file, delete the dead commented Windows line (it refers to
a mount that will never exist again):

```
#UUID=01DD018664F869F0  /mnt/win-c  ntfs3  defaults,uid=1000,gid=1000,umask=022,windows_names  0  0
```

Leave the commented `backup-a` / `backup-b` lines alone for now — they are a
separate decision, see Phase 4.

### 1.4 Mount and reinstall the bootloader

```bash
sudo mount -a
findmnt /boot/efi        # must now show /dev/nvme0n1p1
```

> If Step 1.1 found `/boot/efi` non-empty and not a mountpoint, those files are
> now shadowed under the mount and are wasting root-fs space. Deal with that
> *after* Phase 1 is confirmed by reboot — unmount `/boot/efi`, delete the
> shadowed contents, remount. Not now.

```bash
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu
sudo update-grub
```

Expected: `Installation finished. No error reported.`

Confirm what landed:

```bash
ls -la --time-style=long-iso /boot/efi/EFI/ubuntu/
sudo efibootmgr -v | grep -i ubuntu
sha256sum /boot/efi/EFI/ubuntu/grubx64.efi /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
```

`grubx64.efi` gets a fresh timestamp but the **same hash** as before
(`a831af01…`) — expected, since the ESP was already current. `shimx64.efi` will
*not* be rewritten: `shim-signed` is not installed on this box, so nothing
manages that file.

> **Watch the NVRAM entry.** `Boot0001` currently points at
> `\EFI\UBUNTU\SHIMX64.EFI`. With `shim-signed` absent, `grub-install` may
> repoint it at `\EFI\UBUNTU\GRUBX64.EFI` instead. Either boots fine here
> (Secure Boot is off), but check `efibootmgr -v` after, and know which one it
> says before you reboot — if the box does not come up, that line is the first
> thing to look at.

### 1.5 Reboot and confirm

```bash
sudo reboot
```

- [ ] Box came back up on its own
- [ ] `findmnt /boot/efi` shows the ESP mounted after reboot
- [ ] `uname -r` matches the expected kernel

**If it does not boot:** boot the live USB, mount root + ESP, and restore from
`esp-backup.tar.gz`. The pre-change ESP is a known-good working state — that is
the whole point of taking it in 1.2.

**Do not proceed to Phase 2 until this reboot is confirmed clean.**

---

## Phase 2 — Remove Windows boot remnants

Only after Phase 1 is confirmed. Each item here is independently reversible.

### 2.1 Drop the dead Windows NVRAM entry

```bash
sudo efibootmgr -v | grep -i windows      # confirm it is still 0013
sudo efibootmgr -b 0013 -B
sudo efibootmgr -v                        # Boot0013 gone, BootOrder now 0001,0012
```

Reversible: the entry can be recreated with `efibootmgr -c` if ever needed. It
points at `\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI`, which 2.2 deletes — so do 2.1 and
2.2 together or not at all.

### 2.2 Delete Microsoft's directory from the ESP

Measured 2026-08-04: `EFI/Microsoft` is **32M of the 40M used** on a 96M ESP
(41% full). Removing it drops usage to roughly 8M / 8% — the single biggest
cleanup win in this runbook by proportion, and it matters because a 100M ESP
(Windows' default size, not Ubuntu's 512M) has little headroom for future
kernels/fwupd.

```bash
du -sh /boot/efi/EFI/Microsoft      # expect ~32M
sudo rm -rf /boot/efi/EFI/Microsoft
df -h /boot/efi
```

Reversible from `esp-backup.tar.gz`.

### 2.3 Stop os-prober scanning the dead NTFS partitions

`/etc/default/grub` has `GRUB_DISABLE_OS_PROBER=false` appended at the **bottom**
of the file, overriding the commented-out default higher up. That is what makes
every `update-grub` mount and scan the NTFS partitions.

```bash
sudo vi /etc/default/grub
```

Change the last line from:

```
GRUB_DISABLE_OS_PROBER=false
```

to:

```
GRUB_DISABLE_OS_PROBER=true
```

Optional while you are in there — a 15-second boot menu on a single-OS
production box is not doing anything for you:

```
GRUB_TIMEOUT=2
```

`:wq`, then:

```bash
sudo update-grub          # should no longer mention "Found Windows Boot Manager"
sudo apt purge os-prober
```

### 2.4 Purge the BIOS-grub leftover

`grub-pc` sits in `rc` state (config files only) from the pre-UEFI era.
`grub-pc-bin` was already removed on 2026-07-02.

```bash
dpkg -l grub-pc            # confirm state is 'rc', not 'ii'
sudo apt purge grub-pc
```

**Read the apt output before confirming.** If apt proposes removing
`grub-efi-amd64`, `grub-efi-amd64-signed`, `shim-signed`, or `grub-common`,
answer **no** and stop — that would take out the live bootloader.

- [ ] Phase 2 complete
- [ ] `sudo update-grub && sudo reboot` — confirm one more clean boot

---

## Phase 3 — Reclaim the ~250 GB of dead partitions

Separate sitting. Nothing here is required for the box to be "production" — it
is space recovery.

### 3.1 Understand what is and is not possible

The obvious move — grow `/` into the 248 GB — **is not available.** Root (`p6`)
is the *last* partition on the disk. Deleting the Windows C: partition (`p3`)
opens a hole at position 3, with 606 GB of live Immich data (`p4`) sitting
between that hole and root:

```
p1 ESP │ p2 MSR │ p3 Windows 248.7G │ p4 immich-data 605.9G │ p5 recovery │ p6 / 97.7G
                  └── freed space ──┘                                        └─ wants to grow
```

Closing that gap means relocating `p4` offline in GParted: hours of shuffling
314 GB of live Immich data, with a power cut or a bad sector in the middle of it
as the failure mode. **Not worth it** for a root fs currently at 58%.

Two sane options instead:

**Option A (recommended) — reformat p3 in place as its own filesystem.**
Zero data movement, zero risk to `p4`/`p6`, takes about a minute.

**Option B — do nothing.** 39 GB free on root is not urgent. Revisit if root
crosses ~80%.

### 3.2 Option A: reformat p3 as ext4

> ### ⚠ p3 and p4 are not distinguishable by type or label
>
> Found in the Phase 0 `sfdisk` dump (2026-08-04). The dead Windows C: (`p3`)
> and the **live 314 GB Immich store** (`p4`) share the *same* GPT type GUID and
> the *same* partition name:
>
> ```
> p3 : size=521637888,  type=EBD0A0A2-…-68B6B72699C7, name="Basic data partition"
> p4 : size=1270560768, type=EBD0A0A2-…-68B6B72699C7, name="Basic data partition"
> ```
>
> `p4` reads as "Microsoft basic data" in `lsblk` because it was carved out as a
> Windows partition and later reformatted ext4 — the type GUID was never
> changed. So **"the Microsoft basic data partition" is ambiguous on this disk**,
> and any instruction phrased that way could destroy the Immich store.
>
> Discriminate only by **PARTUUID**, size, and fstype:
>
> | | PARTUUID | Size | FS | Verdict |
> |---|---|---|---|---|
> | `p3` | `E40EC27B-8856-4412-ADBE-43386DDC017F` | 248.7G | ntfs | **target** |
> | `p4` | `0001E925-3A80-64FC-8639-DF1F4AD20300` | 605.9G | ext4 `immich-data` | **DO NOT TOUCH** |

Verify all three signals agree before writing anything:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTUUID /dev/nvme0n1
sudo blkid /dev/nvme0n1p3
findmnt /mnt/immich-data          # confirm which device Immich is actually on
```

**Abort unless `/dev/nvme0n1p3` is all of:** 248.7G, `TYPE="ntfs"`,
PARTUUID `E40EC27B-8856-4412-ADBE-43386DDC017F`, and **not** the device backing
`/mnt/immich-data`.

Partition numbers on this box have shifted before — the curtin comment in
`fstab` says root was `p5` at install time and it is `p6` now — so never trust
the number alone.

Safer still, address the partition by PARTUUID rather than by `pN`:

```bash
ls -l /dev/disk/by-partuuid/E40EC27B-8856-4412-ADBE-43386DDC017F
```

```bash
sudo wipefs -a /dev/nvme0n1p3
sudo mkfs.ext4 -L scratch /dev/nvme0n1p3
sudo blkid /dev/nvme0n1p3        # note the NEW UUID
```

Mount it — use `nofail` and a device timeout, matching the `backup-c` entry
style already in `fstab`, so a future problem with it cannot block boot:

```bash
sudo mkdir -p /mnt/scratch
sudo vi /etc/fstab
```

```
UUID=<new-uuid-from-blkid>  /mnt/scratch  ext4  defaults,nofail,x-systemd.device-timeout=5  0  2
```

`:wq`, then:

```bash
sudo mount -a
df -h /mnt/scratch
```

### 3.3 Optional: delete p2 and p5

`p2` (16M Microsoft reserved) and `p5` (812M Windows recovery) are dead but
tiny. `p5` sits immediately before root, so deleting it is the only 812 MB that
could actually be given to `/`.

Do this at the console with GParted, not over SSH, and not in the same sitting
as anything else. The CLI equivalent is `sudo sgdisk -d 2 -d 5 /dev/nvme0n1` —
correct, but a typo'd partition number there destroys a live filesystem. Undo is
`sudo sgdisk --load-backup=gpt-header.before /dev/nvme0n1` from Phase 0.

Honestly: the ~830 MB is not worth the keystrokes. Recommended to skip.

- [ ] Phase 3 decision made (A / B / skip)

---

## Phase 4 — Cosmetic leftovers

All empty directories on the root fs, ~4–12K total. No data at risk — verified
empty during the 2026-08-04 survey, but re-check before deleting.

```bash
for d in win-c win-d win_share google_take_out backup-a backup-b; do
  printf '%-18s ' "$d"; ls -A /mnt/$d 2>/dev/null | tr '\n' ' '; echo
done
```

Expect all blank except `win-d`, which holds an empty `immich/images/` tree left
over from the 2026-06-30 `win-d` → `immich-data` mount rename.

```bash
sudo rmdir /mnt/win-c /mnt/win_share /mnt/google_take_out /mnt/backup-a /mnt/backup-b
sudo rm -rf /mnt/win-d
```

`rmdir` fails rather than deleting if a directory turns out not to be empty —
that is the safety here, which is why it is used instead of `rm -rf` for all but
`win-d`.

**Keep `/mnt/sdd1-check`** — it is a useful scratch mountpoint, and Phase 1 uses it.

**Keep `ntfs-3g`** — ~1 MB, and you will want it the next time someone hands you
a USB stick. Nothing needs it removed.

`/etc/fstab` commented `backup-a` / `backup-b` lines: leave or delete as you
prefer. They document two drives that used to be attached; if those drives are
gone for good, delete the lines.

- [ ] Phase 4 complete

---

## Phase 5 — Record the new production state

```bash
cd /home/dhm/repos/scripts/WorkBenchUnix
./wbu-snapshot-fleet-configs.sh
```

The snapshot copies `/etc/fstab` into `fleet-configs` (`wbu-snapshot-fleet-configs.sh:9`),
so the production fstab gets captured. Note the repo convention: **review before
committing in `fleet-configs`, and ask before pushing** — run `git status` there
and check the diff is only what you intended.

Also note: the root crontab capture needs local `sudo` and cannot be refreshed
over a non-interactive SSH session. Since you are running this runbook at the
console anyway, this is a good moment to get a fresh `crontab-l-root.txt`.

- [ ] Snapshot run, `fleet-configs` diff reviewed
- [ ] Committed (after review)

---

## Post-run verification

```bash
findmnt /boot/efi                          # ESP mounted
sudo efibootmgr -v | grep -ci windows      # 0
grep -i osprober /etc/default/grub         # GRUB_DISABLE_OS_PROBER=true
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT # no ntfs rows (if Phase 3A ran)
df -h | grep -v snap
sudo update-grub                           # clean, no Windows entries found
```

Then one final reboot to confirm the box comes up unattended.

- [ ] All checks pass
- [ ] Final reboot clean
- [ ] Mark this runbook **executed <date>** at the top

---

## Nothing else in the repo needs changing

Checked during the survey:

- The `win-c` / `win-d` references across `WorkBenchUnix/*.sh` and
  `ChatWorkhorseUnix/restore_from_wbu.sh` are all **dated changelog comments**
  from the 2026-06-30 mount rename. No live path depends on them.
- No doc anywhere in the repo describes this box as experimental, so there is no
  status text to flip to "production."
