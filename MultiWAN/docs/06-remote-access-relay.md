# 06 — Remote Access: Reaching the Admin UI Over the Internet

This covers the "Remote Access" page in the admin UI: an outbound relay tunnel that lets you
reach this router's admin panel from anywhere, without opening any inbound port on the router
itself. Everything on the router side is automated by the app. One step, on the relay host, is
not — this document is those exact instructions.

---

## 1. Architecture

```
Browser/phone  --HTTPS-->  your relay host's public web server
                                |  reverse-proxy rule (relay-host-side, manual)
                                v
                      127.0.0.1:<remote_port>  (relay host, loopback only)
                                ^
                                |  SSH reverse tunnel (-R), router-initiated, outbound only
                      this router's admin port (LAN-bound, e.g. :8080)
```

- **The router never accepts an inbound connection from the internet.** It dials out to your
  relay host over ordinary SSH, the same as any outbound client connection, and asks that host to
  forward one of its own loopback ports back through the tunnel. `firewall.admin_ui_wan` (the
  separate, direct-WAN-exposure rule described in the main README) stays disabled — this feature
  does not need it and does not touch it.
- **What the relay host actually is matters less than you'd think.** A real VPS with root works.
  So does an ordinary shared-hosting SSH account with no root at all, *as long as*
  `AllowTcpForwarding` is permitted for that account (true on most hosts; not something you can
  usually change yourself if it's off — ask the host, or use a different one).
- **The one thing this app cannot configure for you**: making a public HTTPS address on the relay
  host actually proxy to the forwarded loopback port. That's entirely a property of whatever web
  server runs on the relay host, which this router has no access to. See §3.

---

## 2. Router-side setup (all in the UI)

1. No package to install: confirmed live that dropbear's own SSH client (`/usr/bin/ssh` on every
   OpenWrt install, no extra flash) supports `-R` remote forwarding directly. Nothing to do here.
2. Open the **Remote Access** page. Click **Generate key pair**. The private key is written to
   `/etc/mwadmin/remote_id_ed25519` and never shown or transmitted — only the public half is
   displayed.
3. Fill in:
   - **Relay host** — the hostname or IP you SSH to.
   - **SSH username** — the account you SSH in as.
   - **SSH port** — usually 22.
   - **Remote (loopback) port** — pick anything **1024 or above** that's likely free on the relay
     host (e.g. `18080`). This is the port the relay host will listen on, on its own `127.0.0.1`
     only — never exposed directly to the internet, only reachable from that host's own web
     server.
4. Copy the public key shown and add it to the relay host's `~/.ssh/authorized_keys` (see §3.1).
5. Enable the tunnel and save. The Status card should read **connected** within about 10 seconds.

---

## 3. Relay-host setup (manual — do this once)

### 3.1. Authorize the router's key

SSH into the relay host with whatever access you already have, then:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<paste the public key from the admin UI>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 3.2. Reverse-proxy a public address to the forwarded port

**This deployment's target is `https://mikaelbhai.com/MultiWAN/`** — a path on the existing
domain, not a new subdomain. That's actually simpler: `mikaelbhai.com` already has a working
TLS certificate (confirmed live), so no new cert is needed, just a path-scoped proxy rule.

This is host-specific and confirmed **not** to work as a plain `.htaccess` file written over SSH
(tested live: a per-directory `.htaccess` `RewriteRule ... [P]` proxy rule on this exact
OpenLiteSpeed/CyberPanel install returned HTTP 500 — LiteSpeed disables the proxy flag at
per-directory scope for security). It only works configured at the panel/vhost level:

1. Log into the CyberPanel panel at `https://<relay-host-ip>:8090` (or
   `https://mikaelbhai.com:8090`) with your CyberPanel admin account.
