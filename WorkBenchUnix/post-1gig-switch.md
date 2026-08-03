# Post-1GbE-Switch: Finishing the WBU → FleetNAS Immich Backup

**Written 2026-07-31. Updated 2026-08-02** with the Ziggo provisioning numbers, the 1.2 TB
SMB corroboration, and the Wi-Fi chain (AP + client cards) characterization.
**Updated 2026-08-03: the switch is in, and sections 1–3 are done.**

Everything here was blocked on the network, not on the scripts — and that block is now
gone. The gigabit switch is installed, WBU links at 1000 Mb/s, the one-time image load
has run, and both FleetNAS jobs are on cron. What remains is section 4 (nightly checker
integration) and the Btrfs snapshots in section 5.

Sections 1–3 are kept as a record of what was done and what the numbers were, not as
instructions to follow again.

---

## State as of 2026-08-03 — sections 1–3 complete

| Thing | Status |
|---|---|
| `backup_immich_db_to_fleetnas.sh` | Written, **validated twice** end-to-end |
| `backup_immich_images_to_fleetnas.sh` | ✅ **Run 2026-08-03 — 118 GB / 283,460 files in 16m58s** |
| `export_flat_to_fleetnas.sh` / `export_multi_to_fleetnas.sh` | ✅ Written 2026-08-03, destination validated by dry run, **bulk transfer not yet run** |
| SSH key `~/.ssh/id_ed25519_fleetnas` | Installed on NAS, working, no password anywhere |
| WBU `~/.ssh/config` | Created; `ssh fleetnas` / `ssh 192.168.178.123` work keyless |
| WBU link speed | ✅ **1000 Mb/s full duplex**, autonegotiated against the new switch |
| NAS `/volume1/immich/postgres-dumps/` | Holds `immich-dump_2026-07-31_0330.sql` |
| NAS `/volume1/immich/images/` | ✅ **118 GB, 283,460 files — verified identical to WBU** |
| NAS `/volume1/immich/export_flat/`, `export_multi/` | Created, **empty** — ~199 GB still to push |
| Crontab entries | ✅ **Added 2026-08-03** (05:00 DB, 05:20 images) |
| Nightly checker integration | **Not added** — section 4 is the remaining work |
| Scripts committed to git | ✅ Yes |
| Btrfs snapshots on NAS | **Not configured** — still the most important loose end |

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

### Measured 2026-08-01: this switch is throttling the whole house, not just backups

This runbook was scoped around the Immich backups, but the 100 Mb ceiling is capping
**internet access for every device in the house.** Measured from WBU:

| Measurement | Result | Verdict |
|---|---|---|
| Latency to gateway `192.168.178.1` | 0.44 ms | Healthy |
| Latency to `1.1.1.1` | 11.4 ms, 0% loss | Healthy |
| IPv6 (`ping6`, `curl -6`) | Working, on par with v4 | Healthy |
| **Download throughput** | **83 Mbit/s** | ⛔ **Pinned at the 100BASE-TX ceiling** |

100BASE-TX tops out near 94 Mbit real-world; 83 measured. **The internet connection is
capped by the switch, not by Ziggo.**

It's worse than a per-machine cap because of the topology: the **Ziggo router uplinks to
the DES-1024D at 100 Mb, and all 43 LAN devices — every wired box plus everything behind
the Wi-Fi controller — share that single link.** Any one heavy user (a Windows Update, a
4K stream, an Immich backup, the five Wyze cameras uploading) takes a large bite out of
100 Mb shared, and everything else degrades at the same moment. That is the "internet
randomly goes to hell" symptom, and it has a single cause.

**If the Ziggo plan is above 100 Mbit, none of it has ever been delivered.** Worth
checking the plan speed — the switch swap may be a much larger upgrade than the backup
project it was scoped for. *(Checked 2026-08-02 — it is. See immediately below.)*

### Answered 2026-08-02: the plan is 829 Mbit. We are receiving 83.

Read straight off the Ziggo DOCSIS 3.1 modem's status page — these are the provisioned
service-flow rates from the config file (`bac10200010664fa2b24bdac`), not an advertised
marketing number:

