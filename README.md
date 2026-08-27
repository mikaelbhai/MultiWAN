# MultiWAN — TP-Link Archer C6 v3.20 → OpenWrt Multi-WAN Gateway

Priority-based 3-WAN failover gateway with a custom admin UI, built for the
**TP-Link Archer C6 v3.20** (`Ver: 3.20` on the bottom label).

> **Read [`docs/01-hardware-assessment.md`](docs/01-hardware-assessment.md) before you flash anything.**
> Three findings materially change what you asked for. They are summarised below and
> detailed in that document.

---

## Update — the fibre line is gone

The original plan assumed **WAN1 = static IP, gigabit fibre, lowest latency**. That service has
been removed, so two things change.

### 1. WAN1 is no longer assumed to be static

`config/mwan.env` now exposes `WAN1_PROTO`, accepting `static`, `dhcp`, or `pppoe`
(the last using `WAN1_PPPOE_USER` / `WAN1_PPPOE_PASS`). Set it to whatever the replacement
line actually is — validation, the ppp package pull-in, and the install summary all follow it.
WAN2 and WAN3 are unchanged (DHCP).

```sh
WAN1_PROTO="dhcp"     # or "static" (fill IP/netmask/gateway) or "pppoe" (fill user/pass)
WAN1_DNS="1.1.1.1 8.8.8.8"
```

DNS stays pinned in `mwan.env` for all three protocols (`peerdns` is forced off on WAN1), so
name resolution does not change identity when mwan3 fails over.

### 2. Finding #2 below may no longer apply to you

The "mwan3 caps you at ~300–500 Mbps" problem only bites if WAN1 is *faster* than that. With
the gigabit line gone, measure the replacement and read across:

| Replacement WAN1 speed | Is the Archer C6 enough? |
|---|---|
| Up to ~300 Mbps | **Yes, comfortably.** mwan3 costs you nothing you would notice. Ignore finding #2 and the hardware-upgrade suggestion entirely. |
| ~300–500 Mbps | **Mostly.** The ceiling shows only under multi-stream load. Still workable. |
| Above ~500 Mbps | **No.** Finding #2 applies in full — see [`docs/01-hardware-assessment.md`](docs/01-hardware-assessment.md) §4. |

### What I still need from you

**The replacement line's speed, protocol, and whether it is your most stable link.**

The mwan3 health-check timings in `mwan.env` (`W1_INTERVAL=2`, `W1_DOWN=2`) were tuned on the
stated assumption that WAN1 is your *most reliable* connection, where a rare unnecessary switch
was cheaper than a slow real one. If the new WAN1 is flakier than WAN2/WAN3, those thresholds
are too aggressive and the priority order itself may want rethinking. Everything else in this
repo is unaffected and ready to run.

> The **Huawei OptiXstar K562e-10 cannot run OpenWrt** and is not a candidate for this build.
> Removing the fibre does not change that — the blockers are the HiSilicon SoC, the signed
> bootloader, and binary-only WiFi drivers. See
> [`docs/05-huawei-optixstar-k562e-10-assessment.md`](docs/05-huawei-optixstar-k562e-10-assessment.md).

---

## Hardware verdict: supported, with caveats

