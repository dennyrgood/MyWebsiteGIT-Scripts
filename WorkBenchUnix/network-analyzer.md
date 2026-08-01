# Network Analyzer on WorkBenchUnix

> ## 🗄️ ARCHIVED 2026-08-01 — not being built
>
> Design is complete and believed sound; **no hardware was bought and nothing was
> deployed.** Archived because the achievable result — metadata only, no payloads —
> doesn't justify the cost and effort versus what a late-90s sniffer on a hubbed,
> cleartext network delivered for free. **See §11 for why that gap is structural and
> permanent**, not a limitation of this particular design.
>
> Everything below is still accurate if it's ever revived. The pieces worth keeping
> regardless:
> - **§10's free `tcpdump` one-liner** works today on the existing switch, no purchase
>   needed — broadcast/multicast already reach WBU.
> - The **IPv6 dual-stack warning** (§10) applies to any future network work here.
> - The **device inventory** (appendix) and its regeneration script.
> - `post-1gig-switch.md` is unaffected: the gigabit swap proceeds as planned, and the
>   unmanaged TL-SG1024 already ordered is the right part for it.

**Written 2026-08-01.** Goal: see and analyse traffic from *every* device on the LAN —
Win11, macOS, Ubuntu, phones, IoT — from WBU, without installing anything on the
endpoints.

---

## TL;DR

| | |
|---|---|
| Do I need a new machine? | **No.** WBU is the analyser. 12 cores, 31 GB RAM, 252 GB free |
| Do I need new hardware? | **A small managed switch + a NIC.** ~€55 on top of the TL-SG1024 already ordered |
| The design | Mirroring happens on a **separate 8-port Easy Smart switch upstream** of the TL-SG1024 |
| Can I see Wi-Fi devices? | **Yes** — because the Wi-Fi controller hangs off the switch chain, not the router |
| Can I see inside HTTPS? | **No**, and nothing here changes that. You get hostnames/SNI, not content |

---

## 1. The design — mirror upstream, not on the main switch

The plan needs **port mirroring** (SPAN): a switch copies every frame crossing one port to
a second port, where WBU listens. Unmanaged switches cannot do this. There is no
firmware, no trick, no workaround — an unmanaged switch physically will not send you
another device's traffic.

TP-Link's naming makes this easy to trip over:

| Model | Managed? | Port mirroring |
|---|---|---|
| `TL-SG1024` / `1024D` / `1024S` | No — unmanaged | ❌ **None** |
| `TL-SG1024DE` | "Easy Smart" | ✅ Yes |
| `TL-SG105E` / `TL-SG108E` | "Easy Smart" | ✅ Yes |

**A `TL-SG1024` (unmanaged) is already on order — keep it.** Returning it isn't worth the
delay: it solves the 100 Mb ceiling that is currently blocking four large transfers
(the 975 GB AmsterdamDesktop→NAS load, the 111 GB Immich push, the nightly CWHU sync, the
Mac Mini Plex library). That fix has real value today.

Instead, **don't put the mirror on the main switch at all.** Add a small Easy Smart
switch *upstream* of it, between the Ziggo router and the TL-SG1024:

```
Ziggo router
     │
  TL-SG108E   ← 8-port Easy Smart, ~€30. The mirror happens here.
     ├── TL-SG1024 (unmanaged) → Wi-Fi controller + all other devices
     ├── WBU cap0   (mirror destination)
     ├── FleetNAS   (optional — buys intra-LAN visibility, see §5)
     └── 4 spare
```

Every packet between the LAN and the internet has to traverse the small switch, so one
mirrored port still sees every device — wired and wireless.

### Trade-off versus having bought the `DE`

*(Noted 2026-08-01: an earlier draft called this design "arguably better" than a managed
24-port. That overstated it. The `DE` is genuinely the better build — it can mirror any
port to any port, so intra-LAN traffic anywhere on the switch is capturable, which the
upstream tap cannot do. The tap is the pragmatic choice given the unmanaged unit was
already ordered, not the superior architecture.)*

What the tap does have going for it:

- **Dedicated mirroring fabric.** The mirror doesn't consume a port or contend on the
  24-port switch's backplane.
- **All 24 ports stay usable** for actual devices.
- **Portable.** If the topology changes, the tap moves with it.
- **Cost is a wash.** ~€30 versus the ~€25 the `DE` upgrade would have cost — with no
  return shipping and no waiting.

