# 01 — Hardware Assessment: TP-Link Archer C6 v3.20

Everything here was verified against the OpenWrt Table of Hardware and the kernel device tree
for this exact target. Nothing is taken from TP-Link marketing material, per your instruction.

---

## 1. Model identification

You reported `Ver: 3.20` on the label. TP-Link prints minor revisions as `3.20` where OpenWrt
and community documentation write `v3.2`.

**`v3.2` / `v3.20` is the same hardware as `v3` for OpenWrt purposes.** This is confirmed in the
[OpenWrt forum thread](https://forum.openwrt.org/t/is-archer-c6-v3-2-supported-by-openwrt/147209)
where the maintainer response is unambiguous ("v3.2 = v3"), and reported by a user who has flashed
20–30 of these units. The ToH data entry explicitly covers the US, BR, and EU regional variants
with identical specifications.

**Firmware image target: `tplink_archer-c6-v3`.**

> **One genuine caution.** There is a separate **Archer C6 v4** (and a region-specific
> `Archer C6(IN) v4`) that is **not** the same device and **must not** be flashed with the v3
> image. Before flashing, confirm the label reads `3.20` and not `4.x`. If it reads `4.x`, stop
> and tell me — the plan changes.

---

## 2. Confirmed specifications

| Parameter | Value |
|---|---|
| OpenWrt support status | Supported, since **22.03.0** |
| Latest supported release | 25.12.x |
| Target / subtarget | `ramips` / `mt7621` |
| Package architecture | `mipsel_24kc` |
| SoC | MediaTek **MT7621DAT** |
| CPU | Dual-core MIPS 1004Kc @ **880 MHz** (4 hardware threads) |
| RAM | **128 MB** DDR3 |
| Flash | **16 MB** SPI NOR, Winbond W25Q128 |
| Switch | **MT7530**, integrated into MT7621, driven by **DSA** |
| Ethernet | **5 × 1000Base-T** |
| WiFi 2.4 GHz | MediaTek MT7603EN, 2×2:2 MIMO |
| WiFi 5 GHz | MediaTek MT7613BEN, 2×2:2 MIMO |
| WiFi 6 GHz | **Not present** — this is an AC1200 device, no WiFi 6/6E |
| Bootloader | U-Boot |
| Serial console | 115200 8N1, **3.3 V** logic |

### Flash partition layout (from the device tree)

| Partition | Offset | Size |
|---|---|---|
| `u-boot` | `0x000000` | 256 KB |
| `firmware` | `0x040000` | ~15.6 MB |
| config area | `0xfa0000` | 320 KB |
| radio calibration (`radio`) | `0xff0000` | 64 KB |

MAC addresses live in the config partition at offset `0x8`; wireless interfaces get incremented
variants. This matters for the recovery procedure — **the config and radio partitions carry
per-unit calibration data and must never be erased.** A wiped `radio` partition means permanently
degraded or dead WiFi, and it is not recoverable from a generic image.

---

## 3. Port speed capability — the direct answer

**All five ports are gigabit-capable. There are no 10/100-only ports on this device.**

The ToH data entry lists `5 × 1000M` and explicitly records zero `100M` ports. This is
structurally guaranteed rather than merely documented: the MT7530 is a 5-port gigabit switch
integrated into the MT7621 SoC, so every user-facing port is one of the same five gigabit PHYs.
There is no separate slower PHY for the WAN port as there is on some cheaper designs.

### Physical-to-DSA port mapping

From the device tree in the
[support commit](https://git.openwrt.org/openwrt%2Fopenwrt/commit/?id=d22fb7f4fd833c420bc2ab34384862da0a6688b5):

| Switch port | DSA interface name | Physical label on case |
|---|---|---|
| `port@0` | `wan` | **WAN** (blue) |
| `port@1` | `lan1` | **LAN1** |
| `port@2` | `lan2` | **LAN2** |
| `port@3` | `lan3` | **LAN3** |
| `port@4` | `lan4` | **LAN4** |

Under DSA these are five independent netdevs. Any of them can be a WAN or a LAN member — the
"WAN" label on the case is cosmetic. Your requirement for freely assignable port roles is fully
achievable, and the admin UI reads and writes exactly this mapping.

Live negotiated speed is read from sysfs, which reflects actual autonegotiation rather than any
assumption:

```sh
cat /sys/class/net/wan/carrier      # 1 = link up
cat /sys/class/net/wan/speed        # 10 | 100 | 1000
cat /sys/class/net/wan/duplex       # half | full
```

The admin UI polls these paths directly. No `ethtool` dependency, no spec-sheet guessing.

---

## 4. Throughput: where the real bottleneck is

This is the section that conflicts with the goal as written, so it is worth being precise about
*which* traffic is affected.

### LAN ↔ LAN: true gigabit, not bottlenecked

Traffic between two devices on LAN ports is switched inside the MT7530 fabric. It never crosses
the CPU port and never touches the SoC. **This is line-rate gigabit and nothing in this project
changes that.** Your question about internal switch fabric bottlenecking LAN below 1000 Mbps:
the answer is no, LAN-to-LAN is fine.

### LAN ↔ WAN (routed + NAT): this is where you lose gigabit

Routed traffic must traverse the CPU. MT7621 has three performance tiers:

| Mode | Approx. NAT throughput | Compatible with mwan3? |
|---|---|---|
| Hardware flow offload | ~940 Mbps | **No** |
| Software flow offload | ~500–700 Mbps | Yes, with care |
| No offload (pure software routing) | ~200 Mbps single-flow, ~400 Mbps multi-flow | Yes |

**mwan3 is fundamentally incompatible with hardware flow offload.** Hardware offload installs
flows directly into the MT7530's hardware NAT table, which bypasses netfilter — and mwan3's whole
mechanism is netfilter packet marking plus policy routing tables. An offloaded flow never sees
the mark, so it is never steered. The observable symptoms are documented:

- [Intermittent HTTPS failures with mwan3 + hardware offload](https://forum.openwrt.org/t/mwan3-doesnt-work-with-hardware-offloading/241422),
  resolved by dropping to software-only offload.
- [Kernel oops when enabling `flow_offloading_hw` with mwan3](https://github.com/openwrt/packages/issues/5943).

**Shipped configuration:** software flow offload **on**, hardware flow offload **off**. This is
the fastest setting that is correct. Expect roughly **300–500 Mbps** of routed WAN1 throughput
depending on flow count and packet size.

### What this means for your stated goal

You said WAN1 is "full gigabit, lowest latency" and that LAN devices should "get the full benefit
of WAN1." Concretely:

- A **single** LAN device downloading from the internet over WAN1 will see roughly 200–400 Mbps,
  not 900+.
- **Several** LAN devices downloading simultaneously will collectively see roughly 400–500 Mbps.
- Latency is essentially unaffected — the CPU adds well under a millisecond. Your "lowest latency"
  characterisation of WAN1 is preserved.
- LAN-internal transfers remain full gigabit.

If saturating a gigabit WAN is a hard requirement, this router cannot do it while also doing
automatic multi-WAN failover. That is a property of the silicon, not of the configuration. Your
realistic paths forward:

1. **Accept ~400 Mbps** and keep automatic failover. (Shipped default.)
2. **Move routing to a faster device** (x86 mini-PC, or a Filogic MT7981/MT7986 router) and demote
   the C6 to an access point — the AP mode in this project supports exactly that.
3. **Drop mwan3**, enable hardware offload, and switch WANs manually. Full speed, no automation.

I have not silently picked one. Option 1 is shipped because it matches what you asked for; say the
word and I will restructure for 2 or 3.

---

## 5. Resource budget: RAM and flash

### Flash — the binding constraint

Firmware partition is **15.6 MB**. Approximate accounting:

| Component | Size | Notes |
|---|---|---|
| OpenWrt base sysupgrade image (kernel + squashfs rootfs) | ~8.0 MB | includes mt76 WiFi drivers |
| `mwan3` + dependencies (`ip-full`, `iptables`/`nft` bits) | ~0.5 MB | required |
| `wireguard-tools` + `kmod-wireguard` | ~0.2 MB | optional but requested |
| `curl` + `libcurl` | ~0.5 MB | needed for per-interface speed test |
| `ddns-scripts` | ~0.1 MB | optional |
| `sqm-scripts` (QoS) | ~0.1 MB | optional |
| **This admin app** | **~0.15 MB** | measured: 75 KB shell + 76 KB static assets |
| **Remaining free overlay** | **~4–6 MB** | |

That headroom is comfortable *because* the backend is shell rather than Python. For contrast:

| Rejected approach | Flash cost | Verdict |
|---|---|---|
| Python 3 minimal + `python3-uhttpd` | ~5–6 MB | Would leave near-zero headroom |
| Python 3 + Flask + deps | ~12 MB+ | **Does not fit at all** |
| Node.js | ~25 MB+ | **Does not fit at all** |
| Go static binary (stripped, UPX) | ~3–5 MB | Fits, but crowds out WireGuard/QoS |
| **POSIX shell CGI + vanilla JS SPA** | **~0.15 MB** | **Chosen** |

That last row is measured, not estimated: 75 KB of shell across five files, plus 76 KB of static
assets (20 KB gzipped over the wire). It is roughly **1% of the flash a Flask app would need**.

Additionally, NOR flash has limited write cycles. The port-detection service therefore writes live
results to **tmpfs** (`/tmp/mwadmin/`) and persists to flash only on a completed manual or plug-in
test — not on every poll.

### RAM — comfortable

128 MB is generous for this workload.

| Consumer | Typical RSS |
|---|---|
| Kernel + base OpenWrt | ~35 MB |
| `dnsmasq`, `netifd`, `rpcd`, `ubusd`, `hostapd` ×2 | ~12 MB |
| `mwan3` (tracker processes, 3 interfaces) | ~4 MB |
| `uhttpd` + transient CGI | ~3 MB |
| conntrack table (sized for a home LAN) | ~8 MB |
| **Headroom** | **~65 MB** |

**RAM is not a constraint here.** The one thing to watch is running a speed test while WireGuard
is saturated — both are CPU-bound and will contend, which is why speed tests are on-demand only.

---

## 6. Feature feasibility, honestly rated

| Requested feature | Feasible? | Realistic expectation |
|---|---|---|
| 3 WAN priority failover (mwan3) | **Yes** | 4–10 s failover, see doc 03 |
| Per-port role assignment | **Yes** | All 5 ports freely assignable |
| Live negotiated port speed | **Yes** | Read from sysfs, genuinely live |
| Gigabit LAN ↔ LAN | **Yes** | Line rate, switched in hardware |
| Gigabit LAN ↔ WAN1 | **No** | ~300–500 Mbps ceiling with mwan3 |
| Auto port detection on plug-in | **Yes** | Hotplug-driven, DHCP needs a lease first |
| On-router speed test | **Partial** | CPU-limited; cannot measure above ~300 Mbps |
| ISP/ASN detection | **Yes, best-effort** | rDNS + ASN lookup, can be wrong or absent |
| WiFi AP, guest network, WPA2/WPA3 | **Yes** | WPA3 supported via `hostapd-*-wolfssl`/`openssl` variant |
| WiFi 6 / 6 GHz | **No** | Hardware is AC1200; radio does not exist |
| Port forwarding, DMZ, UPnP | **Yes** | Standard `fw4` + `miniupnpd` |
| Static DNS override | **Yes** | Per-WAN `peerdns 0` + custom servers |
| DDNS | **Yes** | `ddns-scripts` |
| QoS / SQM | **Partial** | SQM at ~100–200 Mbps costs significant CPU; see below |
| WireGuard client/server | **Yes, slow** | **~82–99 Mbps ceiling**, CPU-bound |
| Config backup/restore | **Yes** | `sysupgrade -b` wrapped in the UI |
| Ping/traceroute, log viewer | **Yes** | Trivial |
| Live per-interface bandwidth graph | **Yes** | Read from `/proc/net/dev`, no extra daemon |
| Router ↔ AP mode switch | **Yes** | With rollback protection |
| Custom SPA admin UI | **Yes** | ~110 KB total |
| **Seamless/bonded failover (MPTCP/VPN bonding)** | **No** | See below |

### QoS caveat

SQM (`cake`/`fq_codel`) is CPU-intensive and is **not compatible with flow offload** — enabling
SQM disables offload for shaped traffic. On MT7621 you can expect SQM to hold up to roughly
**100–200 Mbps** before the CPU saturates. That is fine for shaping WAN2/WAN3 (both 100 Mb), and it
is the right place to use it. **Do not enable SQM on WAN1** — you would trade your remaining
throughput for latency control you mostly do not need on a low-latency gigabit line. The UI
reflects this: SQM defaults to off on WAN1 and warns if you enable it.

### WireGuard caveat

WireGuard on MT7621 benchmarks at **~82–99 Mbps** across multiple devices
([wg-bench](https://github.com/cyyself/wg-bench): GL-iNet MT1300 82.5 Mbps, Newifi D2 93 Mbps,
EdgeRouter-X 99 Mbps, all on OpenWrt 23.05). This is pure CPU cost — the MT7621 crypto engine
accelerates IPsec, not ChaCha20-Poly1305. WireGuard is exposed in the UI as you asked, but
routing all traffic through it caps you at roughly 90 Mbps.

### Seamless / bonded failover: not feasible — verdict and reasoning

You asked me to be honest and skip rather than half-implement. **Skipping.**

Every seamless approach requires terminating an encrypted multipath tunnel on the router:

- **MPTCP** — needs a kernel with MPTCP v1 enabled plus `mptcpize`, and only helps MPTCP-aware
  applications unless you add a proxy (`shadowsocks-rust`/`glorytun`), which adds CPU cost again.
- **Bonded VPN (glorytun-udp, OpenMPTCProuter)** — needs a VPS aggregation endpoint. OpenMPTCProuter
  explicitly does not target 16 MB flash devices; its image alone exceeds the partition.
- **SD-WAN overlays (ZeroTier, Netmaker, Nebula)** — all add per-packet crypto on the same CPU.

The arithmetic ends the discussion: the *best* crypto throughput this SoC achieves is ~99 Mbps.
Bonding WAN1 (gigabit) with WAN2 (100 Mb) through a tunnel would cap the aggregate at **under
100 Mbps** — you would be throwing away 80% of WAN1 to protect against an outage. Flash is also
insufficient for the OpenMPTCProuter userspace.

If seamless failover genuinely matters more than throughput, it needs different hardware
(x86 mini-PC or MT7986-class router with ≥256 MB flash) plus a VPS. That is a separate project and
I would be glad to scope it — but it is not this router.

---

## 7. Go / no-go

**Go.** The device is properly supported, all ports are gigabit, RAM is ample, and flash is
sufficient for the design chosen here.

Accept these before proceeding:

1. Routed WAN throughput will be ~300–500 Mbps, not ~940. **(Silicon limit + mwan3.)**
2. Three WANs leaves two wired LAN ports. **(Port count.)**
3. Failover is fast, not seamless — in-flight connections drop. **(Physics of NAT failover.)**
4. WireGuard tops out near 90 Mbps, and SQM near 150 Mbps. **(CPU limit.)**
5. Bonded/seamless failover is out of scope on this hardware. **(Flash + CPU.)**

If any of those is a dealbreaker, stop here and tell me — the right answer would be different
hardware, and I would rather say so now than after you have flashed.

Next: [`02-flashing-and-recovery.md`](02-flashing-and-recovery.md).
