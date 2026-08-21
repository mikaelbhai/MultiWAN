# 05 — Hardware Assessment: Huawei OptiXstar K562e-10

**Requested:** port this project to the Huawei OptiXstar K562e-10.

**Verdict: NO-GO. Do not attempt this.** The device is not supported by OpenWrt, and — unlike
"not supported yet" cases — there is no realistic path to it becoming supported. Per your
standing instruction ("check the ToH first; if it's not supported, tell me and suggest close
alternatives instead of proceeding"), I stopped here and did not write a config, a port map, or
a flashing procedure for this device. Alternatives are in section 6.

**Asked again whether there is "some way":** section 3b works through all three doors (OpenWrt, stock firmware, root-then-install) and closes each with evidence. Section 3c covers the two things this device genuinely *can* do in the build — including a Wi-Fi-upstream trick that turns it into a usable failover uplink.

---

## 1. OpenWrt support status — the direct answer

**Not supported. No device page, no ToH entry, no image, no community port.**

| Check | Result |
|---|---|
| OpenWrt Table of Hardware entry | **None.** No `K562`, `K562e`, or `OptiXstar` entry exists |
| OpenWrt device page (`toh/huawei/*`) | **None.** The Huawei index lists AP5030DN, B593s-22, B593u-12, E970, EchoLife EG8141A5, EchoLife HG553, HG556a, other HG-series, and ws7200 — **no OptiXstar of any model** |
| Firmware Selector image | **None** |
| Community port / forum build thread | **None found** for K562e or K562e-10 |
| `toh/huawei/ws7200` (closest Huawei WiFi 6 device) | Empty "Under Construction" stub — no SoC data, no install procedure, **not evidence of support** |

The Huawei entries that *do* exist in the ToH are old Broadcom-based (HG553/HG556a) or
Qualcomm-based (AP5030DN) hardware. Every modern Huawei consumer/edge device — including this
one — sits on a silicon family OpenWrt has no target for.

---

## 2. What this device actually is

This matters, because the K562e-10 is not a router in the sense the rest of this project assumes.

| Parameter | Value | Source |
|---|---|---|
| Product class | **Edge ONT** (optical network terminal / ISP-supplied CPE), not a retail router | Huawei product page |
| Ethernet ports | **4 x GE (10/100/1000)** | Huawei / distributor spec |
| WAN | **One** of the four GE ports is usable as WAN | Huawei spec |
| WiFi | Wi-Fi 6 (802.11ax/ac/n/b/g), 2.4 + 5 GHz, AX3000 (574 + 2402 Mbps) | Huawei spec |
| Antennas | 2 x external, ~7 dBi | Distributor spec |
| USB / POTS | **None listed** | Distributor spec |
| Power | 12 V DC, 1 A, < 12 W | Huawei QSG |
| SoC | **Not publicly documented.** Huawei describes it only as a "high-performance dual-core chip". Huawei home-gateway silicon is HiSilicon (Gigahome family). | Huawei docs |
| RAM / flash | **Not publicly documented** | — |

Two things follow from that table on their own, before OpenWrt even enters the picture:

- **Huawei does not publish the SoC, RAM, or flash size.** You asked me not to assume specs from
  marketing material. For this device I *cannot* get real specs — there is no device tree, no
  GPL source drop, and no OpenWrt hwdata entry to check them against. Everything below the
  enclosure is undocumented.
- **4 ports total.** Even in a hypothetical world where it ran OpenWrt, 3 WAN + LAN would leave
  you **exactly one wired LAN port**. The Archer C6 build leaves two, and that was already
  flagged as tight.

---

## 3. Why this is a hard blocker, not a "someday"

Huawei home gateways run HiSilicon **Gigahome** SoCs. The porting obstacles are structural:

1. **Binary-only WiFi drivers.** In the OpenWrt developer thread for the Huawei AX3 Pro
   (same silicon family), the response from someone working on it is explicit: HiSilicon's
   driver is binary, and there is no source for the WiFi chips. A binary blob built against
   Huawei's own kernel cannot be loaded by an OpenWrt kernel. **Even a successful boot would
   leave you with no WiFi at all** — which kills the AP-mode half of this project outright.
2. **No public SDK, no upstream target.** There is no `hisilicon`/Gigahome target in OpenWrt
   for this SoC family. Adding one is not a config exercise; it is writing an Ethernet driver,
   a switch driver, and a clock/pinctrl tree from scratch with no datasheet.
3. **Locked/verified boot.** Huawei's "Hi-Boot" bootloader accepts only Huawei-signed images.
   Community discussion of the same family concludes the device can be run with "Huawei linux"
   only. There is no documented unlock for this model.
4. **ISP-managed CPE.** This is a carrier device. Units are frequently TR-069/OMCI-managed with
   the admin account restricted by the operator, and firmware is pushed remotely. Even the stock
   web UI may not expose enough for a multi-WAN setup — and any modification is likely to be
   reverted by the ISP or to void the service agreement if the unit is leased.

Any one of these stops the project. Together they close it.

> **If you flash a non-Huawei image to this device you will brick it,** and unlike the Archer C6
> there is no documented TFTP recovery, no serial pinout, and no stock image you can legally
> download (Huawei's firmware downloads sit behind an enterprise support account). There is no
> unbrick procedure I can give you for this model. Do not attempt it.

---

## 3b. "There must be some way" — the three doors, all tried

There are exactly three ways this device could carry the multi-WAN build. I tested each.

### Door 1 — Run OpenWrt on it. Closed.

Section 3. HiSilicon binary WiFi drivers, no upstream target, signed Hi-Boot. Unchanged.

### Door 2 — Do it in the stock firmware. Closed, and this is the decisive one.

If the stock firmware had multi-WAN, none of the OpenWrt problems would matter. It does not.
The full Layer 3 feature list from the OptiXstar K562 datasheet (the K562e-10's sibling):

| Stock firmware has | Stock firmware does **not** have |
|---|---|
| PPPoE / static IP / DHCP | **Multiple simultaneous WAN interfaces** |
| NAT / NAPT | **Failover or backup-link switching** |
| Port forwarding | **Load balancing** |
| ALG, UPnP | **Policy routing / packet marking** |
| DDNS, DNS server/client | **Health-check tracking of an uplink** |
| IPv6/IPv4 dual stack | **VPN of any kind (no WireGuard)** |
| Static / default routes | **QoS / traffic shaping** |
| SPI firewall, parental control | **Any scripting or package installation** |

`NNI: Wi-Fi or GE` — **one** uplink, singular. The device is architecturally single-WAN. There
is no hidden menu for this, because the feature does not exist in the firmware at all.

### Door 3 — Get root on the stock firmware and install mwan3 anyway. Closed.

This is the one people assume is the loophole. It isn't, and it's worth being precise about why:

- Stock Huawei firmware **is not OpenWrt**. There is no `opkg`/`apk`, no OpenWrt package feed,
  and no `uci`/`netifd`. `mwan3` is a set of OpenWrt shell scripts that drive `netifd`, `fw4`,
  and `ip rule` — none of which exist here.
- `mwan3` needs netfilter mark targets and multiple routing tables compiled into the kernel.
  Huawei's kernel is built for their own stack; you cannot load modules you don't have source
  or matching headers for.
- The rootfs is signed and effectively read-only, and the datasheet confirms **"dual-system
  software backup and rollback"** — the device is built to revert unexpected changes.

So even a root shell leaves you at the same wall. Credential unlocking (the `telecomadmin`-style
accounts discussed on enthusiast forums) gets you a fuller *stock* web UI — more VLAN and WAN-
profile detail — but it cannot add a feature the firmware does not implement. It is worth doing
only if you need the bridge/AP toggle in section 5 and the default account hides it.

### The genuinely annoying part

| | Archer C6 v3.20 | OptiXstar K562e-10 |
|---|---|---|
| Flash | 16 MB | **128 MB** |
| RAM | 128 MB | **512 MB** |
| WiFi | Wi-Fi 5 AC1200 | **Wi-Fi 6 AX3000** |
| Runs OpenWrt | **Yes** | No |

(K562 datasheet figures; the K562e-10 is the same family.) The Huawei is the better hardware by
every measure that matters — 8x the flash, 4x the RAM, a newer radio. It is locked, and the C6
is not. That is the whole story, and it is a licensing and driver problem, not a technical one
you can out-clever.

---

## 3c. What the K562e-10 *can* do in this build

Two real roles, both using stock firmware, no flashing, no unlocking:

1. **Wi-Fi 6 access point.** Bridging mode, plugged into a C6 LAN port, C6 radios off.
   Your wireless gets a genuine upgrade from AC1200 to AX3000. Details in section 5.

2. **Wi-Fi-to-Ethernet uplink converter — the useful trick.** The datasheet lists
   **"2 upstream modes: Ethernet upstream mode and Wi-Fi upstream mode"** with
   **routing mode over Wi-Fi upstream**. That means the K562e-10 can take its internet *over
   Wi-Fi* and hand it out as Ethernet.

   If any of your three connections is wireless — a mobile hotspot, a tethered phone, a
   point-to-point link, another building's Wi-Fi — put the Huawei in Wi-Fi-upstream routing
   mode and run one of its GE ports into the C6's WAN2 or WAN3 port. mwan3 then treats it as an
   ordinary DHCP uplink and fails over to it exactly like a wired ISP.

   Caveats: it double-NATs (fine for a failover link, awkward for inbound port forwarding), and
   the C6 sees the Huawei's LAN gateway rather than the real ISP, so per-WAN ISP auto-detection
   in the admin UI will report the Huawei, not the upstream provider.

---

## 4. What I did not build, and why

I did not produce the K562e-10 versions of: the flashing/recovery guide, the UCI network/mwan3/
firewall config, the DSA port map, the port-detection service bindings, or the admin-UI hardware
integration.

Producing them would have meant inventing a DSA port map and a flash layout for a device whose
switch topology and partition table are undocumented, and shipping a flashing procedure that
would brick your hardware. That is worse than delivering nothing. The rest of the project is
hardware-portable — see section 7 — but it has to land on hardware that actually runs OpenWrt.

---

## 5. If you keep the K562e-10

**Update: the fibre has been removed from this unit.** It is no longer terminating anything, so
the "leave it as your ONT" option is gone. What remains is a 4-port Wi-Fi 6 box running stock
Huawei firmware. Removing the optical link changes **nothing** about section 3 — the OpenWrt
blockers are the SoC, the signed bootloader, and the binary WiFi driver, none of which involve
the PON port.

The one role still worth using it for, **as-is, no flashing**:

- **Wireless AP on the OpenWrt router's LAN.** Its Wi-Fi 6 radios (AX3000, 574 + 2402 Mbps) are
  a real upgrade over the Archer C6's Wi-Fi 5 AC1200. Put the Huawei in bridge/AP mode in its
  stock UI, plug one of its GE ports into a C6 LAN port, disable WiFi on the C6, and let the
  Huawei serve wireless clients as plain LAN devices. DHCP stays on the OpenWrt router.

**Caveat before you count on that:** this is carrier CPE. If the unit was ISP-supplied, the
stock admin account is often restricted and may not expose an AP/bridge mode at all — the
operator may hold the only account that can. Check that you can actually reach a full admin
login and find a bridge/AP toggle before planning around it. If you can't, the device has no
remaining use in this build and the C6's own WiFi carries your wireless.

Either way, it is not the router. Nothing here requires flashing anything.

---

## 6. Alternatives that actually run this project

Ordered by how well they fit the goals you originally stated (3 WANs, gigabit WAN1, gigabit LAN,
WireGuard, and the seamless-bonding stretch goal).

| Option | OpenWrt status | Ports | RAM / flash | Fits the goals? |
|---|---|---|---|---|
| **You already own: TP-Link Archer C6 v3.20** | Supported since 22.03 | 5 x 1G | 128 MB / 16 MB | Works today. Routed WAN capped ~300–500 Mbps with mwan3; WireGuard ~90 Mbps; bonding not feasible. **This repo is built and ready for it.** |
| **GL.iNet GL-MT6000 (Flint 2)** ← *recommended upgrade* | Supported since 23.05.3, current in 25.12.x | **6 total: 4 x 1G + 2 x 2.5G**, zero 100M | **1 GB RAM / 8 GB eMMC** | Yes, comfortably. MT7986AV quad-core @ 2 GHz clears gigabit NAT with mwan3, WireGuard runs several times faster than MT7621, and 8 GB of storage removes the flash constraint entirely (a Python or Node backend would fit). 3 WAN + 3 LAN with room to spare. |
| **Banana Pi BPI-R4** | Supported (MT7988A / Filogic 880) | 4 x 1G + 2 x 10G SFP | 4 GB / 8 GB eMMC + SPI-NAND | Yes, with headroom for the bonded-failover stretch goal. Bare board — needs a case, PSU, and a separate WiFi card if you want radios. More project than appliance. |
| **x86 mini-PC (N100 + 4 x i226 2.5G NIC)** | Supported (`x86/64`) | 4 x 2.5G typical | 8–16 GB / SSD | Yes, and it is the only class here that makes **seamless/bonded failover (MPTCP, OpenMPTCProuter, glorytun)** genuinely practical — still needs a VPS endpoint. No WiFi; pair with an AP. |

**Not viable for this project regardless of OpenWrt support:** any 2-port router (Xiaomi AX3000T,
Cudy TR3000, and similar). Three WANs plus a LAN needs four ports minimum, five to be comfortable.

### The short recommendation

- **Cheapest path, zero new spend:** flash the Archer C6 v3.20 you already have, accept the
  ~300–500 Mbps routed ceiling, and use the K562e-10 as the upstream ONT and/or the Wi-Fi 6 AP.
  Everything in this repo runs as-is.
- **If the gigabit-on-WAN1 requirement is real:** the **GL-MT6000** is the smallest change that
  actually delivers it. Same MediaTek/DSA family as the C6, so the port-role code, mwan3 config,
  and admin UI here carry over with only the port map and package architecture changing.

---

## 7. What porting this project to a supported device costs

For the record, since the answer is "change the hardware": this repo is not deeply C6-specific.

| Component | Portable as-is? | Change needed |
|---|---|---|
| `config/30-mwan3.sh` (failover, health-check tuning) | **Yes** | None |
| `config/20-firewall.sh` | **Yes** | None |
| `config/50-system-dhcp.sh` | **Yes** | None |
| Admin UI (`package/www`, `cgi-bin`, `lib`) | **Yes** | None — reads sysfs/ubus/uci generically |
| Port detection + hotplug | **Yes** | None |
| `config/10-network.sh` | Mostly | New DSA port names / count |
| `config/40-wireless.sh` | Mostly | Radio names; WPA3 + 6 GHz options if the radios exist |
| `config/00-packages.sh` | Mostly | Package architecture; the flash budget check can be relaxed on 8 GB eMMC |
| `docs/02-flashing-and-recovery.md` | **No** | Fully model-specific — rewrite |
| `docs/01-hardware-assessment.md` | **No** | Rewrite for the new SoC |
| `docs/03-failover-expectations.md` | Partly | Timings hold; throughput / WireGuard / bonding verdicts change |

Roughly: the network and wireless port maps, the packages list, and three docs. The application
itself is hardware-agnostic by design.

---

## 8. Sources

- [OpenWrt ToH — Huawei device index](https://openwrt.org/toh/huawei/start) (no OptiXstar entry)
- [OpenWrt ToH — Huawei WS7200 page](https://openwrt.org/toh/huawei/ws7200) (empty stub, not evidence of support)
- [OpenWrt Forum — Support for Huawei AX3 Pro](https://forum.openwrt.org/t/support-for-huawei-ax3-pro/66551) (binary HiSilicon drivers, no WiFi source)
- [OpenWrt Forum — OpenWrt on Huawei WiFi AX3 / WS7200](https://forum.openwrt.org/t/openwrt-on-this-router-huawei-wifi-ax3-model-ws7200/83493) (Hi-Boot bootloader behaviour)
- [Huawei — OptiXstar K562e-10 product page](https://e.huawei.com/en/products/optical-terminal/optixstar-k562e-10)
- [Huawei — OptiXstar K562e-10 support / Quick Start](https://support.huawei.com/enterprise/en/optical-access/optixstar-k562e-10-pid-259196145)
- [Distributor spec — OptiXstar K562e-10 (4 x GE, Wi-Fi 6 AX3000)](https://www.ponplanet.eu/en/optixstar-k562e-10/)
- [OpenWrt ToH hwdata — GL.iNet GL-MT6000](https://openwrt.org/toh/hwdata/gl.inet/gl.inet_gl-mt6000)
- [OptiXstar K562 datasheet (PDF)](https://www.hi-network.com/action/download?file=huawei-optixstar-k562-brochure-datasheet) — full Layer 3 feature list, upstream modes, 128 MB flash / 512 MB RAM
- [Banana Pi BPI-R4 wiki](https://wiki.banana-pi.org/Banana_Pi_BPI-R4)