Against it: an extra hop, an extra PSU, and the intra-LAN blind spot covered in §5 and §9.
The size of that blind spot is **unknown** — it depends on traffic patterns that have
never been measured here.

**Get the 8-port `TL-SG108E`, not the 5-port `TL-SG105E`.** The 5-port fills up
immediately (Ziggo, big switch, `cap0`, FleetNAS = 4 of 5) and leaves nothing for adding
mirror sources later. The 8-port is only a few euro more.

### Why the current switch blocks this

The **D-Link DES-1024D is a 24-port 10/100 unmanaged switch.** Two independent problems:

1. **No mirroring** — no management interface at all. No web UI, no CLI.
2. **100 Mb ceiling** — this is what pins WBU, the Mac Mini, and FleetNAS's dual 10GbE.

Note that `post-1gig-switch.md` originally called this device a *hub*. It is not, and the
distinction is the whole project: a real hub floods every frame to every port, which is
exactly why hubs were the classic sniffing tool. If the DES-1024D were a hub, WBU could
already see everything with nothing but `tcpdump`. It is a switch, so it can't.

---

## 2. Topology — why this is the cheap case

**Today:**

```
Ziggo (WAN)
    │
    └── 192.168.178.1  Ziggo router/modem  (MAC 64:fa:2b:24:bd:b0)
            │
            └── DES-1024D 24-port 10/100 switch   ← being replaced
                    ├── Wi-Fi controller / APs        (bridged, NOT routed)
                    ├── WorkBenchUnix  .242
                    ├── FleetNAS       .123
                    ├── devolo powerline pair
                    └── ~40 other devices
```

**Target:**

```
Ziggo (WAN)
    │
    └── 192.168.178.1  Ziggo router/modem
            │
            └── TL-SG108E  (Easy Smart)          ← MIRROR SOURCE = this uplink port
                    ├── WBU cap0                 ← MIRROR DESTINATION
                    ├── FleetNAS  .123           (moved here for intra-LAN visibility)
                    └── TL-SG1024 (unmanaged, gigabit)
                            ├── Wi-Fi controller / APs
                            ├── WorkBenchUnix  .242  (enp9s0, normal traffic)
                            ├── devolo powerline pair
                            └── ~40 other devices
```

The important fact, confirmed by an ARP scan on 2026-08-01: **all 43 discovered devices
are on one flat `192.168.178.0/24`, including 5 with randomised MACs** — those are
phones/laptops using Wi-Fi privacy addressing, sitting on the *same L2 segment* as
everything wired.

That proves the **Wi-Fi controller is bridging, not routing**. A wireless device reaching
the internet goes `radio → AP → switch → Ziggo box`. **It crosses the switch.**

Consequence: mirroring the switch's Ziggo-uplink port captures every device's internet
traffic, wired and wireless alike. No OPNsense box, no inline appliance, no second
machine.

Had the APs hung off the *router* instead of the switch, wireless traffic would never
touch the switch and this would have been a €250+ project requiring WBU (or a new box) to
become the gateway. It doesn't. Bank the win.

---

## 3. Shopping list

| Item | Why | Approx |
|---|---|---|
| ~~TP-Link TL-SG1024~~ | **Already ordered.** Fixes the gigabit ceiling. Keep it | — |
| **TP-Link TL-SG108E** | 8-port gigabit Easy Smart — the mirroring tap | €30 |
| **Intel i210-T1 PCIe x1 NIC** | Dedicated capture interface | €25 |
| Cat5e/Cat6 patch × 2, ~1 m | Ziggo→SG108E→SG1024, and mirror→WBU | €6 |

Do **not** buy the `TL-SG1024DE` as well — the whole point of the upstream-tap design is
that the 24-port switch doesn't need to be managed.

### On the capture NIC

Use a **separate** NIC for capture. Do not mirror into `enp9s0` — that interface already
carries Immich, the FleetNAS backups, and Tailscale, and mixing a mirror feed into a
live production interface makes both the capture and the host's own networking worse.

Intel `igb`-driver cards (i210/i350) are the right choice over Realtek or USB: reliable
promiscuous mode, sane ring buffers, and offloads that turn off cleanly.

