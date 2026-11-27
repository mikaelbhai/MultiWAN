# Baytaar Router Installer (Windows)

`BaytaarInstaller.exe` puts OpenWrt and the Baytaar software (MultiWAN) on a new router and joins it to a website account.
Download: `https://mikaelbhai.com/router/BaytaarInstaller.exe` (also linked on the website, in **Add a router** and at the
bottom of the page). It is not code-signed: Windows shows "unknown publisher" (More info, Run anyway).

## What it does, step by step

1. **Website account:** website address and API key (from **Add a router**). The key is checked on the website
   (`enroll.php` with `check: true`; nothing is created, a wrong key counts against the same 8-per-15-minutes limit).
   Can be skipped (the router then joins later from its panel).
2. **Router model:** Linksys EA8100 v1 (tested: Router 1 and Router 2), EA8100 v2 (untested), TP-Link Archer C6 v3
   (the project's first router; this OpenWrt version untested on it). Anything else is refused.
3. **OpenWrt:** the version the website recommends for the model (`router/fw/openwrt.json`, else 25.12.6), downloaded from
   downloads.openwrt.org and refused unless it matches OpenWrt's own sha256 (from `profiles.json`, which also confirms the
   image is for that board). Factory image for a router with its original software, sysupgrade image for one with OpenWrt.
   Saved in `Downloads\Baytaar Installer`.
4. **Put OpenWrt on the router:** written steps for the Linksys, TP-Link or LuCI page, buttons to open the page and show the file.
5. **Settings (essentials):** router name and password, Wi-Fi name and password, country, main line (automatic, fixed
   address or PPPoE), a second line on LAN 1 and a third on LAN 2 (unused line ports join the LAN), router address
   (default 192.168.20.1, away from the 192.168.1.x most modems use).
6. **Install:** waits for OpenWrt at 192.168.1.1, logs in through OpenWrt's web JSON-RPC (`/ubus`, the interface LuCI uses;
   blank password on a fresh OpenWrt), checks the board name and the OpenWrt version (25.x), downloads the Baytaar software
   from the website and checks its sha256, uploads the stage scripts (`MultiWAN/config`), a generated `mwan.env`, the
   software and `router_runner.sh`, and starts the runner detached. The runner: internet on the main line, packages,
   Baytaar software, join the website with the key, network / firewall / DHCP / Wi-Fi / lines, router password, reboot.
   Progress is read from the router (first through `/ubus`, then from `install-status.txt` on the panel, at the old and
   then the new address).
7. **Done:** the panel address, whether it joined the website.

Secrets (router password, Wi-Fi password, PPPoE password, API key) only go to the router, in `/tmp` (RAM), and the
runner deletes `install.env` when it finishes or fails.

Build: `python installer/build.py` (PyInstaller, one file, no console) -> `installer/dist/BaytaarInstaller.exe`.

## Tested, and not tested (2026-11-27)

Tested: every page builds; the generated `mwan.env` read back by a real shell (passwords with quotes, `$` and backticks
come through intact; port layout for 2 lines); a wrong checksum is refused and the file deleted; the website refuses a
wrong key in check mode; the download links work.

**Not tested: a real install on a router** (no spare router was available). The first real run should be on a router
whose settings do not matter, with the cable to a LAN port and the modem in the internet port.