| Service flow | Max traffic rate | |
|---|---|---|
| Primary downstream `163471386` | **829,250,000 bps** | **829 Mbit/s** |
| Secondary downstream `163471387` | 64,000,000 bps | 64 Mbit/s |
| Primary upstream `163463193` / `163463196` | 64,200,000 bps | **64.2 Mbit/s** |

After DOCSIS overhead a real speed test should land near **780–800 Mbit down**. Measured
today: **83**. So the house has been getting roughly **10% of the provisioned rate**, and
the DES-1024D accounts for all of it.

This resolves the open question above: the switch swap is not a backup-project nicety,
it is a ~10x internet upgrade that happens to also unblock the backups.

**It also weakens suspect #2 below.** Upstream is provisioned at 64 Mbit, not the ~5–10
Mbit a legacy cable plan would give. Five Wyze cameras do not saturate 64 Mbit. Bufferbloat
stays on the list; camera upstream saturation drops well down it.

### Corroborating measurement: the 1.2 TB SMB transfer

A ~1.2 TB SMB copy, **Wi-Fi PC → FleetNAS (wired)**, took a bit over a day. That works out
to roughly **11–13 MB/s, i.e. ~90–100 Mbit/s** sustained:

| Elapsed | Throughput |
|---|---|
| 24 h | 13.9 MB/s = 111 Mbit |
| 28 h | 11.9 MB/s = 95 Mbit |
| 30 h | 11.1 MB/s = 89 Mbit |
| 36 h | 9.3 MB/s = 74 Mbit |

The elapsed time was not timed precisely, so treat this as a band rather than a point
measurement. But unless it ran well past 30 hours, that transfer was at **line rate for a
100 Mb link** — which tells us three things:

- **Wi-Fi was not the bottleneck.** It sustained ≥90 Mbit for a day. The wired 100 Mb leg
  was the cap.
- **SMB per-file overhead was not a factor** at that size — these were large files.
- **The switch is not degraded, it is simply 100 Mb.** This is the cleanest throughput
  number on the LAN, better than the 83 Mbit internet test and the 6.77 MB/s contended
  figure above. Nothing is faulty; the ceiling is exactly where the spec puts it.

### The Wi-Fi path, characterized 2026-08-02 — the AP is fine, the client cards are not

Since the biggest remaining transfers may run over Wi-Fi, the whole chain was checked.
**The access point is not a bottleneck and does not need replacing.**

| Link in the chain | What it is | Verdict |
|---|---|---|
| Ziggo modem → switch | DOCSIS 3.1, provisioned 829/64 | ⚠️ modem's LAN port speed **not yet verified** |
| Switch | TL-SG1024 (on order) | Gigabit once installed |
| Switch → AP | TP-Link **Archer AX50** | ✅ 1× GbE WAN + 4× GbE LAN |
| AP radio | AX3000 Wi-Fi 6, 2x2, 160 MHz capable | ✅ not the limit |
| AP → clients | 802.11**ac** clients on channel 48 | ⛔ **this is now the bottleneck** |

The AX50 was the main worry — plenty of TP-Link models pair AC Wi-Fi with 100 Mb ports
(Archer C20/C50/C60 all do), which would have left every wireless device capped at ~94
Mbit after the switch swap. The AX50 is not one of them. **Do not buy a new router.**

Channel 48 sits in the non-DFS 36–48 block, so the AP is running **80 MHz, not 160** — in
the EU a 160 MHz channel needs DFS. Assume 80 MHz for all planning below.

#### The two Wi-Fi clients

Read via `netsh wlan show interfaces`. Both are 802.11ac on 5 GHz, channel 48:

| Machine | Reported rate | Decodes to | Assessment |
|---|---|---|---|
| PC A | **433.3 Mbps** | 1x1 VHT80 **MCS9** (short GI) | **Maxed out.** Single-stream card — a hardware ceiling, not a signal problem |
| PC B | **650 Mbps** | 2x2 VHT80 **MCS7** (short GI) | Two-stream card, but **two steps below** its 866.7 ceiling |

PC A is at the top rate its radio can produce, so moving it will not help — only a new
adapter would. PC B has headroom that costs nothing: MCS7 → MCS9 is a signal/interference
issue, so better placement or line of sight to the AX50 should close it. The reported rate
is instantaneous and fluctuates — sample it several times over a minute before concluding.