**Slot availability — confirmed 2026-08-01, physically and via `lspci`:**

| Slot | Occupant |
|---|---|
| CPU x16 (`00:01.1`) | RTX 3050 6GB (used by `immich_machine_learning` for CUDA) |
| Second full-length x16, chipset x4 | **ICY BOX card** = the ASMedia ASM1061 SATA controller at `03:06.0` |
| M.2 socket (`00:02.2`) | Lexar NVMe — **on-board M.2, not an adapter card** |
| **3 × PCIe x1** | **free** (`03:00.0`, `03:01.0`, `03:04.0` / `03:05.0` empty) |

**The i210-T1 is a PCIe x1 card, so it drops straight into one of the three free small
slots. Nothing needs to be moved or rearranged.**

Two side notes, neither blocking:

- The ICY BOX doesn't *need* the full-length slot — an ASM1061 is a PCIe 2.0 **x1** chip,
  so it would run identically in a small slot. No reason to move it, but if you ever want
  the long slot back, you can.
- `lsblk` currently shows **no SATA drives attached at all** — only the NVMe and the CIFS
  mount from `100.125.37.114`. So the ASM1061 appears to be doing nothing at the moment.
  Unrelated to this project, just worth knowing.

The one thing to check with the panel off: the RTX 3050 is a dual-slot card and routinely
covers the x1 directly beneath it. With three free you should have a clear one regardless.

**If every usable slot turns out to be blocked**, fall back to a USB 3 gigabit adapter.
WBU has 10 Gbps USB ports (`lsusb -t` shows three 10000M root hubs), and an RTL8153-based
adapter does promiscuous mode fine. It's a real step down for capture fidelity under
load, but it works and costs €15.

---

## 4. Physical install

Do this in two stages — get gigabit working and stable *first*, then add the tap. Don't
debug both at once.

**Stage A — replace the DES-1024D (do this when the TL-SG1024 arrives):**

1. Site the TL-SG1024, move every cable over from the DES-1024D, including the Ziggo
   uplink and the Wi-Fi controller.
2. Power up, verify gigabit across the fleet (below), let it settle for a day.
3. Retire the DES-1024D.

**Stage B — insert the tap (when the TL-SG108E and NIC arrive):**

4. Unplug the cable running **Ziggo → TL-SG1024**. Instead:
   - Ziggo router → **TL-SG108E port 1**
   - TL-SG108E **port 2** → TL-SG1024 (any port)
5. Patch WBU's new Intel NIC → **TL-SG108E port 3** (the mirror destination).
6. Optionally move **FleetNAS** off the TL-SG1024 onto **TL-SG108E port 4** — see §5.

Confirm the gigabit problem is actually solved before touching mirroring:

```bash
cat /sys/class/net/enp9s0/speed          # expect 1000
```

`/sys/.../speed` reads `-1` for a few seconds mid-renegotiation — re-read before
concluding anything. If it comes up 100, work through the diagnosis already written in
`post-1gig-switch.md` §1 ("If WBU comes back at 100, not 1000") — that section stands, and
its 2-pair-vs-4-pair cabling logic is exactly the right first check.

Then sweep the fleet, since the old switch was capping everything:

```bash
ssh fleetnas 'cat /sys/class/net/eth0/speed'
ssh -i ~/.ssh/id_ed25519_macmini dennishmathes@mathes-mac-mini \
    'networksetup -getmedia Ethernet | grep -i active'
```

---

## 5. Configure port mirroring

All of this happens on the **TL-SG108E**. The TL-SG1024 has no configuration and needs
none. Use the web UI rather than the "Easy Smart Configuration Utility".

The switch ships with a **static IP of `192.168.0.1`** which is *not* on your
`192.168.178.0/24`. To reach it the first time, either temporarily give a laptop an
address on `192.168.0.0/24`, or add a second address to WBU:

```bash
sudo ip addr add 192.168.0.50/24 dev enp9s0     # temporary
# browse to http://192.168.0.1   (default admin/admin)
sudo ip addr del 192.168.0.50/24 dev enp9s0     # after you've moved it
```

In the UI: set a static address on `192.168.178.0/24` outside the DHCP pool (e.g.
`192.168.178.2`), change the admin password, then find **Monitoring → Port Mirror**:

