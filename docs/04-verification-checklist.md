# 04 — Verification Checklist

Work through this in order. Each test states what to do, what a pass looks like, and what to check
if it fails.

**Do test 1 before anything else, and keep a paperclip nearby throughout.** Failsafe mode is your
way out of every mistake in this document.

---

## 0. Recovery rehearsal (do this first)

Practising recovery *before* you need it is the difference between an inconvenience and a
weekend.

- [ ] **Enter failsafe mode deliberately.** Power off. Power on, and when the LEDs flash, press
      the **Reset** button repeatedly for a few seconds. Set your computer to a static
      `192.168.1.10/24` and run `ssh root@192.168.1.1`.
- [ ] **Confirm you get a shell.** In failsafe, no configuration is applied and there is no
      password.
- [ ] **Confirm your backup restores.** `sysupgrade -r /root/multiwan-preinstall-*.tar.gz`
- [ ] Reboot normally.

**Pass:** you reached a failsafe shell and back out again.
**If it fails:** stop. Do not proceed until you can reach failsafe mode. Re-read
[`02-flashing-and-recovery.md`](02-flashing-and-recovery.md) §4.

---

## 1. Base install

- [ ] `cat /tmp/sysinfo/board_name` → `tplink,archer-c6-v3`
- [ ] `ip -br link` shows `wan`, `lan1`, `lan2`, `lan3`, `lan4`, `br-lan`
- [ ] `df -h /overlay` shows at least 2 MB free
- [ ] `free -m` shows well over 60 MB available
- [ ] `logread | grep -iE 'error|fail'` shows nothing alarming

---

## 2. WAN interfaces

- [ ] `ip -4 addr show` — all three WAN devices have addresses
- [ ] WAN1 shows your configured static IP
- [ ] WAN2 and WAN3 have DHCP-assigned addresses
- [ ] Each uplink reaches the internet independently:
      ```bash
      ping -I wan -c 3 1.1.1.1
      ```
      Repeat with the WAN2 and WAN3 device names (`lan1`, `lan2` by default).

**If an uplink fails:** check the cable, confirm the modem is in bridge mode if it should be, and
confirm the port role in the admin UI matches where the cable actually is.

---

## 3. mwan3 baseline

- [ ] `mwan3 status` shows all three interfaces `online`
- [ ] `mwan3 status` shows the policy carrying traffic on **wan1**
- [ ] `mwan3 interfaces` shows all trackers active
- [ ] A LAN client's traffic egresses via WAN1:
      ```bash
      curl -s http://ip-api.com/json/ | grep query
      ```
      The address returned should match WAN1's public IP.

---

## 4. Failover — the test that matters most

This is the acceptance test for the whole project. Run it deliberately, and time it.

### 4a. Forced failover

- [ ] Start a continuous ping from a LAN client: `ping 1.1.1.1 -t` (Windows) or `ping 1.1.1.1`
- [ ] **Physically unplug the WAN1 cable.** (Better than `ifdown`, which is a clean shutdown and
      does not simulate a real line failure.)
- [ ] Watch the ping output and count the lost replies.

**Pass:** replies resume after roughly **4–10 seconds**. `mwan3 status` shows `wan1` offline and
traffic on `wan2`.

**If it takes much longer:** check `logread | grep mwan3` for the transition timestamps and
confirm the tracking targets are reachable from WAN2.

**If it never recovers:** confirm WAN2 actually has internet independently (test 2), and check
that hardware offload is off: `uci get firewall.@defaults[0].flow_offloading_hw` must be `0`.

### 4b. Confirm the drop behaviour is what was documented

- [ ] Start a large download, or an SSH session to an external host, over WAN1.
- [ ] Unplug WAN1 mid-transfer.

**Expected — this is correct behaviour, not a fault:** the transfer fails and the SSH session
dies. New connections work over WAN2 within ~10 seconds. If you expected the download to
continue, re-read [`03-failover-expectations.md`](03-failover-expectations.md) §2.

### 4c. Failback

- [ ] Plug WAN1 back in.
- [ ] Watch `mwan3 status`.

**Pass:** `wan1` returns to `online` after roughly **6–14 seconds** and resumes carrying traffic.
New connections use WAN1 again.

### 4d. Sticky sessions

- [ ] With traffic failed over to WAN2, start a long-running download.
- [ ] Reconnect WAN1 and wait for failback.

**Pass:** the in-progress download **continues over WAN2** and does not stall. Only new
connections move to WAN1. This is the `flush_conntrack` behaviour working correctly.

### 4e. Flap resistance

- [ ] Unplug and replug WAN1 rapidly, four or five times over about 20 seconds.

**Pass:** the router does not thrash. Because `up=3`, WAN1 must be continuously healthy for ~6
seconds before traffic returns. `logread | grep mwan3` should show far fewer transitions than
you made cable changes.

### 4f. Total outage

- [ ] Unplug all three WAN cables.

**Pass:** LAN clients get immediate connection errors rather than long hangs — this is
`last_resort=unreachable`. `mwan3 status` shows all three offline.