Note both clients share airtime on the same 80 MHz channel, so simultaneous transfers
**split** the capacity rather than adding to it. Neither benefits from the AX50's Wi-Fi 6
features (OFDMA, improved MU-MIMO), which need `ax` clients.

#### What this means for a large one-time transfer (1 TB reference)

Real TCP throughput runs ~45–60% of the PHY rate quoted above:

| Path | Real throughput | 1 TB |
|---|---|---|
| Today, over the 100 Mb switch | ~11 MB/s | ~23 h |
| After swap — PC A (1x1 @ 433) | ~27 MB/s | ~10 h |
| After swap — PC B (2x2 @ 650) | ~40 MB/s | ~6–7 h |
| After swap — PC B if it reaches 866.7 | ~57 MB/s | ~4.5–5.5 h |
| **Wired gigabit** | ~112 MB/s | **~2.5 h** |

**Use a cable for anything of this size.** 2.5 h versus 6–10 h, and a single huge file over
Wi-Fi is the worst case for an interruption — SMB will not resume it, so a dropout at hour
five means starting over. If Wi-Fi is genuinely unavoidable: run it from **PC B**, and use
`robocopy /Z` for restartable mode.

Separately, PC A's 1x1 card caps that machine at ~250 Mbit on an 829 Mbit plan — about 30%,
permanently, on every download, not just NAS transfers. An Intel AX210 (2x2 Wi-Fi 6, M.2,
~€25–30) would take it to ~600–700 Mbit real and pairs well with the AX50. Cheap fix, but
unrelated to the backups — treat it as optional.

### Ruled out: cron overlap

Checked the fleet schedule, since overlapping jobs were a plausible alternative cause:

```
01:00  WBU   backup_immich.sh → /mnt/backup-c   (local disk, no network)
03:30  WBU   dump_immich_db_for_cwhu.sh         (local dump)
04:00  CWHU  restore_from_wbu.sh                (~2.25 GB pull — the only big one)
05:00  WBU   → Mac Mini db      (Fridays)
05:05  WBU   → Mac Mini images  (Fridays)
06:30  WBU   nightly summary
07:00  CWHU  nightly summary
```

Well spaced, no overlaps, and the single heavy job is ~3 minutes even at 100 Mb. WBU's
own volume is modest too: 27 GB across 3¾ days on `enp9s0`, ~7 GB/day. **Not the cause.**

### After the swap — verified 2026-08-03

**The 100 Mb ceiling is gone.** Measured on WBU the day the switch went in:

| Measurement | Before (DES-1024D) | After (TL-SG1024) |
|---|---|---|
| WBU `enp9s0` link | 100 Mb/s (10 Mb/s before 08-01) | **1000 Mb/s full duplex** |
| FleetNAS `eth0` link | 100 Mb/s | **1000 Mb/s** |
| LAN pull, WBU ← NAS (800 MB) | 6.77 MB/s | **111 MB/s (~890 Mbit)** |
| Internet, single stream | 83 Mbit | ~206 Mbit — see the caveat below |

The LAN number is the one that matters and it is essentially line rate: 111 MB/s against
a theoretical 125. **16× the contended 100 Mb figure.**

> **Methodology correction — the internet test above expects the wrong number.** The
> `ash-speed.hetzner.com` target is in **Ashburn, Virginia**. A single TCP stream from
> Amsterdam to US-East is bounded by round-trip latency and the congestion window, not by
> the local link, so it cannot reach 780–800 Mbit no matter how good the LAN is. The 206
> Mbit measured there proves the 100 Mb ceiling is gone; it is **not** a pass/fail read on
> the 829 Mbit provisioning, and the "anything under ~400 means something else is in the
> way" rule below it was wrong for this target.
>
> To actually test the plan, use a **Netherlands-local** server — `speedtest.net` /
> `fast.com` in a browser, or a multi-stream download from an NL mirror. Expect
> ~780–800 Mbit there. That test has not been run yet.

```bash
# Kept for reference — but read the correction above before trusting the number.
S=$(curl -o /dev/null --max-time 12 -s -w '%{speed_download}' \
      https://ash-speed.hetzner.com/100MB.bin)
echo "$S" | awk '{printf "%.1f MB/s = %.0f Mbit/s\n", $1/1000000, ($1*8)/1000000}'
```

If it still feels bad at gigabit, the next suspects — neither fixed by a switch:

1. **Bufferbloat.** Test at `waveform.com/tools/bufferbloat`, 30 seconds, free. Cable
   modems buffer upstream aggressively; a saturated upload collapses downloads too
   because ACKs get delayed. Classic "fast on paper, awful in practice". Needs SQM/QoS,
   not hardware.
2. **Upstream saturation from the 5 Wyze cameras.** *Demoted 2026-08-02* — upstream is
   provisioned at 64.2 Mbit, which five cameras are unlikely to saturate. Still possible
   if they are streaming at high bitrate continuously, but no longer a leading candidate.

Only if both come up clean does per-device traffic monitoring earn its keep — and the
Ziggo router's own per-device stats page is the cheap first stop, not a mirrored switch.
See `network-analyzer.md` (archived) for why the full-capture route wasn't worth it.

---

## 1. Network settings — ✅ done 2026-08-03

**WBU came up at gigabit on its own. Nothing in this section needed doing.** Confirmed by
`ethtool`, which shows real autonegotiation rather than a forced fallback:

```
Speed: 1000Mb/s   Duplex: Full   Auto-negotiation: on
Link partner advertised link modes: ... 1000baseT/Full
```

The feared outcome below — "If WBU comes back at 100, not 1000", where the run's other two
pairs turn out to be bad — **did not happen**. All four pairs on that cable are good.
FleetNAS `eth0` also reports `1000`.

The rest of this section is kept as the procedure that was followed, and as contingency
if a link ever regresses.

**Nothing to undo.** As of 2026-08-01 WBU was already
advertising all modes (10/100/1000) and autonegotiating 100 Mb/s correctly against the
old DES-1024D. There was no `ethtool` override in place, and none was needed. *(Earlier drafts
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

### Expected: `1000` — got `1000` ✅

Then confirm the rest of the fleet, since the old switch was capping **every** machine on
the LAN, not just WBU:

```bash
ssh fleetnas 'cat /sys/class/net/eth0/speed'                                   # ✅ 1000
ssh -i ~/.ssh/id_ed25519_macmini dennishmathes@mathes-mac-mini 'networksetup -getmedia Ethernet | grep -i active'
ssh amsterdamdesktop 'powershell -NoProfile -Command "Get-NetAdapter | Where-Object {$_.Status -eq \"Up\"} | Select-Object Name,LinkSpeed"'
```

| Box | Status |
|---|---|
| WBU `enp9s0` | ✅ **1000 Mb/s full duplex**, confirmed 2026-08-03 |
| FleetNAS `eth0` | ✅ **1000**, confirmed 2026-08-03 |
| Mac Mini | ⚠️ **Still unverified.** Was `100baseTX` on 2026-07-31, so it should have changed |
| AmsterdamDesktop | ⚠️ **Still unverified**, and it owns the largest pending transfer of all |

FleetNAS has **dual 10GbE**, so on a 1GbE switch it will report `1000` — that's the
switch's ceiling, not a fault. AmsterdamDesktop was never measured (SSH key auth from WBU
was refused), so it needs checking from the box itself.

### Also check the two infrastructure ports — added 2026-08-02

Neither of these is a fleet machine, and both sit upstream of everything else:

1. **The Ziggo modem's LAN port.** *Still not directly verified as of 2026-08-03,* but
   **partially answered by inference**: internet throughput moved from 83 Mbit to ~206
   Mbit after the swap, which is impossible through a 100 Mb uplink. So that port is not
   capped at 100. Whether it is actually gigabit — rather than merely above 100 — still
   needs the modem's status page or a Netherlands-local speed test.
2. **The Archer AX50's uplink.** Confirmed gigabit by spec (1× GbE WAN + 4× GbE LAN), so
   this is a formality — but worth eyeballing the switch's link LED for that port.

While at the AX50's web UI, confirm **Advanced → Operation Mode** reads *Access Point*, not
*Router*. The Ziggo box at `192.168.178.1` is doing the routing and NAT; if the AX50 is also
routing, that's a double-NAT with Wi-Fi clients on a separate subnet. The 1.2 TB Wi-Fi→NAS
transfer succeeded, which strongly implies AP mode already (same subnet), but it has not
been directly confirmed.

### What else gets faster — still worth verifying, not just assuming