| Setting | Value |
|---|---|
| Mirror destination | **port 3** — WBU's Intel NIC |
| Mirror source | **port 1** — the Ziggo uplink |
| Direction | **Both** (ingress + egress) |

That single source gets you all LAN↔internet traffic, from every device on the LAN
including everything wireless.

### The intra-LAN gap, and how to close it

Traffic between two devices that both hang off the **TL-SG1024** never reaches the
TL-SG108E, so the mirror won't see it. Concretely: a Mac Mini → FleetNAS transfer would
be invisible if both sit on the big switch.

Fix: **move FleetNAS onto the TL-SG108E** (port 4) and add that port as a second mirror
source. A flow is visible if *either* end sits on the tap, not both — so putting the NAS
there captures every NAS transfer regardless of which machine is on the other end.

How much that recovers is **unmeasured**. The NAS is the endpoint for the known heavy
jobs (the 975 GB AmsterdamDesktop load, the nightly CWHU sync, the Immich pushes, the
Plex library), but the fleet also has non-NAS machine-to-machine paths — e.g. the 932 GB
`//100.125.37.114/Comfyui` mount and ComfyUI model sharing across IMAGEBEAST /
CHATWORKHORSE / TRAVELBEAST. Don't assume NAS-centricity without measuring it.

Anything you want fully visible goes on the TL-SG108E. You have 4 spare ports for that,
and relocating a device later costs a patch cable, not a re-purchase.

⚠️ **Oversubscription is real.** Mirroring multiple gigabit sources into one gigabit
destination drops frames whenever aggregate traffic exceeds 1 Gb/s — which your NAS syncs
absolutely will. Hardware limit, not a misconfiguration. Fine for analysis; just don't
trust byte totals during those windows. Start with port 1 alone and add sources once the
basics are proven.

---

## 6. Capture interface setup on WBU

The capture NIC should have **no IP address**, be **up**, be **promiscuous**, and have
**all offloads disabled**. Offloads matter: GRO/LRO coalesce packets before they reach
libpcap, so you'd capture 40 KB frankenpackets that never existed on the wire and your
analysis would be quietly wrong.

Find the new interface name after installing the card (`ip -br link`). Assume `cap0`
below — rename it for sanity with a udev rule keyed to its MAC:

```bash
# /etc/udev/rules.d/70-capture-nic.rules
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="AA:BB:CC:DD:EE:FF", NAME="cap0"
```

Ubuntu Desktop uses NetworkManager, so tell it to leave the interface alone:

```bash
# /etc/NetworkManager/conf.d/99-unmanage-cap0.conf
[keyfile]
unmanaged-devices=interface-name:cap0
```

Then a unit to bring it up in capture mode at boot:

```ini
# /etc/systemd/system/capture-nic.service
[Unit]
Description=Put cap0 into promiscuous capture mode
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link set cap0 up promisc on
ExecStart=/sbin/ethtool -K cap0 gro off lro off tso off gso off rx-vlan-offload off tx-vlan-offload off
ExecStart=/sbin/ethtool -G cap0 rx 4096
ExecStart=/sbin/sysctl -w net.core.rmem_max=134217728

[Install]
WantedBy=multi-user.target
```

`ethtool -G` and some `-K` flags fail on adapters that don't support them — harmless, but
if you're on a USB NIC expect warnings. Enable and verify:

```bash
sudo systemctl enable --now capture-nic.service
ip -br link show cap0          # expect UP and PROMISC
sudo ethtool -k cap0 | grep -E "generic-receive|large-receive"
```

### Verify the mirror actually works

The moment of truth — traffic between two *other* machines should be visible:

```bash
sudo tcpdump -i cap0 -nn -c 50 'not host 192.168.178.242'
```

If that fills with traffic between machines that aren't WBU, mirroring is live. If it's
silent, the mirror source/destination are probably swapped in the switch UI.

---

## 7. Software stack

Raw pcap is the wrong primary output. **Zeek** is the actual "network analyser": it turns
the wire into structured per-device logs at roughly 1–2 % of pcap volume, which is what
makes months of retention possible.

### Zeek

Not in the Ubuntu archive (`apt-cache policy zeek` → none). Use the upstream OBS repo —
verified reachable 2026-08-01:

```bash
. /etc/os-release
echo "deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_${VERSION_ID}/ /" \
  | sudo tee /etc/apt/sources.list.d/security:zeek.list
curl -fsSL "https://download.opensuse.org/repositories/security:zeek/xUbuntu_${VERSION_ID}/Release.key" \
  | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/security_zeek.gpg > /dev/null
sudo apt update && sudo apt install zeek
```

Zeek installs to `/opt/zeek`. Point it at the capture interface in
`/opt/zeek/etc/node.cfg`:

```ini
[zeek]
type=standalone
interface=af_packet::cap0
```

With 12 cores you can move to a clustered config with several `af_packet` workers later;
standalone is fine for a 1 Gb mirror and much simpler to reason about. Then:

```bash
sudo /opt/zeek/bin/zeekctl deploy
sudo /opt/zeek/bin/zeekctl status
```

Logs land in `/opt/zeek/logs/current/` — `conn.log`, `dns.log`, `ssl.log` (SNI!),
`http.log`, `files.log`, `notice.log`. These are the analysis surface.

### ntopng — the live UI

The archive version is old (`5.2.1`; upstream is 6.x). Use ntop's repo — also verified
2026-08-01:

```bash
curl -fsSLO https://packages.ntop.org/apt-stable/24.04/all/apt-ntop-stable.deb
sudo apt install ./apt-ntop-stable.deb
sudo apt update && sudo apt install ntopng
```

Set `-i cap0` in `/etc/ntopng/ntopng.conf`, then browse `http://workbenchunix:3000`.
Gives per-host live breakdown with nDPI application classification — the closest thing to
what most people picture when they say "network analyser".

### Optional

- **Suricata** (`apt install suricata`, 7.0.3 in the archive) — IDS alerting on top.
  Meaningful only if you'll actually read the alerts; it is noisy by default.
- **Full pcap** — only for targeted investigation, never continuously. Ring buffer:

```bash
sudo tcpdump -i cap0 -nn -s0 -W 24 -G 3600 \
  -w /mnt/immich-data/netcap/pcap/cap-%Y%m%d-%H%M.pcap -Z dhm
```

  `-W 24 -G 3600` keeps a rolling 24 hours in hourly files, overwriting the oldest.

---

## 8. Storage

**Do not write captures to `/`.** It has 39 GB free on a 96 GB partition and filling it
takes the machine down.

| Path | Free | Use |
|---|---|---|
| `/` (`nvme0n1p6`) | 39 G | ❌ never |
| `/mnt/immich-data` (`nvme0n1p4`) | 252 G | ✅ with retention + monitoring |

Use `/mnt/immich-data/netcap/`. The caveat is that this partition holds the Immich
library — **filling it breaks Immich**, which is a far worse outcome than losing capture
data. So retention is mandatory, not optional:

```bash
# /etc/cron.daily/netcap-retention
#!/bin/bash
find /mnt/immich-data/netcap/pcap -name '*.pcap' -mtime +2 -delete
find /opt/zeek/logs -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +
```

Rough sizing: Zeek logs run a few hundred MB/day at typical household volumes — years fit
comfortably. Full pcap at a 20 Mb/s average is ~15 GB/day, hence the 2-day cap above.

**Add a disk check to the existing nightly job.** `wbu-health-monitor.sh` already runs and
reports; extend it to alarm when `/mnt/immich-data` crosses ~85 %, so a runaway capture
surfaces in the nightly summary rather than as an Immich outage.

---

## 9. Known blind spots

Real limits of this design. None are fixable by spending more on the switch.

- **HTTPS payloads.** Encrypted. You get SNI, hostnames, JA3 fingerprints, volumes,
  timing, and who-talked-to-whom — not content. This is genuinely enough for nearly every
  question worth asking.
- **Device ↔ device where both sit on the TL-SG1024.** Never reaches the tap. This is the
  cost of the upstream-mirror design, and its size is unmeasured. Mitigate by moving
  anything you care about onto the TL-SG108E — FleetNAS first (§5).
- **Wi-Fi client ↔ Wi-Fi client on the same AP.** Bridged inside the AP; never reaches
  any switch. Often blocked by client isolation anyway.
- **The 3 GL.iNet devices** (`.36`, `.60`, `.75`). If any is routing rather than
  bridging, everything behind it is NAT'd and appears as one IP — per-device identity is
  lost for that segment. **Worth checking their mode before you rely on the data.**