- [ ] Replug them all. All three return to `online`, WAN1 carries traffic.

---

## 5. Port detection

- [ ] Unplug a WAN cable, wait 10 seconds, plug it back in.
- [ ] Open the admin UI → **Ports**.

**Pass:**
- The port shows link and a negotiated speed within a second or two of replugging.
- A test begins automatically and finishes within ~60 seconds.
- Download, upload, latency, and a detected ISP all populate.
- "Last test" shows a recent timestamp.

- [ ] Press **Re-test** on a port. It re-runs.
- [ ] Check the honesty of the numbers: on the gigabit WAN1 the result should carry the CPU-ceiling
      note. On the 100 Mb links it should read close to 100 Mb/s.

**Known-good "failures" that are correct behaviour:**
- ISP name blank or wrong — best-effort, as documented.
- A test on an unplugged port reports "No cable detected".
- A test on a link with no DHCP lease reports "no IP address after 30 s".

---

## 6. LAN and DHCP

- [ ] A wired client on a LAN port gets an address in your configured range.
- [ ] It reaches the internet.
- [ ] `nslookup openwrt.org` resolves.
- [ ] The client appears in the UI under **LAN & DHCP → Active leases**.
- [ ] Press **Reserve** next to it, save, renew the lease, and confirm it receives the reserved
      address.
- [ ] **LAN-to-LAN speed:** transfer a large file between two devices on LAN ports. This should
      run near gigabit — it is switched in hardware and never touches the CPU.
- [ ] **Routed speed:** run a speed test from a LAN client to the internet. Expect **300–500
      Mbps**, not gigabit. This is the documented mwan3 trade-off, not a fault.

---

## 7. Wi-Fi

- [ ] Both SSIDs are visible.
- [ ] A client connects on 2.4 GHz and reaches the internet.
- [ ] A client connects on 5 GHz and reaches the internet.
- [ ] Wireless clients are on the same subnet as wired LAN clients.
- [ ] Guest SSID connects, reaches the internet, and **cannot** reach a LAN device:
      ```bash
      ping 192.168.20.1   # should work (router only)
      ping <a LAN client> # should FAIL — this is the point of the guest zone
      ```
- [ ] Change an SSID in the UI, save, and confirm the change takes effect.

---

## 8. Firewall and security

- [ ] Add a port forward in the UI; confirm it appears in `nft list ruleset | grep dnat`.
- [ ] Remove it; confirm it disappears.
- [ ] **Admin panel is not reachable from WAN.** From outside your network, or using a phone on
      mobile data:
      ```
      http://<your WAN1 public IP>:8080
      ```
      **Pass: this must time out or refuse.** If it loads, stop and investigate immediately.
- [ ] Confirm the listener is bound correctly:
      ```bash
      netstat -ltn | grep 8080
      ```
      **Pass:** it shows `192.168.20.1:8080`, **not** `0.0.0.0:8080`.
- [ ] SSH from WAN is refused.
- [ ] Log in to the admin UI with the wrong password — it is rejected with a delay.
- [ ] Log in with the correct root password — it works.
- [ ] Sign out; confirm the API returns 401 afterwards.

---

## 9. VPN, QoS, DDNS

- [ ] **WireGuard:** generate a key pair in the UI. If you configure a tunnel, expect **~90 Mbit/s
      maximum** — verify this rather than assuming it is broken when it does not hit gigabit.
- [ ] **QoS:** enable SQM on WAN2 with a limit near its real capacity. Confirm latency under load
      improves. Confirm CPU usage rises noticeably (`top`) — this is expected.
- [ ] **DDNS:** configure a provider, save, and confirm the hostname resolves to WAN1's public IP
      within a few minutes.

---

## 9a. Remote Access (outbound relay tunnel)

See [`docs/06-remote-access-relay.md`](06-remote-access-relay.md) for the full setup (this is the
one feature in this app with a manual, off-router step).

- [ ] **Generate a key pair** from the Remote Access page. Confirm the public key is shown and a
      private key file now exists on flash (`ls /etc/mwadmin/remote_id_ed25519*` over SSH).
- [ ] Paste the public key into the relay host's `~/.ssh/authorized_keys`.
- [ ] Fill in relay host, SSH username, SSH port, and remote port; **enable** the tunnel.
- [ ] **Pass:** the Status card reads **connected** within ~10 seconds, and `ps | grep "ssh -N"`
      on the router shows the tunnel process.
- [ ] Confirm `uci get firewall.admin_ui_wan.enabled` is still `0` — this feature must never
      flip it.
- [ ] From a network that is NOT this LAN (e.g. phone on mobile data), reach the public URL the
      relay host serves and confirm you land on the admin login page.
- [ ] **Failover survival:** fail WAN1 over to WAN2 (see §7) and confirm the tunnel reconnects on
      its own within a minute — procd respawns it regardless of which WAN currently carries
      traffic.
- [ ] **Disable it** from the page and confirm the tunnel process exits and the public URL stops
      responding.

---

## 9b. Nodes & Networks — reachability test, history, content blocking

