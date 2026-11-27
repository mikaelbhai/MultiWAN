# 14: Mode 3 (node: cable, mesh, repeater), 128 MB routers, and the universal package (2026-11-27)

## The three modes

| | Mode 1: main router | Mode 2: Router 2 | Mode 3: node |
|---|---|---|---|
| Job | multi-WAN gateway | a second router with its own network behind Router 1 | adds Wi-Fi to Router 2's network |
| Addresses (DHCP) | gives out | gives out (its own range, default 192.168.2.x) | none (Router 2 does) |
| Routing, NAT, firewall | yes | yes | no |
| Uplink | its lines | one cable to Router 1 | cable, Wi-Fi mesh, or any Wi-Fi (repeater) |

Mode 3 replaces "Router 2 with DHCP off" (the old access point mode, mode file `ap`, still works and shows as
"Mode 3: node (cable)").

### Mode 3 uplinks (`lib/node.sh`, `modeswitch.sh to-node`)

- **Cable:** all ports bridged, the router is a DHCP client of Router 2's network, DHCP and DNS off.
- **Wi-Fi mesh:** the same, but the link to Router 2 is an encrypted 802.11s mesh on 5 GHz (`wireless.mwmesh`, SAE,
  `mesh_fwding 1`, bridged into the LAN). Needs `wpad-mesh-mbedtls` instead of `wpad-basic-mbedtls`: installed at switch
  time, while the router still has its current connection. Router 2 turns on **Mesh for nodes** (Operating mode page,
  `POST /wifi/mesh`): the same mesh link on its 5 GHz radio, on a fixed channel (every member of a mesh must share it).
- **Repeater:** joins any Wi-Fi as a client (`wireless.mwsta`, `network.wwan` DHCP) and passes it through with relayd
  (`network.mwrelay`, proto relay, lan + wwan), so devices get their addresses from that Wi-Fi. Picked from a scan
  (`GET /wifi/scan`) or typed. By default it repeats under the same name and password (devices move between them by
  themselves); or its own name. The router keeps a management address 192.168.199.1 on its own ports. Needs `relayd`.

Every node broadcasts the given Wi-Fi name and password with **fast roaming**: 802.11r (`ieee80211r`, mobility domain
derived from the Wi-Fi name so every router with that name matches, `ft_psk_generate_local`) and 802.11v
(`bss_transition`). Router 2's own Wi-Fi gets the same when Mesh for nodes is turned on. 802.11k needs the full wpad and
is not set.

Same safety as the other modes: the main-router profile is saved first, the node is built from it, and the 90-second
rollback restores the previous mode unless confirmed. `modeswitch.sh preview-node <file>` shows the result on a copy.

## 128 MB routers (memory profile)

`common.sh` reads MemTotal. Under ~200 MB (a 128 MB router; its /tmp is then ~60 MB) the same software uses smaller RAM
caches: DNS query log 2 MB (second guard 4 MB), activity records 1 MB, app details 1500 rows, address names 2500, and the
clutter guard acts at 45 % instead of 60 %. Everything else, including the website connection, is unchanged.

## Universal package (any OpenWrt router)

- `lib/hwdetect.sh`: board, ports (from `/etc/board.json`: the WAN device and the LAN ports), DSA or not, radios, USB,
  free storage, memory, package manager; `hwdetect.sh env N` writes the port layout for N lines (WAN = the WAN port,
  extra lines = the first LAN ports; an older swconfig router gets one line). Panel/API: `GET /hardware`.
- `openwrt/baytaar-multiwan/Makefile`: one package (`PKGARCH all`: scripts and web pages only) built with the OpenWrt
  SDK by `.github/workflows/openwrt-package.yml`: `.apk` for OpenWrt 25.12, `.ipk` for 24.10. Its files are the website
  bundle (`build_fw.py` -> `openwrt/stage_root.py`), so both always install the same software. Depends on mwan3, curl,
  nlbwmon, conntrack, uhttpd, jsonfilter, ip-full. postinst runs `lib/setup.sh` (the same setup the website upgrade
  runs; `apply.sh` now calls it too).
- After installing: `baytaar-setup` over SSH asks the essentials (lines, main line type, router address, Wi-Fi, website
  key) with this router's own port names and applies the stages in the background.

## Tested, and not tested

Tested on the real routers, without changing them: hardware detection on both (ports, radios, USB, storage); the three
node types previewed on a copy of Router 2's settings (bridging, DHCP off, mesh link, repeater client and relay, fast
roaming with a matching mobility domain, a Wi-Fi password with quotes and `$` intact); a mesh request without a mesh
password refused; the Wi-Fi scan on Router 1 (6 networks with signal and security). The package file tree staged locally.

**Not tested:** a real switch to Mode 3 of any kind, a real mesh link or roaming between two routers, a repeater joining
a real Wi-Fi, a 128 MB router, the package on another brand, `baytaar-setup` on a fresh OpenWrt. Router 2's Wi-Fi scan
returned nothing (its driver gave no results while serving devices; typing the name works).