- **The 2 devolo powerline adapters** (`.179`, `.235`). Traffic between two devices on
  the powerline segment can bridge across it without crossing the main switch.
- **Tailscale.** WireGuard-encrypted on the wire. Capture `-i tailscale0` on WBU to see
  the decrypted side, but only for WBU's own sessions. A meaningful share of intra-fleet
  traffic runs this way and is opaque regardless of hardware.
- **Randomised MACs.** The 5 Wi-Fi privacy clients change MAC periodically, so
  device identity over time needs DHCP-hostname or IP correlation, not MAC.
- **Mirror oversubscription** during large NAS transfers — see §5.

---

## 10. Protocol coverage — what you can and can't decode

Port mirroring operates at **layer 2**: the switch copies *frames*, not packets. So
protocol coverage is much broader than "IP traffic" — anything on the wire is copied,
including things that aren't IP at all.

### SMB

Fully visible and parsed by Zeek: `smb_mapping.log` (who mounted which share),
`smb_files.log` (file-level operations), plus `ntlm.log` / `kerberos.log` for auth.

- Modern SMB is direct-hosted on **TCP/445**. **TCP/139** is SMB-over-NetBIOS, still
  listening on most Windows boxes.
- ⚠️ **SMB3 encryption blinds it.** SMB 3.0+ can encrypt per share. The ComfyUI mount
  (`//100.125.37.114/Comfyui`) negotiates `vers=3.1.1` with no `seal` option, so it's
  unencrypted and parseable today. Turn encryption on anywhere and you get volumes and
  endpoints only.

### NetBIOS and what replaced it

NetBIOS still exists, largely vestigial, usually still chattering:

| | Port | Status |
|---|---|---|
| NBT Name Service | UDP/137 | Still default-enabled on most Windows |
| NBT Datagram | UDP/138 | Same |
| NBT Session | TCP/139 | Superseded by 445, often still listening |

Modern discovery protocols doing the same job:

- **mDNS** UDP/5353 — Bonjour; Apple, Chromecast, printers, Avahi
- **LLMNR** UDP/5355 — Microsoft's mDNS equivalent
- **WS-Discovery** UDP/3702 — how Win10/11 finds printers and shares
- **SSDP** UDP/1900 — UPnP / DLNA

**Security note:** NBT-NS and LLMNR are the classic NTLM credential-theft vectors (what
Responder abuses). If the analyzer shows them active, disabling them is usually free.

### Non-IP traffic

All captured, since this is L2:

- **ARP** (EtherType 0x0806) — not IP; excellent for device inventory
- **LLDP** (0x88CC), **EAPOL** (802.1X), **STP/BPDUs**, **802.1Q** VLAN tags
- **Wake-on-LAN** magic packets
- **HomePlug AV** (0x88E1) — the two **devolo** powerline adapters' management frames

