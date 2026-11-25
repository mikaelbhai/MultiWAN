# Baytaar / MultiWAN

Multi-line internet gateway software for OpenWrt routers, with a website portal and an Android app to watch
and control them from anywhere.

> **Looking for the first, router-only version?** It is kept on the [`legacy`](../../tree/legacy) branch.
> It has the older, weaker interface, has no online checking (no website, no alerts), and may not work on
> newer hardware. This branch (`main`) is the current version.

## What is in here

| Folder | What it is |
|---|---|
| `MultiWAN/` | The router software: config scripts, the admin panel and its shell API (`package/`), docs (`docs/`). Start with `MultiWAN/README.md`. |
| `webapp/` | The website: dashboard, panel, activity pages, enrolment and the router channel (PHP + static pages). |
| `portal/` | Website back end that lives outside the web root: accounts, alerts, push, enrolment keys (`cli.php`). |
| `android-app/` | The phone app (WebView of the portal, outage alerts, push). Source only. |
| `repeater/` | Script that turns a spare router into a wireless repeater. |
| `build_fw.py`, `build_web.py` | Build the router update bundle and the website's copy of the panel. |
| `migrate-router.sh` | Copy data and settings from one router to a fresh one. |

## Main features

- Two or more internet lines with priority failover, speed tests, per-line naming and "use only this line"
  (asks first, resets open connections, checks the line really works, and puts everything back by itself if not).
- Alerts: main line down (20 s), backup line down (1 min), nodes (switches, access points) down, router offline
  (only when its upload, HTTPS channel and tunnel are all silent). Each line outage carries the router's own opinion of why.
- Site blocking with break time and allowances, per-device speed caps, guest sign-in, USB drive sharing.
- Remote access through an outbound SSH tunnel or an HTTPS channel (no inbound port on the router).
- A router joins a website with only the website's name and a one-time key:
  `php portal/cli.php new-key "Router name"`, then on the router
  `sh /usr/lib/mwadmin/connect.sh join <website> <key>`.
- `MultiWAN/docs/08-two-router-plan.md`: plan for a second router with shared settings and device limits (not built yet).

## Hardware

Developed and tested on the Linksys EA8100 v1 (OpenWrt 25.12). The first version targeted the TP-Link Archer C6 v3.

## What is deliberately not in this repository

Router backups and firmware images, SSH and signing keys, the Android signing key, the Firebase service
account and `google-services.json`, the site's database, and `MultiWAN/config/mwan.env` (your real Wi-Fi
password and addresses; copy `mwan.env.example`). Everything you need to supply is read from files that are ignored.

## Contributors

- **Mikael** ([@mikaelbhai](https://github.com/mikaelbhai)): owner, hardware, on-site testing, every real-world decision.
- **Claude** (Anthropic): wrote most of the code and documentation, working interactively with Mikael.
