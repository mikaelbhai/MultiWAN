# 08 — Two-router system: Main (A) + Second (B)

Status: PLAN for the developer. Nothing in this document is built or tested on hardware.
Facts marked **[measured]** were read from the live main router on 2026-11-24 (idle).
Facts marked **[verify]** are assumptions the developer must confirm in code before relying on them.

---

## 1. What the owner asked for

1. **Two separate networks, one internet.** Router A (main) does multi-WAN. Router B (second) only
   routes. Different Wi-Fi names, different LAN subnets, different DHCP servers. Devices do **not**
   roam between them (explicitly out of scope).
2. **Device cap on each router, like a phone hotspot:** N "open" devices (Wi-Fi or cable, any
   mix, all allowed to talk to each other) **plus** 5 "whitelisted" devices that never count
   against N and are never refused.
3. **Spread the load over both routers' RAM.** A runs the heavy services; B runs almost
   nothing else, so it starts at 70 open and grows with every access point added (+25 each).
   A stays at 20 open.
4. **Only the settings are shared** (blocked sites, break times, allowances, exceptions, device
   names, whitelist). Not shared: Wi-Fi name/password, DHCP/LAN, device caps, ports, WAN setup.
5. **B has the same web panel, cut down:** its own settings, devices, port close/reopen — no
   multi-WAN pages.
6. **Both appear on the website as one location with two nodes**, like the existing router.
7. B reaches A **by cable or over the internet.**

## 2. Device limits (owner's decision, 2026-11-24: A = 20 + 5; B = 70 + 5, plus 25 per access point)

| | Open devices | Whitelisted | Why |
|---|---|---|---|
| **A, main (EA8100)** | **20** (hard limit) | **5** | Owner's decision. A runs mwan3 (no hardware offload), 4 dnsmasq processes, nlbwmon, a per-minute activity pass, so its real constraint is CPU, not RAM or Wi-Fi (see below). The memory guard protects it. No access-point bonus. |
| **B, second (EA8100, confirmed by owner)** | **70** (hard limit), **+25 for every access point added in B's local panel** | **5** | Same chip and 256 MB RAM as A, but none of A's services. 70 open + 5 whitelisted = 75 on B's own radios, under the chip's 111-slot Wi-Fi table. Each access point adds 25 (setting, editable per AP). Example: 3 access points = 70 + 75 = 145 open + 5 whitelisted. |

(If B were ever the old Archer C6 v3 — 128 MB RAM, 2x2 Wi-Fi — use 15 + 5 instead.)

Both numbers are **settings, not constants** (range 1–200 open, 0–10 whitelisted; defaults above).

**The owner's intent for B: no artificial low cap; stop only just short of where it would
break.** Two protections make that safe (details in §4.3):
1. **Antenna ceiling.** Both of B's radios are MediaTek MT7615 **[measured on A, same model]**.
   The driver's station table (`mt7615.h`: `MT7615_WTBL_SIZE` 128, minus 1 reserved, minus
   `MT7615_MAX_INTERFACES` 16) leaves **111 client slots**; the code appears to use one
   device-wide table for both bands, but that is an inference, not stated in the source. (A
   forum list quotes 123 for this chip; it says itself it is "inferred" and may have errors, so
   the driver source is used here. The router does not expose the number at runtime.) The default of 70 open + 5
   whitelisted keeps Wi-Fi clients on B's own radios under it (and `radio_max` 100 + 5 keeps them
   under it even when access points raise the total). Cable devices and devices on
   access points are not in that table.
2. **Memory/connection guard.** When free memory or connection tracking gets close to the edge,
   B stops admitting **new** devices and shows "full" instead of letting the router run out and
   drop everyone. Existing devices are never kicked by the guard.