| Item | Finding | Source |
|---|---|---|
| OpenWrt support | **Supported** since 22.03.0, current through 25.12.x | [ToH hwdata](https://openwrt.org/toh/hwdata/tp-link/tp-link_archer_c6_v3) |
| `Ver: 3.20` vs `v3` | **Same device.** v3.2 / v3.20 is the v3 image target `tplink_archer-c6-v3` | [OpenWrt forum](https://forum.openwrt.org/t/is-archer-c6-v3-2-supported-by-openwrt/147209) |
| Target | `ramips` / `mt7621`, arch `mipsel_24kc` | ToH |
| SoC | MediaTek MT7621DAT, dual-core MIPS 1004Kc @ 880 MHz | ToH |
| RAM | **128 MB** DDR3 | ToH |
| Flash | **16 MB** SPI NOR (W25Q128) | [DTS commit](https://git.openwrt.org/openwrt%2Fopenwrt/commit/?id=d22fb7f4fd833c420bc2ab34384862da0a6688b5) |
| Switch | MT7530 integrated in MT7621, DSA driver | DTS commit |
| Ports | **All 5 ports are gigabit.** No 10/100-only ports. | ToH |

**Your gigabit requirement is satisfiable at the port level** — every physical port on this
device negotiates 1000Base-T. There is no "which port is gigabit" trap on this model.
The bottleneck is elsewhere. See below.

---

## The three findings that change your plan

### 1. Three WANs leaves you exactly two LAN ports

The device has 5 ports total. Assigning 3 to WAN leaves **2 physical LAN ports** (plus WiFi).
The UI implements fully dynamic per-port role assignment as you asked, so this is your choice
to make — but if you need more than 2 wired LAN clients, plan on a cheap unmanaged gigabit
switch downstream of a LAN port. That switch is line-rate and costs you nothing in throughput.

Default layout shipped in [`config/10-network.sh`](config/10-network.sh):

```
Physical label:   WAN      LAN1     LAN2     LAN3     LAN4
DSA name:         wan      lan1     lan2     lan3     lan4
Assigned role:    WAN1     WAN2     WAN3     LAN      LAN
                  static   dhcp     dhcp     └── br-lan ──┘
                  1 Gb     100 Mb   100 Mb
```

### 2. mwan3 forfeits hardware NAT offload — WAN1 will not route at full gigabit

This is the most important finding and it directly conflicts with your stated goal.

MT7621 reaches ~940 Mbps NAT **only** with hardware flow offload enabled. mwan3 works by
marking packets and steering them through custom routing tables; offloaded flows bypass that
logic entirely. Hardware offload + mwan3 is
[documented as broken](https://forum.openwrt.org/t/mwan3-doesnt-work-with-hardware-offloading/241422)
(intermittent HTTPS failures), and `flow_offloading_hw` has caused
[kernel oops with mwan3](https://github.com/openwrt/packages/issues/5943).

**With mwan3 active, expect roughly 300–500 Mbps of routed NAT throughput on WAN1**, not 1000.
Software flow offload (safe to leave on) recovers part of it; hardware offload must stay off.
Reference points on MT7621 without offload: ~200 Mbps single-flow, ~400 Mbps multi-flow
([forum](https://forum.openwrt.org/t/slow-pppoe-on-mt7621/154688)).

Your options, honestly:

| Option | WAN1 throughput | Failover |
|---|---|---|
| mwan3 as specified (**shipped default**) | ~300–500 Mbps | Automatic, 5–10 s |
| Hardware offload on, mwan3 off | ~940 Mbps | Manual only |
| Keep this box for failover, add a faster router | ~940 Mbps | Automatic |

LAN-to-LAN traffic is unaffected — that is switched in the MT7530 fabric at line rate and never
touches the CPU. **Local device to local device is a true gigabit.** The ceiling applies only to
traffic being *routed* between LAN and a WAN.

### 3. 16 MB flash rules out Python and Node for the admin UI backend

You suggested Python or Node. Neither fits. A minimal Python 3 install is ~5 MB before any
libraries; Node is far larger. After the OpenWrt base image, mwan3, WireGuard, and curl, you
have roughly **4–6 MB of writable overlay**.

The admin UI here is therefore built as:

- **Backend:** POSIX shell CGI over `ubus` / `uci` / `jshn` — all already in the base image.
  Measured: **75 KB**.
- **Frontend:** dependency-free vanilla JS/CSS SPA served by the in-base `uhttpd`.
  Measured: **76 KB** on disk, **20 KB** over the wire gzipped.
- **Auth:** delegated to OpenWrt's own `rpcd` session system, so your router root password is
  the admin password. No second credential store, no homegrown crypto.

This is not a downgrade. It is the only design that leaves headroom on this device, and it is
faster than a Python backend would be on an 880 MHz MIPS core.

---

## Repository layout

```
MultiWAN/
├── README.md                          ← you are here
├── docs/
│   ├── 01-hardware-assessment.md      Full ToH findings, resource budget, port map
│   ├── 02-flashing-and-recovery.md    Flash steps, stock backup, TFTP unbrick
│   ├── 03-failover-expectations.md    Honest timing, what breaks, bonding verdict
│   ├── 04-verification-checklist.md   Step-by-step acceptance tests
│   ├── 05-huawei-optixstar-k562e-10-assessment.md  NO-GO verdict + alternatives
│   └── 06-remote-access-relay.md      Internet admin access: setup, relay-host manual step
├── config/
│   ├── install.sh                     Runs everything in order
│   ├── 00-packages.sh                 opkg/apk install with flash budget check
│   ├── 10-network.sh                  3 WAN + LAN on DSA ports
│   ├── 20-firewall.sh                 Zones, forwarding, admin-UI LAN lock
│   ├── 30-mwan3.sh                    Priority failover + tuned health checks
│   ├── 40-wireless.sh                 2.4/5 GHz AP + guest network
│   └── 50-system-dhcp.sh              DHCP, DNS, NTP, hostname
├── package/                           The on-router admin application
│   ├── www/                           SPA (index.html, app.css, app.js)
│   ├── cgi-bin/mwadmin                API entry point
│   ├── lib/                           API handlers, port detect, mode switch, history offload
│   ├── hotplug/                       netifd/hotplug integration
│   ├── init.d/mwadmin                 Service + LAN-bound uhttpd instance
│   ├── init.d/mwremote                Outbound relay tunnel for internet admin access
│   └── etc/                           Default state files
└── deploy/
    ├── deploy.sh                      Push to router over SSH (from Linux/macOS)
    └── deploy.ps1                     Push to router over SSH (from Windows)
```

## Order of operations

1. **[`docs/02-flashing-and-recovery.md`](docs/02-flashing-and-recovery.md)** — back up stock
   firmware, flash OpenWrt, verify you can reach 192.168.1.1. Do not skip the backup.
2. **`config/install.sh`** — run on the router to lay down network, firewall, mwan3, WiFi.
3. **`deploy/deploy.ps1`** — push the admin app from this Windows machine.
4. **[`docs/04-verification-checklist.md`](docs/04-verification-checklist.md)** — prove each
   feature works, especially the failover and lockout-recovery tests.

## Failover summary

Full detail in [`docs/03-failover-expectations.md`](docs/03-failover-expectations.md).

- **Best case WAN1→WAN2:** ~4 seconds. **Worst case:** ~10 seconds.
- **This is fast failover, not seamless failover.** Every in-flight connection bound to the
  WAN1 source IP dies at the switch — SSH sessions, VoIP calls, active downloads, video calls.
  New connections use WAN2. Nothing changes that on this class of hardware.
- **Failback to WAN1:** ~6–14 seconds after WAN1 is genuinely healthy, deliberately slower than
  failover to prevent flapping.
- **Seamless/bonded stretch goal (MPTCP / bonded VPN):** **not feasible on this hardware.**
  WireGuard alone benchmarks at
  [~82–99 Mbps on MT7621](https://github.com/cyyself/wg-bench). A bonded tunnel would cap your
  gigabit WAN1 at under 100 Mbps and require a VPS endpoint. Reasoning in the doc; not
  implemented rather than half-implemented, as you asked.

## Security posture

- Admin UI binds to the **LAN IP only** (`192.168.20.1:8080`), never `0.0.0.0`.
- No WAN firewall rule is created for it. Direct WAN exposure is opt-in in the UI and shows an
  explicit warning before it will enable.
- A separate, also opt-in **Remote Access** page (`docs/06-remote-access-relay.md`) offers a
  second way to reach the admin UI from the internet: an *outbound* SSH tunnel to a relay host you
  control, so the router itself never accepts an inbound WAN connection at all. Requires a
  one-time manual step on the relay host (its own reverse proxy + TLS), documented in full there.
- Authentication uses `rpcd` sessions against the router root password, with a session timeout.
- The Router/AP mode switch **and any LAN IP/netmask change** use a **90-second confirmed-apply
  rollback** — if you lose access after either, the router reverts on its own. This is the
  single most important safety feature in the app.
- A fixed hostname (`ROUTER_HOSTNAME` in `mwan.env`, default `multiwan.router`) always resolves
  to the admin UI's address, the same trick as `tplinkwifi.net`. It's kept in sync automatically
  whenever the LAN IP changes — from the UI, LuCI, or a manual `uci set` — so bookmarking it means
  you never have to chase a changed IP again. It only resolves for LAN clients using this router
  as their DNS server (the default) and is not a real, publicly-registered domain.
- To make that hostname work with no `:8080` suffix, the admin UI gets a second, LAN-only address
  dedicated to port 80 (`ADMIN_ALIAS_HOST` in `mwan.env`, default `.254`), and LuCI's own plain-HTTP
  listener — normally wildcard-bound, which blocks anything else from using port 80 anywhere on the
  box — is narrowed to just its own LAN address to free that port up. LuCI keeps working exactly as
  before on the primary LAN IP; it just no longer also listens on every other address.

---

## Collaborators

- **Mikael** ([@mikaelbhai](https://github.com/mikaelbhai)) — owner, hardware, on-site testing,
  every real-world call (flashing, wiring, network topology, what to prioritize).
- **Claude** (Anthropic) — wrote essentially all of the code in `config/` and `package/`, the
  install scripts, the admin UI (both the Easy Setup and Advanced views), and this
  documentation, working interactively over the course of the build and live debugging session.

---

## Sources

- [OpenWrt ToH hwdata — TP-Link Archer C6 v3](https://openwrt.org/toh/hwdata/tp-link/tp-link_archer_c6_v3)
- [OpenWrt commit: ramips: add support for TP-Link Archer C6 v3](https://git.openwrt.org/openwrt%2Fopenwrt/commit/?id=d22fb7f4fd833c420bc2ab34384862da0a6688b5)
- [OpenWrt forum — Is Archer C6 v3.2 supported by OpenWrt?](https://forum.openwrt.org/t/is-archer-c6-v3-2-supported-by-openwrt/147209)
- [OpenWrt forum — mwan3 doesn't work with hardware offloading](https://forum.openwrt.org/t/mwan3-doesnt-work-with-hardware-offloading/241422)
- [openwrt/packages issue #5943 — mwan3: flow_offloading](https://github.com/openwrt/packages/issues/5943)
- [OpenWrt forum — Slow PPPoE on MT7621](https://forum.openwrt.org/t/slow-pppoe-on-mt7621/154688)
- [cyyself/wg-bench — WireGuard benchmarks incl. MT7621](https://github.com/cyyself/wg-bench)
- [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/?target=ramips%2Fmt7621&id=tplink_archer-c6-v3)