The Immich→NAS backup is not the main beneficiary. Everything below shares the same wire.
**Only the WBU↔NAS path has actually been measured post-swap** — the rest remains
inference, and is listed here as work to confirm rather than as results.

- **✅ WBU ↔ FleetNAS.** Measured 2026-08-03: **111 MB/s** on an 800 MB pull, **107 MB/s**
  sustained across the 118 GB image load. Essentially line rate. This one is done.
- **CWHU's nightly warm-sync — not yet confirmed.** `restore_from_wbu.sh` rsyncs the latest
  dump, and since the dump gets a fresh datestamped filename daily, that is a **full 2.25GB
  transfer every night**, not an incremental one. Measured at 10 Mbit that step alone is
  ~32 minutes; at gigabit it should be under a minute. Its ceiling is chatworkhorse's
  physical NIC, since CWHU is a VM — so check that box's link speed too, not just the
  elapsed time.
- **Mac Mini Friday pushes — not yet confirmed** (`backup_immich_db_to_macmini.sh` 05:00,
  `backup_immich_images_to_macmini.sh` 05:05). The Mac Mini's own link speed is still
  unverified; it was `100baseTX` on 2026-07-31.
- **AmsterdamDesktop → NAS `photo_legacy`, ~975GB one-time.** Roughly 22 hours at 100
  Mbit versus ~2.5 at gigabit. This is the single biggest remaining win, and the switch is
  now in — but AmsterdamDesktop's link speed has not been checked, so confirm that first.
- **Mac Mini → NAS Plex library** — same story, also still pending. (Sync scripts for this
  landed separately in commit `d7ca1e1`.)
- **Internet for all 43 devices** — the big one, and not what this runbook was scoped for.
  Moved from 83 Mbit to ~206 Mbit single-stream, which proves the ceiling is gone but does
  not measure the 829 Mbit plan. Needs a Netherlands-local test — see the methodology
  correction in *After the swap* above.
- **Wi-Fi clients — partially, unmeasured.** The AX50's gigabit uplink stops being
  throttled, but the two measured clients are 802.11ac 1x1/2x2 and become the new ceiling
  (~27 and ~40 MB/s predicted). Better than the 11 MB/s they got before, still well short
  of wire. Details in *The Wi-Fi path, characterized 2026-08-02* above.

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

## 2. The one-time image load — ✅ done 2026-08-03

**Ran clean.** 118 GB / 283,460 files in **16m58s** (16:26:13 → 16:43:11 UTC) at a
sustained **~107 MB/s**, measured NAS-side mid-transfer. Destination verified byte-for-byte
against WBU: identical file count, no transfers pending, no deletions pending.

Estimate versus actual:

| Link | Estimate | Actual |
|---|---|---|
| **1 Gb/s** | ~20 minutes | ✅ **16m58s** |
| 100 Mb/s | ~2.5 hours | — |
| 100 Mb/s, contended with SMB pushes | ~4.7 hours | — |
| 10 Mb/s (WBU before 08-01) | ~27 hours | — |

That last row is why the switch was the blocker rather than an optimization: at 10 Mbit
this transfer does not fit in a nightly window at all — it would still be running when the
next night's job fired, and it would have to survive 27 uninterrupted hours on a box whose
I/O faults have corrupted a backup before.

The procedure below is kept for the record and for any future full reload.

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

### Found on the first real run: the verification could never pass — fixed 2026-08-03

The initial load transferred perfectly and the verification still reported **283,460 of
283,460 paths as drift.** Every entry carried the identical itemize flag:

```
.f...p.....|encoded-video/6f28ca07-.../52a1ee3a-....mp4
```

Decoded: leading `.` = **no transfer needed**, `f` = file, and `p` = the only differing
field, **permissions**. Not one `>f` (would transfer), not one `*deleting`. Confirmed
directly on both sides — source is 100% mode `644`, the NAS is 100% mode `777`, because
**the UGREEN share forces its own permission model on everything it stores.**

So `-a` (which implies `-p`) was asking rsync to preserve something the destination
overrides by design. The check was **structurally incapable of ever passing**, and left
alone it would have written a 283,460-line WARNING into `cron.log` every night about a
backup that was correct — which is exactly how a drift report that matters gets ignored.