- [ ] **Node speed test:** on Nodes & Networks, add a node that's currently online, click **Test**
      next to it. **Pass:** within ~10 seconds the cell shows an `ms` figure (green if 0% loss,
      amber if partial loss, red/"no reply" if the node didn't answer at all).
- [ ] **Recent activity:** still on that page, confirm the "Recent activity" table exists (may be
      empty on a fresh install — that's correct, it only fills in as real WAN/node transitions
      happen over time).
- [ ] **WAN history really logs:** temporarily disable WAN2 or WAN3 (Firewall/WAN page, not
      WAN1 — don't interrupt your primary uplink for this test) and wait for mwan3 to mark it
      offline, then re-enable it. **Pass:** both a "went offline" and "came online" row for that
      WAN appear in Recent activity within a minute of each event.
- [ ] **Content blocking:** on the DNS page, add a domain to the custom blocklist (e.g.
      `doubleclick.net`). **Pass:** `nslookup doubleclick.net <router LAN IP>` from a LAN client
      now returns `0.0.0.0`. Remove it again and confirm resolution returns to normal.
- [ ] **History offload (only if Remote Access/Method 1 is enabled):** check
      `crontab -l` on the router lists `history_offload.sh`; after ~30 minutes (or run it by hand:
      `sh /usr/lib/mwadmin/history_offload.sh`), confirm `~/mwadmin-history/` exists on the relay
      host with non-empty log files, and that the router's own `/etc/mwadmin/history/*.log` files
      got truncated back down afterward.

---

## 10. Access Point mode — including the rollback safety net

Do these in order. **Test 10a deliberately triggers the rollback**, which is the most important
thing to verify before you rely on it.

### 10a. Rollback protection (intentional failure)

- [ ] Switch to AP mode in the UI.
- [ ] **Do nothing.** Do not reconnect, do not confirm. Wait.

**Pass:** after 90 seconds the router restores Router mode and reboots on its own. Your multi-WAN
configuration is intact.

**If it does not roll back:** stop and investigate before proceeding. Check
`logread | grep mwadmin`. Without working rollback, a bad AP switch means a physical reset.

### 10b. Genuine AP mode switch

- [ ] Connect a LAN port of this device to a LAN port of your existing router.
- [ ] Switch to AP mode, choosing DHCP.
- [ ] Find its new address from the upstream router's DHCP lease list.
- [ ] Browse to `http://<new address>:8080` and press **Keep this configuration**.

**Pass:** the rollback bar disappears and the header badge reads **Access Point**.

### 10c. Wired bridging

- [ ] Plug a laptop into a LAN port of this device.

**Pass:** it receives an address from the **upstream** router, on the upstream subnet, and reaches
the internet. The device is a transparent bridge.

### 10d. Wireless bridging

- [ ] Connect a phone to this device's Wi-Fi.

**Pass:** it also receives an upstream address on the same subnet, and can reach other devices on
the upstream LAN directly. It is an ordinary client of the upstream network, not behind a second
NAT.

### 10e. Confirm routing really is off

- [ ] `mwan3 status` reports the service is not running.
- [ ] `/etc/init.d/firewall status` shows it stopped.
- [ ] There is no second DHCP server: `ps | grep dnsmasq` — DHCP service on `lan` is ignored.

### 10f. Switch back

- [ ] Switch to Router mode in the UI. Reconnect at your LAN address and confirm.

**Pass — this is the requirement about preserving configuration:**
- [ ] All three WAN interfaces are back with their original settings
- [ ] WAN1 still has its static IP — you did not have to retype it
- [ ] `mwan3 status` shows all three online, WAN1 carrying traffic
- [ ] The firewall is running
- [ ] LAN DHCP works again
- [ ] Port forwards and DHCP reservations survived
- [ ] Wi-Fi SSIDs and passwords survived

---

## 11. Backup and restore

- [ ] Download a backup from **System**.
- [ ] Change something noticeable (e.g. hostname).
- [ ] Restore over SSH: `sysupgrade -r <file> && reboot`
- [ ] Confirm the change was reverted.

---

## 12. Final sign-off

- [ ] Router has been up for 24 hours with no unexpected mwan3 transitions
      (`logread | grep mwan3 | grep -i 'is offline'` should be empty on a stable line)
- [ ] Free flash still above 1 MB
- [ ] Free RAM still above 50 MB
- [ ] Admin password changed from any default
- [ ] Wi-Fi passwords changed from the `CHANGEME` placeholders
- [ ] Remote admin access (direct WAN exposure) **disabled**
- [ ] Remote Access relay tunnel: either genuinely in use with Basic Auth configured on the
      relay host, or disabled — not left on with no protection beyond the router login page
- [ ] Stock partition dumps (`radio`, `config`) archived off-device
- [ ] A current config backup stored somewhere other than the router

---

## Reporting a failure

If something here does not pass, collect this before asking for help:

```bash
ubus call system board
mwan3 status
mwan3 interfaces
ip -4 addr show
ip route show table main
ip rule show
nft list ruleset | head -100
logread | tail -200
df -h /overlay
free -m
```
