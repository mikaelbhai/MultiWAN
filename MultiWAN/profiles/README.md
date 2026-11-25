# Profiles: cleaned copies of real routers' settings

`router1/` is the main router (Linksys EA8100, three lines, mwan3 failover) as it runs today, exported on
2026-11-26 with everything personal removed. It is a **reference and a starting point**, not something a
router installs by itself: the bundle never writes these files, so an upgrade can never overwrite a router's settings.

What is in it (`router1/config/` are OpenWrt config files, `router1/mwadmin/` the extra files in `/etc/mwadmin/`):

| File | What it holds |
|---|---|
| `network` | LAN bridge and address, the line ports (WAN1 = port `wan`, WAN2 = `lan1`), the admin and block-page addresses |
| `dhcp` | DHCP pool (.2 to .201, 12 h), pinned DNS servers and the encrypted-DNS name blocks, `sites.router`, the speedtest.net pin |
| `firewall` | zones, forwarding, SSH blocked from the internet, panel allowed from the LAN |
| `mwan3` | the two lines, health checks, failover policy, rules (calls and HTTPS pinned to chosen lines) |
| `wireless` | both radios, one name on both bands |
| `mwadmin` | alerts, game blocking list, which line carries calls, break times, guest network, line names |
| `mwadmin/addr_swaps` | the address swap that works around Transworld's block on one Cloudflare address |

What was **removed or replaced** (so nothing here can identify a person or open a door):
WAN1's real public address, gateway and ISP resolvers (replaced by documentation addresses, as in `config/mwan.env.example`),
the Wi-Fi password (`CHANGE-ME-BEFORE-USE`), every per-device DHCP reservation (names, MACs, addresses), every port
forward, the registered access points and routers (names, MACs, addresses), the website host and account, per-line ids and
measurements, and the place name.

Using it on a new main router: install the software, then copy the files you want over `/etc/config/` by hand,
**after** setting the real WAN1 address, the Wi-Fi password and the LAN address; `uci show` to check; reboot or `/etc/init.d/network restart`.
Do not copy `network` blindly to a router whose ports are named differently (`ls /sys/class/net`).