**Fix:** `--no-perms` on *both* rsync calls in `backup_immich_images_to_fleetnas.sh` — the
sync and the verification. They must stay in sync; adding it to only one reintroduces the
problem. Re-verified after the change: **0 drift.** The same flag is in
`export_flat_to_fleetnas.sh` and `export_multi_to_fleetnas.sh` from birth for the same
reason.

`backup_immich_db_to_fleetnas.sh` is unaffected — it checks rsync's exit code and has no
dry-run verification pass.

> Ignore the `du -sb` totals when comparing the two sides: 118,306,295,066 on WBU versus
> 118,332,715,470 on the NAS, a 26 MB gap across 118 GB. That is block-allocation
> difference between ext4 and Btrfs, not content. rsync confirmed size and mtime match on
> every file, which is the meaningful check.

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

## 3. Crontab entries — ✅ added 2026-08-03

Live in **`dhm`'s** crontab, alongside the existing Friday Mac Mini entries. The previous
crontab was saved to `~/.cache/fleetnas-sync/crontab.bak.2026-08-03` before the edit:

```cron
# --- FleetNAS Immich backup — daily (added post-1GbE-switch) ---
0  5 * * * /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_db_to_fleetnas.sh >> /home/dhm/.cache/fleetnas-sync/cron.log 2>&1
20 5 * * * /home/dhm/repos/scripts/WorkBenchUnix/backup_immich_images_to_fleetnas.sh >> /home/dhm/.cache/fleetnas-sync/cron.log 2>&1
```

> **Friday 05:00 now has two DB pushes.** The new daily FleetNAS DB job lands on the same
> minute as the weekly `backup_immich_db_to_macmini.sh`. They read the same dump and write
> to different destinations, so it is correct either way, and at gigabit both finish in
> well under a minute. Noted rather than changed — see *Mac Mini Friday cron spacing* in
> section 5, which would move the Mac Mini pair to 05:00/05:20 anyway.

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

### export_flat / export_multi to FleetNAS — new 2026-08-03, bulk transfer still pending

Two new scripts, the FleetNAS counterparts to the existing Mac Mini pair:

```
WorkBenchUnix/export_flat_to_fleetnas.sh     → /volume1/immich/export_flat    (83 GB, 69,474 files)
WorkBenchUnix/export_multi_to_fleetnas.sh    → /volume1/immich/export_multi  (116 GB, 98,702 files)
```

**Status:** written, syntax-checked, destination directories created on the NAS, and the
share-name rsync destination **validated by dry run** — `export_flat` enumerated 69,474
would-transfer files with 0 errors, exactly matching the source count. The ~199 GB bulk
transfer has **not** been run. At the measured 107 MB/s expect roughly 13 and 18 minutes
respectively.

They are modelled on `backup_immich_images_to_fleetnas.sh`, **not** on their Mac Mini
namesakes. The Mac Mini scripts verify with a bulk scan plus a per-file `ssh test -e`
recheck; that loop exists solely to work around a reproducible FSKit/ExFAT bug on the Mac
Mini's Expansion drive where bulk enumeration silently omits files that are present (286
flagged, 0 genuinely missing, 2026-06-29). FleetNAS is Btrfs and has no such bug, so
carrying that workaround across would have cost an SSH round-trip per flagged file to
solve a problem this destination does not have. It also matched on *basename anywhere in
the tree*, so a file in the wrong directory counted as present.

Like the images script, both are **manual-only by design** — `export_flat` and
`export_multi` only change when `export_archive.py` is re-run by hand (~11 hours), so
there is nothing for a nightly job to pick up most nights. Cron placeholders are in the
script footers, commented out, matching the Mac Mini convention.

When they do run for the first time, remember section 4: `nightly_summary.sh` knows
nothing about them either.

### ~~Commit the scripts~~ — done

**Resolved.** As of 2026-08-02 all three are tracked in git:

```
WorkBenchUnix/backup_immich_db_to_fleetnas.sh
WorkBenchUnix/backup_immich_images_to_fleetnas.sh
WorkBenchUnix/post-1gig-switch.md
```

As of 2026-08-03 the two export scripts above are tracked as well.

Still worth remembering when syncing: `sync-this` stages with **`git add -A`**, which sweeps
everything untracked in the repo — check `git status` first, since this directory already
carries tracked `.bak.2026-07-*` files.

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
