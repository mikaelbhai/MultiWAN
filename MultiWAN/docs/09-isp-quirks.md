# 09: ISP quirks seen in the field, and the tools for them

## Transworld resets connections to one Cloudflare address (2026-11-25)

**Symptom.** With only Transworld (WAN2) carrying traffic, `www.speedtest.net` does not load
(`ERR_CONNECTION_TIMED_OUT` / "connection reset"). With Connect (WAN1) it loads normally.

**What was measured** (router, each line tested on its own with `mwan3 use wan1|wan2 curl ...`;
a plain `ping -I` or `curl --interface` does not pin a line while another is forced):

| Test | Connect | Transworld |
|---|---|---|
| TCP connect to 104.17.148.22:443 | works | works |
| TLS handshake to 104.17.148.22, name www.speedtest.net | works | **reset by peer** |
| same address, name www.cloudflare.com | works | **reset** |
| same address, plain HTTP (no name at all) | works | **fails** |
| neighbours 104.17.147.22, .148.21, .148.23, .149.22, 104.17.0.1 | work | work |
| speedtest.net, c.speedtest.net, ookla.com, fast.com, speed.cloudflare.com | work | work |
| kick.com (site, API, player, images, chat host), netflix.com and Netflix's video servers | work | work |

So it is **one destination address**, whatever name is used, and it only happens on Transworld. The
router, the cable (100 Mb, 0 errors) and DNS (identical answers from every resolver on both lines) are fine.
It is a filter or fault inside Transworld's network. Other differences between the two lines: Transworld has
about 120 ms latency to 1.1.1.1 (Connect: 1.5 ms) and leaves through Singapore.

**Tool: line exceptions** (`lib/lines.sh`). A destination that must always use one line:

```
/etc/mwadmin/line_exceptions        one per line:  <ip or cidr> <wan1|wan2|wan3> <note>
104.17.148.22 wan1 www.speedtest.net address: Transworld resets connections to it
```

Each entry becomes an mwan3 rule on that line's own policy (that line first, the others only if it is down),
placed before the call rules and the HTTPS rule, so it wins over "use only this line" for that address. The
rules are rebuilt from the file together with all the others, so they survive every settings change.
API: `GET /lines/exceptions`, `POST /lines/exceptions {"action":"add|del","dest":"...","wan":"wan1","note":"..."}`.

Verified: UDP to ordinary addresses leaves through Transworld (connection mark 512) and UDP to
104.17.148.22 leaves through Connect (mark 256).

Caveats: a speed test of that site now measures Connect, not Transworld (use `fast.com` or
`speed.cloudflare.com` to measure Transworld). If Cloudflare moves the site to another address the entry has
to change. If Connect is down the address goes through Transworld and breaks again; nothing local can fix that.
The proper fix is for Transworld to remove the block: give them the address and the symptom
("TCP connects, then the connection is reset during the TLS handshake, only for 104.17.148.22").

## Lessons for testing lines

- Restore a port you took down with `ifup wanN`, as the panel does. A bare `ip link set <port> up` leaves
  the line's routes dead and mwan3 keeps the line offline (the router now heals this itself after 60 s, `site_selfheal`).
- Pin a test to a line with `mwan3 use <line> <command>`.
- `timeout` does not exist on the router; detach long jobs with `setsid`.
