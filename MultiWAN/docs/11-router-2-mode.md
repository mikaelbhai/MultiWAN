# 11: Router 2 mode (2026-11-26) - NOT YET TRIED ON A REAL SECOND ROUTER

The old "Access Point mode" is now one of two variants of the **Router 2** role, chosen by a DHCP switch on
Operating mode. The main router (Router 1) is unchanged: it is the default mode and nothing here runs on it unless
someone presses the button.

| | DHCP on (`router2`) | DHCP off (`ap`, the old access point mode) |
|---|---|---|
| Network | its own, default 192.168.2.1/24 | none of its own: joins Router 1's network |
| Addresses | handed out by Router 2 | handed out by Router 1 |
| Uplink | one: the WAN1 port, an ordinary DHCP client of Router 1 | none (all ports bridged) |
| NAT, firewall | on | off |
| mwan3 (multi-WAN) | off (one line, nothing to fail over; no false "line down" alerts) | off |
| Wi-Fi | unchanged (set a different name from Router 1) | unchanged, bridged to Router 1 |

How it works (`lib/modeswitch.sh`): a change snapshots the running configuration to a named profile on flash, builds
the new variant from the saved **main-router** profile, and arms the existing 90-second rollback; if nobody confirms,
the snapshot is restored and the device restarts. `to-router` restores the main-router profile, from either variant.
API: `POST /mode/router2 {dhcp:"1"|"0", lan_ip, lan_mask, bridge_all, proto, ipaddr, netmask, gateway}`;
`POST /mode/ap` still works (it is DHCP off). `POST /mode/router`, `/mode/confirm` unchanged.

Guard: with DHCP on, the address is refused when it is in the same /24 as the default gateway Router 2 currently has.

## What was tested, and what was not

Tested: shell syntax on the router's own shell; `modeswitch.sh preview 1|0`, which applies the change to a **copy** of
the settings (`MW_DRY=1 MW_UCI_DIR=...`: nothing started or stopped, no mode file) and prints the result: DHCP on gives
LAN 192.168.2.1, WAN1 as DHCP client, spare ports in the LAN, WAN2/3 gone, the alias moved to .254; DHCP off gives the
bridged layout the access point mode always produced. The main router's mode, address and configuration were
checked unchanged afterwards.

**Not tested: a real switch on a real second router** (firewall zones with only one line, hostapd after the switch,
the DHCP server restarting on the new address, the rollback restoring the previous variant). Do the first switch with
a cable to a laptop and the 90-second rollback in mind; failsafe mode is the way back if everything fails.

## Not built

A cap on the number of devices (the plan's 20+5 for Router 1, 70+5+25 per access point for Router 2) does not
exist in the software yet, on either router; the per-device speed limits are a different feature. Settings sync
between the routers (docs/08) is also still a plan.