Zeek is IP-focused (it handles ARP but isn't a general L2 decoder). For raw non-IP
frames use `tcpdump -e` or `tshark`.

### ⚠️ IPv6 — the easiest thing to get wrong

**This network is natively dual-stack.** Ziggo hands out real GUAs — WBU holds three
`2001:1c00:ba80:9700::/64` addresses and the neighbour table shows other devices with
them.

Modern OSes **prefer IPv6 when available**, so a large share of internet traffic is
likely v6, not v4. Filters and dashboards written only around `192.168.178.0/24` will
silently miss it. Zeek and ntopng handle v6 fine — it's the *queries* that need care.

Verified healthy 2026-08-01: `ping6` to `2606:4700:4700::1111` and `ipv6.google.com` both
0% loss at ~12 ms, and `curl -6` connects marginally faster than `curl -4`.

### Free today, no hardware required

Broadcast and multicast flood to every port by definition, so **the existing unmanaged
switch already delivers them to WBU**. The discovery-protocol landscape can be
characterised right now:

```bash
sudo tcpdump -i enp9s0 -nn -e \
  'arp or udp port 137 or udp port 138 or udp port 5353 \
   or udp port 5355 or udp port 3702 or udp port 1900 \
   or udp port 67 or icmp6'
```

`-e` prints MAC addresses and EtherTypes, so non-IP frames are visible too.

---

## 11. Why this is a shadow of a late-90s sniffer

Worth recording honestly, because it's the reason this project was archived.

A Sniffer Pro / EtherPeek / Observer setup in 1999 genuinely did show you everything, and
that was not nostalgia — it was a property of the era:

| Then | Now |
|---|---|
| **Hubs** flooded every frame to every port | **Switches** forward only where needed → mirroring or nothing |
| Telnet, FTP, POP3, HTTP, SMB all **cleartext** | **TLS everywhere**; payload is opaque |
| Services on the **LAN** | Services in the **cloud**; traffic leaves the premises |
| DNS in cleartext | **DoH/DoT** hides even the lookups |
| Stable MACs | **MAC randomisation** breaks device identity over time |
| — | **WireGuard/Tailscale** mesh encrypts machine-to-machine traffic on your own LAN |

So the instinct is correct: **observability genuinely regressed**, deliberately, and no
amount of money on switches recovers it. What a modern equivalent gives you is
*metadata* — who talked to whom, when, how much, to which hostname, with which TLS
fingerprint. Zeek and JA3 are far better at that than anything from 1999. But reading a
colleague's POP3 password off the wire is gone for good, and that was the thing that made
those tools feel omniscient.

If this is ever revived, calibrate expectations to metadata analysis, not packet
archaeology.

---

## Appendix — device inventory, 2026-08-01

43 devices discovered via ARP sweep of `192.168.178.0/24`.

| Count | Vendor | Notes |
|---|---|---|
| 5 | Wyze Labs | Cameras — likely a large share of upstream traffic |
| 5 | *randomised MAC* | Wi-Fi clients (phones/laptops) |
| 3 | Espressif | ESP32 IoT |
| 3 | GL Technologies | GL.iNet routers — see blind spots |
| 3 | Google | Nest / Chromecast |
| 2 | devolo AG | Powerline adapters — see blind spots |
| 2 | Apple | `.59`, `.197` |
| 1 each | Philips Lighting (Hue), Prusa Research, tado, Nintendo, Samsung, HP, Intel, TP-Link, EliteGroup, Oracle VirtualBox | |
| 10 | unidentified OUI | incl. `.1` Ziggo gateway, `.123` FleetNAS |

Regenerate with:

```bash
DB=/usr/share/nmap/nmap-mac-prefixes
ip neigh show dev enp9s0 | awk '/^192\.168\.178\./ && $2=="lladdr" {print $1, $3}' \
| sort -t. -k4 -n | while read ip mac; do
    p=$(echo "$mac" | tr -d ':' | tr 'a-z' 'A-Z' | cut -c1-6)
    o1=$((16#$(echo $mac | cut -d: -f1)))
    if [ $((o1 & 2)) -ne 0 ]; then v="<< RANDOMIZED MAC - wifi client >>"
    else v=$(grep -m1 -i "^$p " $DB | cut -d' ' -f2-); fi
    printf "%-16s %-18s %s\n" "$ip" "$mac" "${v:-unknown-oui}"
  done
```

Note the `$2=="lladdr"` guard: when `ip neigh` is filtered with `dev <iface>`, the
`dev <iface>` columns are omitted from the output, so the MAC is field 3, not field 5.

---

## Order of work

1. ☑ ~~TL-SG1024 ordered~~ — keep it, it's the gigabit fix
2. ☐ Order **TL-SG108E** (8-port Easy Smart) + **Intel i210-T1**
3. ☐ **Stage A:** swap DES-1024D → TL-SG1024; verify gigabit across the fleet (§4)
4. ☐ Let it settle a day, retire the DES-1024D
5. ☐ Pick one of the 3 free x1 slots — check the RTX 3050 cooler isn't covering it
6. ☐ **Stage B:** insert TL-SG108E between Ziggo and TL-SG1024; patch NIC to port 3 (§4)
7. ☐ Set up `cap0` — udev, NM unmanaged, systemd unit, offloads off (§6)
8. ☐ Mirror port 1 → port 3; verify with `tcpdump` (§5, §6)
9. ☐ Install Zeek; `zeekctl deploy` (§7)
10. ☐ Install ntopng (§7)
11. ☐ Retention cron + `wbu-health-monitor.sh` disk check (§8)
12. ☐ Check whether the GL.iNet devices bridge or route (§9)
13. ☐ Move FleetNAS to TL-SG108E port 4, add as second mirror source (§5)
