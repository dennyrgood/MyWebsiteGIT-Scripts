# FleetNAS health scripts

Monitoring for **FleetNAS** (`192.168.178.123`), a UGREEN NAS running a 3-drive
RAID5 array. Two scripts: a 5-minute alerting monitor and a daily summary email.

Both scripts **run on FleetNAS** (from root's crontab) but are **edited on WBU**
and deployed with `sync-this-nas`. See [Editing and deploying](#editing-and-deploying).

| File | What it is |
|---|---|
| `nas-health-monitor.sh` | Every 5 min. Silent unless something is wrong; emails alerts and all-clears. |
| `nas-nightly-summary.sh` | 05:00 UTC. Always emails a full status report. |
| `logrotate-nas-health-monitor` | logrotate config for the monitor's alert log. Must be **installed** into `/etc/logrotate.d/`; syncing the repo is not enough. |
| `sync-this-nas` | A reminder stub. The real script lives on WBU at `~/repos/scripts/sync-this-nas`. |

Root's crontab on FleetNAS:

```
*/5 * * * * /home/dhm/repos/scripts/nas/nas-health-monitor.sh 2>&1 | logger -t nas-health-monitor
0 5 * * *   /home/dhm/repos/scripts/nas/nas-nightly-summary.sh 2>&1 | logger -t nas-nightly-summary
```

Cron runs the **working copy in the repo directly**, so a successful
`sync-this-nas` is the whole deploy.

## How mail gets out

FleetNAS has no `msmtp`. Both scripts pipe the message over SSH to WBU
(`dhm@192.168.178.242`) and send it there:

```
ssh -o BatchMode=yes "$WBU" "sudo msmtp --account=icloud $TO"
```

`sudo` is needed on WBU because `/etc/msmtprc` is root-only. Recipient is
`dennyrgood@yahoo.com`. **If WBU is down, alerts do not go out** — the monitor
still writes them to its local log.

---

## nas-health-monitor.sh

Runs every 5 minutes. Emails only when a condition fires or clears, so **no mail
is good news**. Every alert email carries a footer explaining what the condition
means and what to do about it.

### What it checks

| Condition | Fires when | Anti-flap |
|---|---|---|
| SMART unreadable | `smartctl` missing, or can't open the drive, or output won't parse | 2 consecutive (~10 min) |
| SMART overall-health | `-H` result is not `PASSED` | 2 consecutive |
| Reallocated sectors | `Reallocated_Sector_Ct` > 0 | 2 consecutive |
| Pending sectors | `Current_Pending_Sector` > 0 | 2 consecutive |
| Drive temperature | > `TEMP_THRESHOLD` (45 °C) | 2 consecutive |
| RAID array | state not `clean`/`active`, or unreadable | none — immediate |
| Disk usage | any real filesystem > `DISK_THRESHOLD` (85%) | none — immediate |
| UPS unreadable | `upsc` returns nothing | 2 consecutive |
| UPS replace battery | status contains `RB` | none — sticky fault |

Drive checks run per drive across `DRIVES=(sda sdb sdc)`.

A **degraded array that is also recovering** does not alert — that's an expected
rebuild, and the nightly reports it instead.

### Alert lifecycle

State lives in `/tmp/nas-monitor-state.tmp` and is re-read each run, so the
script knows what was already firing. Per condition:

- **alert** — first trip (or `ALERT_INTERVAL`, 30 min, since the last alert while
  still firing). Sends mail, appends to the log.
- **suppress** — still firing, but within the 30-minute window. Silent.
- **clear** — was firing, now isn't. Sends an ALL CLEAR.
- **wait** — triggered but the streak hasn't reached the threshold yet. Silent.

State resets on reboot (it's in `/tmp`), which just means the first post-boot
alert re-sends.

### SMART is tri-state, deliberately

`healthy` / `failing` / **`unreadable`** are three different things. A failed
SMART read is never defaulted to `0` — doing so is what made this script blind
for its entire life before 2026-08-07 (see [Gotchas](#gotchas)).

When a drive is unreadable, its realloc/pending/temp/health conditions are
**frozen at their last known values, not cleared**. Without this, a genuinely
failing drive that went unreadable would trip `clear` and email you an
**ALL CLEAR** — the worst possible outcome.

---

## nas-nightly-summary.sh

Runs at 05:00 UTC and always sends. Opens with a TLDR block, then detail
sections: SMART per drive (with model, serial, power-on hours), full `mdadm
--detail`, disk usage, `upsc` output, monitor state, and recent monitor events.

### Subject line

Reports the **most severe** issue found, plus `(+N more)`:

| Tier | Emoji | Examples |
|---|---|---|
| crit | ⚠️ | SMART drive error, RAID failed/degraded, RAID unreadable, UPS replace battery |
| warn | ⚠️ | SMART unreadable, disk >85%, UPS unreadable, monitor stale/missing, active health alerts |
| info | 🔄 | RAID rebuilding (with % and ETA) |
| none | ✅ | `all healthy` |

A **rebuild is surfaced in the subject** on purpose: it's the window in which a
second drive failure destroys the array, so it shouldn't be silent even though
it's expected and self-resolving.

### What it deliberately does *not* print

- **Pseudo-filesystems.** Disk usage is filtered to real `/dev/*` devices,
  excluding loop mounts. The udev/tmpfs/overlay/efivarfs lines were noise, and
  the squashfs loop mounts backing the UGREEN OS are permanently 100% full.
  `/volume1` and `/home` are two btrfs subvolumes of the *same* filesystem, so
  they share one pool and always report identical usage — collapsed into one row
  listing both mountpoints.
- **The whole state file.** Only active alerts, plus any condition with a streak
  above zero (something going wrong that hasn't alerted yet).
- **The whole alert log.** Only the last 24h of event headers. Each logged alert
  carries the same ~80-line remediation footer, so dumping the log meant
  re-reading that footer once per alert ever recorded.

### Monitor freshness

If `/tmp/nas-monitor-state.tmp` is older than `MONITOR_STALE_SECS` (15 min) or
missing, the nightly flags it — that's the check that catches the monitor itself
having died.

---

## logrotate-nas-health-monitor

`/var/log/nas-health-monitor.log` had no rotation and grew forever. Config is
weekly, 8 rotations, compressed, rotating early if it passes 1M.

**Installing it is a separate manual step** — `sync-this-nas` updates the repo,
not `/etc`. On FleetNAS:

```
cd ~/repos/scripts/nas
sudo cp logrotate-nas-health-monitor /etc/logrotate.d/nas-health-monitor
sudo chown root:root /etc/logrotate.d/nas-health-monitor
sudo chmod 644 /etc/logrotate.d/nas-health-monitor
```

Verify (`weekly (8 rotations)`, no `note:` lines):

```
sudo logrotate -d /etc/logrotate.d/nas-health-monitor
```

Re-run the install after any change to the config in the repo.

---

## Editing and deploying

Edit on **WBU**, in `~/repos/scripts/nas/`. Then from `~/repos/scripts`:

```
./sync-this-nas "commit message"
```

It asks both sides whether `nas/` is dirty and picks the direction: NAS dirty →
pull, WBU dirty → push, both dirty → it stops and makes you choose. Either way
FleetNAS ends `reset --hard origin/main`, so both sides finish identical.

FleetNAS has **no git binary** — `sync-this-nas` does its git through an
`alpine/git` Docker container. Don't try to run git there directly.

Deletions are one-way: if you delete a file on FleetNAS, delete it on WBU too,
then sync.

**Don't leave scratch files in `nas/` on either side.** `sync-this` stages with
`git add -A`, and pull mode tars the NAS's whole `nas/` directory back, so any
stray file there gets committed and pushed. (A throwaway `cmd` file used to run
a `sudo` step on the NAS ended up on GitHub this way on 2026-08-07.) Pull mode
also carries the NAS's permissions back — files land there mode 777, which is
how the logrotate config briefly became executable. Keep scratch work in
`~/nastest/` or `/tmp`, not in the repo.

## Testing without sending mail

Both scripts honour `NAS_DRYRUN=1`, which prints the message instead of emailing
it. The monitor also takes `NAS_STATE_FILE` and `NAS_LOG_FILE` so a test run
can't disturb live state:

```
cd ~/repos/scripts/nas
sudo NAS_DRYRUN=1 ./nas-nightly-summary.sh | head -20
```

Monitor against scratch state (expect no output when healthy):

```
sudo NAS_DRYRUN=1 NAS_STATE_FILE=/tmp/s.test NAS_LOG_FILE=/tmp/l.test ./nas-health-monitor.sh
```

To exercise the *unreadable* paths, run without `sudo` — `smartctl` and `mdadm`
then genuinely fail to read the hardware, which is exactly the condition being
tested. Streak-based conditions need two runs to fire.

---

## Gotchas

Every one of these cost real debugging time. They're the reason the code looks
the way it does.

**Root's cron PATH is `/usr/bin:/bin`.** `smartctl` and `mdadm` live in `/sbin`,
so a bare command name finds nothing. Both are referenced by absolute path
constants (`SMARTCTL`, `MDADM`). This was the original bug: with `2>/dev/null`
and `:-0` defaults, every drive read as `health= realloc=0 pending=0 temp=0`, so
the nightly flagged all 3 drives ⚠️ daily *and* the monitor could not fire a
SMART alert at all. `upsc`, `logger`, and `ssh` are in `/usr/bin` and were fine.

**`smartctl` exits nonzero on healthy drives here.** These WD80EFPX drives always
report `SMART Attribute Thresholds Structure error: invalid SMART checksum`,
setting exit bit 4, while serving perfectly good data. So `rc != 0` must **not**
mean "unreadable" — only bit 2 (device open failed) does, plus a parse check.

**Never default a failed sensor read to a healthy value.** `${VAR:-0}` on a
failed SMART read turns "I can't see the drive" into "the drive is perfect".

**logrotate: `size` silently overrides `weekly`.** `size 1M` makes rotation
purely size-driven. To keep a weekly schedule with a size escape hatch, use
`maxsize`. `logrotate -d` tells you: `note: 'size' overrides previously
specified 'weekly'`.

**logrotate ignores group/world-writable config files.** Synced repo files can
land as mode 777, so install into `/etc/logrotate.d/` with an explicit
`chmod 644`, not a bare `cp`.

**`scp`/SFTP is restricted on FleetNAS.** To copy a file there ad hoc:
`ssh dhm@192.168.178.123 'cat > ~/dest' < localfile`.

**`sudo` over non-interactive SSH can't prompt for a password.** Anything needing
root on FleetNAS — `smartctl`, `mdadm`, installing to `/etc` — has to be run
from a real session on the box.

---

## Hardware reference

- 3 × WD Red Plus `WD80EFPX-68C4ZN0` (8 TB, rated 0–65 °C) as `sda`/`sdb`/`sdc`.
- RAID5 on `/dev/md1` (~14.5 TiB) → LVM → one **btrfs** filesystem. `/volume1`
  and `/home` are two subvolumes of it (`/@home` for the latter), which is why
  `df` lists the same device twice with identical figures.
- UPS `ups0` via NUT on localhost; `upsc` is in `/usr/bin`.
- Per-drive model, serial, and power-on hours are in every nightly email — use
  those to identify which physical drive to pull, rather than trusting a
  snapshot in this file.

_Last substantive update: 2026-08-07._