2. **Websites → List Websites → mikaelbhai.com → Manage → Rewrite Rules.**
3. Add a rule scoped to the `/MultiWAN` path only (so the rest of the live site is untouched),
   proxying to the loopback port you set in the router's Remote Access page (§2 above), e.g.
   `18080`:

   ```apache
   RewriteEngine On
   RewriteCond %{REQUEST_URI} ^/MultiWAN
   RewriteRule ^/MultiWAN/?(.*)$ http://127.0.0.1:18080/$1 [P,L]
   ```

   If CyberPanel's Rewrite Rules screen also rejects the `[P]` flag (it may — this hasn't been
   tested on a live panel yet, only the per-directory `.htaccess` failure has been confirmed),
   the fallback is **Websites → Create Website**, choosing the **Node.js** application type for
   a new site, since that site type is generically "run something on a port, proxy HTTPS to it"
   at the panel level regardless of what's actually listening there — point its port at the same
   loopback port.
4. Save, then test: `curl -I https://mikaelbhai.com/MultiWAN/` should reach the router's admin
   login page (once the router-side tunnel is enabled and connected) rather than a 404 or 500.

### 3.3. Add a second layer of auth in front (strongly recommended)

The relayed connection lands on this router's own login page, which still requires the router's
root password and carries its own CSRF/session protection — but it's still your router's login
prompt sitting on the open internet. A second layer in front of it is worth having.

**Plain `.htaccess` Basic Auth does NOT work on this host** — confirmed live, the same way the
`[P]` proxy flag didn't: an `AuthType Basic` / `Require valid-user` block in
`~/public_html/MultiWAN/.htaccess` was silently ignored (a request with zero credentials still
got a `200`, not the expected `401`). LiteSpeed on this CyberPanel install restricts per-directory
`.htaccess` more broadly than just the proxy flag, not only proxying.

What's already prepared on the host, ready to use once real auth is wired up: a password
hash lives in `/home/<ssh-user>/.htpasswd_router` (standard `htpasswd` format), and
`~/public_html/MultiWAN/.htaccess` exists with the (currently inert) directives above — if CyberPanel's
panel offers a **"Password Protect Directories"** feature (Websites → Manage → Security, common
across CyberPanel/cPanel/Plesk), point it at `MultiWAN` and it may pick up that same `.htpasswd`
file directly, or it may generate its own — either is fine, whichever the panel actually enforces
is the one that matters. This is the same category of step as §3.2 (panel-level config this app
cannot script), so do both in the same visit to the panel.

If the panel has no such feature either, the pragmatic fallback is to skip the second layer and
rely on the router's own login + CSRF protection alone, which is real protection on its own —
just not defense-in-depth.

---

## 3a. Method 2 — direct port forward (the simpler alternative)

The Remote Access page also has a second, independent method: enabling the router's own
pre-built (but disabled-by-default) `firewall.admin_ui_wan` rule, forwarding straight to whichever
WAN currently has a real public IP. No relay host, no manual panel step — but the login page is
directly internet-reachable on plain HTTP, and it only works on a WAN that isn't itself behind
another layer of NAT. The same page shows, per WAN, whether its current address is public
("ready") or private ("behind another NAT" — forward the port on whatever router/modem sits
upstream of that WAN instead, pointed at the address shown). Both methods can be configured
independently; nothing stops you from having both available at once.

## 3b. Offloading history to the relay host

Once a relay host is configured *and enabled* (Method 1), `package/lib/history_offload.sh` runs
from cron every 30 minutes: it appends this router's WAN/node online-offline history onto
`~/mwadmin-history/{wan,nodes}.log` on the relay host over the same SSH key, then truncates the
local copy. This is deliberately tied to Remote Access being on — with nowhere to send it, the
router just keeps a bounded local history (capped at 500 events per file) instead. Silent-failing:
a relay outage leaves rows queued locally for the next attempt rather than erroring anywhere
visible.

## 4. Verifying it end to end

See §9a of [`docs/04-verification-checklist.md`](04-verification-checklist.md).

## 5. Turning it off

Disable the tunnel from the Remote Access page — the outbound SSH process stops immediately and
the public URL goes dark, whether or not you also tear down the relay-host side. Nothing on the
router itself was ever reachable from the internet directly, so there is no separate router-side
"undo."