**Access points added on B's dashboard** (they are `node` entries of kind `ap`, §4.4) raise the
open limit by `ap_bonus` each (**owner's setting: 25**; editable per access point, 10–60).
The limit is **hard**: the cap is never exceeded (whitelisted devices aside), and the guard may
refuse new devices earlier, never later. Effective open limit =
`open_max + ap_bonus × (number of AP nodes)`. The ≤100 limit on B's **own radios** does not
grow, since those clients still live in B's station table. This only applies to **bridged
access points** (plain AP mode, wired to B), whose devices show up on B as individual MACs. An AP
left in router mode is one device and gives no bonus.

**Google Wifi units as access points (owner's plan).** Each unit is set up **on its own, not
as a mesh**, in Google's bridge mode, with a **wired** cable to a LAN port of B (or to a
switch). Google documents bridge mode as working with a single Wifi unit per network, so each
unit is its own network with its own name and password; there is no roaming between them
(already out of scope). Because each unit hands out no addresses of its own, every phone
behind it gets an address from B and shows up on B as an individual device, so counting,
blocking, break times and activity all work for it. Register each unit as an `ap` node
(its own MAC never uses a slot). Bonus per unit: **25** (owner's decision; Google's
spec says up to 100 devices per point, but only at 1 Mbps each, so treat it as a ceiling, not a
planning number). B has 4 LAN sockets (the 5th is the internet port), so more than 4 units, or
units plus wired devices, need a plain switch. The existing Google Wifi on A stays as it is.
Sources: [Google bridge mode](https://support.google.com/googlenest/answer/6240987),
[Google tech specs](https://support.google.com/googlehome/answer/6280668).

**RAM freed on B by not running multi-WAN [measured on A, idle, 2026-11-24].** The services B
drops (mwan3 route monitors and trackers, ksmbd, nlbwmon, the line-speed tracker and helper
shells) add up to roughly **10–20 MB** of process memory on A (the whole userspace on A is ~61 MB
by RSS, which over-counts shared libraries). So B has somewhat more room than A, **not twice as
much**; the base picture is the same 248 MB router with ~139 MB available (mostly reclaimable
cache). B's bigger advantage is **CPU**: no mwan3 packet marking and health pings, no per-minute
line jobs. That, plus the guard (rule 7), is what lets B run a much bigger pool.

**Why A is at 20+5.** A has the same two MT7615 radios as B, so Wi-Fi capacity is not the
reason for A's low number, and RAM is not either (139 MB available at 818 tracked connections).
A's real constraint is **CPU time**: mwan3 forces software routing (~300–500 Mbps total), plus
four dnsmasq processes, the activity pass and health checks. 20+5 keeps A responsive and leaves
most clients to B. It can be raised later in the panel (the guard protects it the same way).
Everything B routes also exits through A, so A's routing speed is shared by both.

**What it takes for B to hold 100+ devices** (estimates, to be confirmed by the §10 load test):
- RAM: no problem on its own. Per-device cost is tens of KB plus connection-tracking entries;
  100 devices at ~300 flows each is ~30,000 entries; 150 devices at 500 flows is 75,000. B has
  no mwan3, so set `nf_conntrack_max` to 131,072 (roughly 40 MB worst case; estimate). A is left
  alone at 31,744.
- The real ceiling is **Wi-Fi airtime and CPU on traffic, not RAM.** More devices does not mean
  more speed: they share the same radios and the same internet line. The EA8100's 5 GHz radio is
  4x4 and copes well; the 2.4 GHz radio is the weak one. Steer capable devices to 5 GHz (band
  steering / a separate 5 GHz SSID is a developer option, not required).
- **[verify on the device]** that the 2.4 GHz and 5 GHz radios really share the 111-slot table
  (associate test clients on both bands until one is refused). Both radios report "up to 16
  interfaces" only; that is not the client limit. Note: a kernel kept on **firmware offload**
  can have a much smaller table on the related MT7663 (32), which does not apply to the
  EA8100's MT7615, but check `dmesg` for the firmware name on B.
- Sources: [mt7615.h defines](https://raw.githubusercontent.com/openwrt/mt76/master/mt7615/mt7615.h),
  [OpenWrt forum station list](https://forum.openwrt.org/t/reference-for-number-of-supported-stations-in-different-wifi-hardware/156535),
  [conntrack entry size discussion](https://forum.openwrt.org/t/max-conntrack-connection/248914).
  Forum estimates put a conntrack entry at roughly 230–350 bytes, so 131,072 entries is about 30–46 MB worst case.
- DHCP pool on B must be larger than the effective cap + leftover leases. With 70 + 5 + 25 per AP,
  `.2`–`.250` is enough up to about 6 access points; use `.2`–`.250` and keep
  lease time at 12 h (or 2 h on B) so stale leases don't exhaust the pool.
- hostapd per-interface association limit must not be set below the cap (it is unset today).

Honest context for the owner: A's RAM is **not** the binding limit today. **[measured, idle,
~0 Wi-Fi clients]**: 248 MB total, ~138 MB available, load 0.4, conntrack 932 of 31,744, /tmp
3 MB of 121 MB used, overlay 4.3 MB of 23 MB. A at 20+5 is the owner's decision (RAM
would allow more); CPU, not RAM, is what limits A. The developer
must **load-test** (see §10) before the numbers are called final. The real per-device costs are
conntrack entries (flows), the per-minute `insight.sh` pass over the connection table, and the
DNS log; the activity spool is already capped at ~2–3 MB (`events.sh`, `insight.sh`).

What the cap does **not** do, and the owner has accepted: devices behind the Google Wifi count as
one device on A and cannot be limited (register it as a node, §4.4).

One thing that does matter: **phones with "private/random Wi-Fi address"** look like a new
device each time the address rotates, so they burn open slots and a whitelisted phone stops being
recognised. Whitelisted phones must be set to "use device MAC" for this SSID. The panel must say
so next to the whitelist.

## 3. Architecture

```
                       ┌─────────────────────────── website (mikaelbhai.com/router) ──────────────────┐
                       │  location "Home"  ─┬─ node A (main)     ─ tunnel 22081-22084                 │
                       │                    └─ node B (second)   ─ tunnel 22085-22088                 │
                       │  policy table (A is master) · activity DB (per router_id) · relay.php        │
                       └────────▲──────────────────────▲──────────────────────────────▲──────────────┘
                                │ policy PUT + uploads │ policy GET (poll 60 s)       │ uploads
        ISP lines ─► ┌──────────┴──────────┐   cable  ┌┴─────────────────────────────┴┐
        (WAN1/WAN2)  │ A  main, multi-WAN   │◄────────┤ B  second, single WAN, NAT     │
                     │ LAN 192.168.1.0/24   │ B.WAN←A.LAN or B.WAN←its own ISP       │
                     │ cap 20+5             │         │ LAN 192.168.2.0/24, cap 70+5   │
                     └──────────────────────┘         └────────────────────────────────┘
```

**Data path (decision):** B is a normal NAT router. In wired mode its WAN port plugs into an A
LAN port and gets an address by DHCP (reserve it outside A's pool, e.g. `192.168.1.210`, as a
static host entry like the Google Wifi one). A sees B as one device. Rejected alternative:
routing B's subnet without NAT — A's blocking, sign-in and exceptions are keyed by MAC
(`block.sh`, `guest.sh`, `allow.sh`), and B's clients all arrive with B's MAC, so it would not
work and would couple the two routers tightly.

**Addressing rule (owner's decision): the two routers must have different LAN and DHCP
addresses.**

| | Router address (and DHCP server) | Subnet | DHCP pool | Panel aliases |
|---|---|---|---|---|
| **A, main** | `192.168.1.1` | `192.168.1.0/24` | `.2`–`.201` (as today) | admin `192.168.1.254`, block page `192.168.1.253` |
| **B, second** | `192.168.2.1` | `192.168.2.0/24` | `.2`–`.250` | admin `192.168.2.254`, block page `192.168.2.253` |

- Each router runs **only its own DHCP server**, on its own subnet. B's DHCP must never answer
  on A's LAN and vice versa; in wired mode B's DHCP is off on its WAN port (it is only a client
  there).
- A validates that its LAN subnet is not equal to B's and B validates the reverse; the panel
  refuses a LAN change that would make them equal, and refuses one that equals either router's
  WAN-side subnet (see the collision check in §4.2).
- Wired mode: B's WAN port receives an address from A's `192.168.1.0/24` (reservation
  `192.168.1.210`), B's own clients live on `192.168.2.0/24`, so the two never overlap.
- **A is live today at `192.168.67.1`.** Moving it to `192.168.1.1` is a one-time change done
  with the panel's existing LAN change (it renumbers the DHCP and firewall addresses, moves the
  admin and block-page aliases to `.254` / `.253`, cycles the LAN ports so wired devices
  re-request an address, and has the 90 s rollback). Devices with hand-set addresses in
  `192.168.67.x` (for example the Google Wifi's reservation `.167`) must be moved to the new
  subnet. The website tunnel re-reads the LAN address on each reconnect (`tunnel.sh`), so it
  follows the change. **[verify]** the Windows dev PC and any saved bookmarks.
- **Risk to check before changing A:** `192.168.1.x` is the factory range of many ISP modems. If
  either of A's WAN uplinks (the second line, DHCP) is handed an address in `192.168.1.0/24`,
  routing breaks (the same warning as in the README). Check each line's modem subnet first; if
  one uses `192.168.1.x`, that modem's LAN must be moved, or the owner must pick another range
  for A.

**Consequence:** because A cannot see B's clients, **B must enforce and report for itself.**
That is why B runs the same software bundle, not a thin repeater. (The existing
`repeater/setup-repeater.sh` is a different thing — a bridged WDS repeater, one network —
and stays as is.)

**Over the internet mode:** B has its own ISP line (reuse the `WAN1_PROTO` dhcp/static/pppoe logic
in `config/10-network.sh`), same software, same website link. The only thing "shared" is
settings, which already travels through the website. If the owner later wants B's traffic to
**exit through A's IP**, that needs a WireGuard tunnel: the repo's own benchmark puts MT7621 at
~82–99 Mbps and it needs a reachable endpoint on A. **Not planned; do not start without a
decision.**

## 4. Router-side work

### 4.1 One bundle, two roles
`uci mwadmin.node.role = main | branch` (set by `apply.sh`, default `main`). Same
`fw/baytaar-fw.tar.gz` for both (`build_fw.py` already lists the files).

| Piece | main | branch |
|---|---|---|
| mwan3, `mwsite` peak tracker, `portdetect`, line names/slots, `lines.sh` | on | **off** (don't install mwan3 on B) |
| USB drives (`drive.sh`, ksmbd) | on | off |
| `block.sh`, `pause.sh`, `allow.sh`, `guest.sh`, `insight.sh`, `events.sh`, tunnel, relay | on | **on** |
| device cap (new) | on | on |
| panel pages | all | hide Lines, Drives, mwan3, Remote-line pages |

`site.sh watch` currently mixes the line-peak tracker with the once-a-minute jobs
(`insight sample`, `guest tick`, `block tick`). Split it so B runs only the minute jobs
(plus the ports-off enforcement loop). **[verify]** `mwsite` init script and how `api.sh` gates
mwan3-only routes.

B's panel must show the same pages (Home, Devices, Block/Break, Ports, Wi-Fi, Backup/Restore,
Software update) — port close/reopen is the existing `ports_off` mechanism.

### 4.2 B's local network defaults (written by a new `config/60-branch.sh`)
- LAN `192.168.2.1/24`, DHCP pool `.2`–`.250`, lease 12 h (see the addressing rule in §3).
  **Auto-check:** if the WAN-side subnet equals the LAN subnet (for example B on its own ISP line
  whose modem uses `192.168.2.x`), pick the next free `192.168.x.0/24`, never `192.168.1.0/24`
  (A's); use the existing 90 s confirmed-apply rollback for any LAN change.
- Its own SSID and password (not copied from A), hostname `Baytaar-2`, admin hostname
  `baytaar2.router` (A already owns `baytaar.router`).
- `nf_conntrack_max` 131072 (sysctl) so 70 + 5 + 25 per access point never hit the table limit.
- Firewall: standard wan zone with masquerade. Admin panel on the LAN **and, wired mode only,
  from the upstream subnet** so it can be opened from A's Wi-Fi. Never open it to an ISP-facing
  WAN; remote access is through the website tunnel only.
- B's DNS upstream: pinned public resolvers, same as A (`WAN1_DNS`). Do not point B at A's DNS.

### 4.3 The device cap — new `lib/devcap.sh` (follow the shape of `guest.sh`)
**Rules**
1. A device is **present** while it is associated on Wi-Fi (`ubus call hostapd.phyX-apY
   get_clients`, both radios — **[measured]** the objects exist and answer) **or** seen on the
   LAN in the neighbour table (`ip neigh show dev br-lan`, REACHABLE/STALE/DELAY) within the last
   **3 minutes**. DHCP leases do **not** count (12 h leases would fill the slots for half a day).
   `bridge` tool is **not installed** on A **[measured]** — use `ip neigh`, or add the small
   `bridge` package.
2. Whitelisted MACs (≤5) and registered **nodes** (§4.4) never take an open slot and are never
   refused.
3. Other devices take open slots first-come-first-served. When N are taken the next device is
   **refused**; when one leaves (3-minute grace) the slot frees.
4. After a reboot slots are re-taken in arrival order (state lives in `/tmp`, never in flash).
5. The owner can **pin** a present device (adds it to the whitelist if a whitelist place is free)
   or **kick** one (frees its slot; it is refused for a 2-minute cool-down).
6. Counted across both bands and cable together. **Do not use hostapd `maxassoc`:** it is
   per radio and cannot exempt anyone.
7. **Resource guard (new devices only).** On each tick, if `MemAvailable` < 40 MB, or
   conntrack count > 85 % of `nf_conntrack_max`, or the 1-minute load is above a set value,
   treat the network as **full** for new arrivals (same "network full" page, reason shown in the
   panel: "memory low"), write an event, and recover automatically when the numbers recover.
   Whitelisted devices are still let in. Never disconnect existing devices because of the guard.
   Thresholds are estimates for A and B; the load test (§10) sets the real ones. On A the same
   guard applies with the same defaults.
8. **Access-point bonus.** Effective open limit = `open_max + ap_bonus × AP nodes` (§2). AP
   nodes are the `node` entries of kind `ap` that the owner adds on B's dashboard; a node must
   be **bridged** (devices appear as their own MACs) to count. AP nodes themselves never take a
   slot (§4.4). Separately, devices seen on **B's own radios** are limited to `radio_max`
   (default 100) so the chip's station table is never overfilled; this limit does not grow
   with APs.

**Enforcement (the guarantee):** an nftables set + chains in `/etc/nftables.d/24-mwcap.nft`,
loaded with firewall4 like `20-mwguest.nft`. A refused MAC may reach only DHCP and the router's
DNS; its HTTP (port 80) is redirected to the existing page listener on `:8188` showing
"This network is full (10/10). Ask the owner." Everything else is dropped. Reuse the guest-page
CGI (`www-guest/cgi-bin/guest`) with one more state. Rules are rebuilt only when the admitted
set changes.

**Enforcement (nicety, phase 2):** for refused **Wi-Fi** clients also
`ubus call hostapd.<ifname> del_client '{"addr":…,"reason":5,"deauth":true,"ban_time":120000}'`
so the phone says "can't connect" instead of "connected, no internet" and airtime isn't wasted.

**Tick:** every 10 s from the existing watch loop (one `ubus` call per radio, one `ip neigh`).
Must cost near nothing when idle.

**Config** (uci `mwadmin.devcap`): `open_max` (A 20, B 70), `vip_max` (≤10, default 5),
`ap_bonus` (default 25, 10–60, editable per access point), `radio_max` (default 100 on B, unset on A), guard thresholds
`guard_mem_mb` (40), `guard_conntrack_pct` (85), `enabled`. The panel shows the live
numbers: "47 of 112 in use (100 base + 1 access point)", Wi-Fi table "46 of ~110", and
"memory OK / low".
**Data:** `/etc/mwadmin/vip_devices` (mac, name) — persistent, **shared** (§5); `/tmp/mwadmin/slots` — volatile.

**API** (in `api.sh`, same style as the others): `GET /devcap` (used/limit, who holds slots, VIP list, refused list),
`POST /devcap/set`, `POST /devcap/vip` (add/remove), `POST /devcap/kick`.
**UI:** panel section "Device limit": "7 of 10 in use", list with Kick / Make whitelisted,
the whitelist (max 5) with the random-MAC warning.

### 4.4 Nodes on A
`mwadmin` already has `node` sections (name, mac, kind router|ap, admin_url) **[measured]**.
Register B (and the Google Wifi) as nodes. A node is: exempt from the cap, exempt from block
lists (add to `exempt_devices` via `allow.sh` — this is also what keeps A's DNS blocking from
hitting all of B's clients as if they were one person), counted as signed in (`guest.sh`).
A can still apply its existing per-device speed cap (`devlimit.sh`) to B's MAC = a total-speed
limit for the whole second network. Surface it as one field.

## 5. Sharing the settings

**Rule: A is the master of shared settings.** B shows them read-only ("Managed by Main
router") and cannot edit them locally. This avoids two-way conflicts. Edits are made on A's
panel or on the website (which already proxies to A through `api.php`). **No change to the
existing editing flow.**

**Shared (A → B)**

| Setting | Source on A |
|---|---|
| Blocked sites | `/etc/mwadmin/blocked_sites` |
| Break window, daily allowance minutes | `uci mwadmin.pause.*` |
| Device groups | `/etc/mwadmin/groups` |
| Never-blocked devices | `/etc/mwadmin/exempt_devices` |
| Whitelist (VIP) devices | `/etc/mwadmin/vip_devices` (new) |
| Device names | **[verify]** where names live (`profiles`, `dhcp host` sections, node names) — pick one store and share it |
| 18+ filter on/off | `uci mwadmin.adult` — stays hidden in the UI, as the owner wants |
| Guest sign-in list (optional) | `/etc/mwadmin/guests` so a person signs in once for both networks |

MAC addresses are global, so a device keeps its name, group and exceptions on either network.

**Not shared (stay local):** SSID/password, LAN subnet, DHCP, caps, ports on/off, WAN setup,
admin password, tunnel identity, anything line/mwan3/USB.

**Flows that go both ways**
- *Access requests:* a device on B opens a blocked site → B writes the request (same
  `site_requests` format, tagged with B's node id) → uploaded to the website → appears in A's
  list → admin approves/denies on A or the website → the decision comes back down inside the
  policy bundle.
- *Daily allowance use (`pause_use`):* **default = shared per device/group**, otherwise a child
  gets another 60 minutes just by joining the other Wi-Fi. Each router uploads
  `owner, day, used_s` every minute; merge rule = max per (owner, day). Worst case an over-grant
  of about one sync interval. If the owner prefers separate allowances per router, it's one
  setting (`pause.shared_use`).

**Mechanism (reuses the channels that already exist)**
1. A builds a JSON bundle of the shared settings, with a `version` = hash. When it changes (and
   once an hour), A uploads it to a new `policy.php` on the website (token auth, same as
   `ingest.php`).
2. B polls `policy.php?token=…&have=<version>` every 60 s (or rides the `relay.php` long-poll)
   and gets the bundle only when newer.
3. B applies it by **writing the same files and uci keys the existing libs already read**, then
   reloading (`block.sh`/`pause.sh`/`allow.sh` apply functions — **[verify]** exact names). No
   change to the blocking logic itself.
4. B keeps the last applied bundle in flash. If the website or A is down, B keeps enforcing the
   last one; a power cut loses nothing.
5. Optional later: B pulls straight from A's LAN address when wired (faster, works when the
   internet is down). The website path is the one that must work first.

Security: bundle contains no passwords, keys or tokens. Size is small (a few KB). Reject a
bundle with an unknown schema version rather than half-applying it.

## 6. Website work (`portal/`, `webapp/`)

- **Locations:** add `sites(id, name)` and `routers.site_id`, `routers.role` ('main'/'branch').
  `portal.php/routers` returns locations with their nodes; the home card shows one location,
  two nodes, each with its own online dot, line (A only), clients used "7/10", last seen.
  `cli.php`: `add-site`, `add-router --site --role`.
- **Per-node tunnel ports.** A is `22081` (+ the second pair up to `22084`). Give B base
  `22085` (`22085–22088`). The host's `authorized_keys` entry for A's key is
  `permitlisten=22081-22084`; B gets **its own key** with `permitlisten=22085-22088`. Do not
  reuse A's key or token on B.
- **Policy storage:** `policy(site_id, version, json, updated)` + `policy.php` (PUT from A,
  GET for B).
- **Panel proxy:** unchanged (`api.php/r/<id>/…`). The panel has a node switcher at the top
  ("Main / Second"), and shared-setting pages always route to A.
- **Activity / events:** already keyed by `router_id`. Add a "whole location" view (UNION over
  the location's routers; names by MAC) next to the per-node view. Outage alerts
  (`alerts_lib.php`) must treat B going silent as its own alert.
- Remember the shared-host constraints in the existing notes: `permitlisten` ranges,
  relay fallback when port 22 is blocked, and the Let's Encrypt intermediate bundle B must ship
  (`le-intermediates.pem`).

## 7. Provisioning B (`migrate-router.sh` pattern)

New `provision-branch.sh`: flash OpenWrt → run `config/60-branch.sh` → install bundle with role
`branch` → generate **B's own** `portal_token`, tunnel key and host-key pin (the existing
migrate script deliberately never clones these) → print the `cli.php add-router` and
`authorized_keys` lines for the host.

## 8. Phases (each is shippable)

1. **Device cap on A** (§4.3) — useful on its own, no second router needed. Default 20+5.
2. **Role flag + B image** (§4.1, 4.2, 7): B boots, works as a NAT router with its own panel and cap.
3. **Website locations + B tunnel** (§6): B visible as a second node.
4. **Settings sync** (§5), one-way A→B, including allowance-use merge and access requests.
5. Wi-Fi kick nicety, direct-LAN sync, total-speed cap for B on A.
6. Not planned: WireGuard full tunnel.

## 9. Constraints from earlier decisions (do not violate)
- No Python/Node on the routers (16 MB flash class); shell + uci + ubus only.
- mwan3 stays on A only; hardware offload stays off there.
- Google Wifi stays in router mode behind A; do not design around bridge mode. Owner accepts that devices behind it cannot be limited.
- 18+ switch stays hidden; never on the DNS page or the website front page.
- LAN-to-LAN traffic is never shaped (`devlimit.sh` priority-1 rule).
- Router event log keeps only today's entries once uploaded; full history lives on the website.
- mwan3 policy/rule names ≤ 15 chars.
- Files may be CRLF on Windows; `build_fw.py` strips them, hand-copied files need `sed -i 's/\r$//'`.

## 10. Acceptance tests

1. **Cap:** with open_max=3, connect 3 phones + 1 laptop by cable → 4th is refused, sees the
   "network full" page, cannot browse; unplug one, wait 3 min+, the 4th gets in.
2. **Whitelist:** with the network full, a whitelisted device still joins; a 6th whitelist entry is rejected.
3. **Mixed:** slots are shared between Wi-Fi 2.4, Wi-Fi 5 and cable; devices can reach each other.
4. **Lease vs presence:** a device that left 30 min ago (lease still valid) does not hold a slot.
5. **Random MAC:** document the behaviour with an iPhone and an Android phone, private address on and off.
6. **Node:** B's WAN MAC is not counted, not blocked by A's DNS lists, still bandwidth-capped by A if set.
7. **Sync:** add a blocked site on A → blocked on B within ~2 min; remove → open. Kill A's internet → B keeps last policy. Reboot B → policy still there.
8. **Allowance:** use 30 min on A, switch to B's Wi-Fi → B shows 30 min left, not 60.
9. **Request flow:** blocked site on B → request appears on A/website → approve → opens on that device only.
10. **Failover:** unplug A's WAN1; B's clients keep internet through A's WAN2 (mwan3 is transparent to B).
11. **Load test (decides the final numbers):** step B from 30 → 75 (70 + whitelist) → 100 (one access point) → 150 (three) simulated or real clients (mix of 2.4 GHz, 5 GHz and cable) and A to 25, each 200–400 flows. Watch `MemAvailable`, conntrack count, load, `insight.sh` duration, Wi-Fi retries and, above all, **whether any existing device gets dropped**. Pass: no existing device is disconnected at any step, each router keeps ≥ 40 MB available, and the 21st open device on A, and the 71st on B with no access points, is refused. If 2.4 GHz retries are high, steer devices to 5 GHz or lower `radio_max`. Also find the real MT7615 station-table size by associating clients until it refuses, and set `radio_max` just under it.
14. **Guard:** deliberately fill memory/conntrack (e.g. a flow generator) on B: new devices get the "full / memory low" page, existing devices keep working, and new ones are admitted again once the numbers recover. Whitelisted device still joins during the guard.
15. **Access-point bonus:** with B at its limit, add a bridged AP node on B's dashboard → the limit rises by 25 and devices on that AP are admitted; add a router-mode AP → no bonus; remove the node → the limit drops back and existing devices stay connected until they leave.
12. **Website:** both nodes under one location; unplug B → B alert only; A unaffected.
13. **Safety:** LAN change on B reverts via the 90 s rollback if the admin loses access.

## 11. Open questions for the owner (the plan assumes the answer in brackets)

1. ~~What hardware is B?~~ Answered: EA8100, own Wi-Fi, as high as it safely goes (A = 20 + 5; B = 70 + 5, +25 per access point).
2. Wired B uses one of A's three free LAN ports. [Accepted.]
3. In "over the internet" mode, should B's traffic exit through A's IP? [No — own ISP line; shared settings only.]
4. Shared daily allowance across both routers? [Yes, shared per device/group.]
5. Should B's panel be able to edit shared settings when A is offline? [No — read-only; edit on A or the website.]
