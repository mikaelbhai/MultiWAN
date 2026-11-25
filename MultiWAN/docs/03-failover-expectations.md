# 03 — Expected Failover Behaviour

This is the honest statement you asked for. It covers what actually happens during a WAN1
outage, how long it takes, what breaks, and why the seamless stretch goal was not built.

---

## 1. The headline

**This is fast failover. It is not seamless failover.**

Those are different things, and the difference is not a matter of tuning:

| | Fast failover (what you have) | Seamless failover (what you asked about) |
|---|---|---|
| Detection | 4–10 seconds | Instant |
| New connections | Move to WAN2 automatically | Never interrupted |
| **In-flight connections** | **Dropped** | Survive |
| Video call during outage | **Drops, must be redialled** | Continues |
| Large download in progress | **Fails** unless the client resumes | Continues |
| SSH session | **Dies** | Survives |
| Requires a VPS | No | Yes |
| Feasible on this router | **Yes** | **No** |

No configuration change moves this router from the left column to the right. The reason is
structural and is explained in section 5.

---

## 2. Why in-flight connections cannot survive

This is worth understanding, because it is not a limitation of mwan3 or of OpenWrt.

Each of your three uplinks has a different public IP address. When a LAN device opens a TCP
connection through WAN1, the router rewrites the source address to WAN1's public IP. The remote
server sees that address, and the entire connection — the TCP four-tuple, the TLS session, the
sequence numbers — is bound to it.

When WAN1 dies, that address becomes unreachable. Moving the connection to WAN2 would mean the
remote server suddenly receiving packets for an established session from a completely different
source IP. Every TCP stack on earth discards those as spoofed. The connection is already dead the
instant WAN1 fails; failover simply decides where the *next* connection goes.

The only way around this is to make both uplinks carry the same address, which requires an
aggregation endpoint outside your network — a VPS. That is section 5.

**What this means practically:** during a failover, expect to redial a call, restart a download
that does not support resume, and reconnect an SSH session. Web browsing recovers on its own
because each page load is a new connection. Anything with a retry loop — most apps, streaming
clients with adaptive buffers — recovers within seconds without you noticing much.

---

## 3. Timing arithmetic for this specific configuration

Values from [`config/30-mwan3.sh`](../config/30-mwan3.sh) — WAN1: `interval=2`, `timeout=2`,
`count=1`, `down=2`, `up=3`, `reliability=2`, four tracking targets.

### The tracker loop

```
cycle:  ping 4 targets (1 ping each, 2 s timeout)
        PASS if >= 2 targets replied, else FAIL
        sleep 2 s
2 consecutive FAIL cycles -> WAN1 marked offline
3 consecutive PASS cycles -> WAN1 marked online
```

A healthy cycle costs ~2 s (replies arrive in milliseconds, then the 2 s sleep).
A failing cycle costs ~4 s (2 s waiting out the timeout, then the 2 s sleep).

### Failover: WAN1 → WAN2

| Phase | Best case | Worst case |
|---|---|---|
| Failure occurs → next check begins | 0 s | 2 s |
| First failing cycle | 2 s | 4 s |
| Second failing cycle (`down=2` reached) | 2 s | 4 s |
| mwan3 rewrites routes and nftables rules | ~0.5 s | ~1.5 s |
| **Total** | **≈ 4.5 s** | **≈ 11.5 s** |

**Quote these as 4–10 seconds typical, up to ~12 seconds worst case.**

The best case assumes the link fails just as a check starts. The worst case assumes it fails
immediately after a successful check, so a full healthy interval is wasted before detection even
begins, and every subsequent ping burns its full timeout.

### Failback: WAN2 → WAN1

| Phase | Best case | Worst case |
|---|---|---|
| WAN1 recovers → next check begins | 0 s | 2 s |
| Three passing cycles (`up=3`) | ~6 s | ~9 s |
| Route reconfiguration | ~0.5 s | ~1.5 s |
| **Total** | **≈ 6.5 s** | **≈ 12.5 s** |

**Quote these as 6–14 seconds.**

Failback is deliberately slower than failover. That asymmetry is the anti-flapping mechanism:
failing over late costs you an outage, but failing back late costs nothing because traffic is
already flowing over WAN2. A WAN1 that comes up for four seconds and dies again must not drag
every new connection back with it.

### Total outage as a user experiences it

Add DNS and application retry behaviour on top of the numbers above:

- **Web browsing:** roughly 5–15 seconds of failed page loads, then normal.
- **Streaming video:** usually just buffers; most players hold 10–30 seconds and recover.
- **Video/voice call:** **drops.** Redial after ~10 seconds.
- **Online gaming:** **disconnects.** The session is lost.
- **File download:** fails unless the client supports HTTP range resume.
- **SSH:** **dies.** Use `mosh` if this matters to you — it is built for exactly this.

---

## 4. What could make it faster, and why it was not done

| Change | Gain | Cost | Verdict |
|---|---|---|---|
| `interval=1` | ~2 s | Doubles sensitivity to normal jitter | **Rejected** — false-positive risk |
| `down=1` | ~2–4 s | A single unlucky moment triggers a switch | **Rejected** — this is the flapping guard |
| `timeout=1` | ~1–2 s | A 1 s spike on all four targets reads as an outage | **Rejected** — too tight |
| `reliability=1` | Slightly faster | Declares "up" while 3 of 4 resolvers are unreachable | **Rejected** — wrong direction |
| `track_method=httping` | More accurate about real reachability | Higher CPU, slower checks | Rejected — ICMP to 4 anycast targets is sufficient |

You said you would tolerate a rare unnecessary switch over a slow real one, and the config already
reflects that: `interval=2`/`down=2` is aggressive for a production multi-WAN setup. Most
deployments run `interval=5`/`down=5`, which detects failure in 25–30 seconds. You are roughly
three times faster than that default.

If you want to push further after seeing real-world behaviour, change `W1_INTERVAL` to `1` in
[`config/mwan.env`](../config/mwan.env) and re-run `30-mwan3.sh`. Watch `logread | grep mwan3` for
a week. If you see no spurious transitions, keep it.

---

## 5. Seamless / bonded failover: verdict

**Not feasible on this hardware. Not implemented, as you asked — rather than half-built.**

### What it would require

Every approach needs both uplinks active simultaneously with traffic presented to the internet
under a single stable address. That means an aggregation endpoint you control on the far side —
a VPS — and an encrypted multipath tunnel between the router and it.

The three real options:

1. **MPTCP** — needs a kernel with MPTCP v1 plus a userspace proxy (`shadowsocks-rust`,
   `glorytun`) for non-MPTCP-aware applications, which is nearly all of them.
2. **Bonded VPN / OpenMPTCProuter** — purpose-built for this, and the most complete answer.
3. **SD-WAN overlay** (ZeroTier, Nebula, Netmaker) — same per-packet crypto cost.

### Why each fails here

**The arithmetic is decisive.** WireGuard — the *fastest* tunnel available on this platform —
benchmarks at **82–99 Mbit/s** on MT7621 hardware
([wg-bench](https://github.com/cyyself/wg-bench): GL-iNet MT1300 82.5, Newifi D2 93,
EdgeRouter-X 99, all OpenWrt 23.05). The MT7621's crypto engine accelerates IPsec, not
ChaCha20-Poly1305, so this is raw CPU work.

Bonding your gigabit WAN1 with a 100 Mb WAN2 through such a tunnel would produce an aggregate
capped at **under 100 Mbit/s**. You would be discarding more than 80% of WAN1's capacity,
permanently and during normal operation, to protect against occasional outages. That is a bad
trade by a wide margin.

**Flash is the second, independent blocker.** OpenMPTCProuter does not target 16 MB devices; its
image alone exceeds the 15.6 MB firmware partition before any configuration. There is no version
of this that fits.

**CPU contention is the third.** Bonding requires both uplinks active and probed continuously,
plus per-packet encryption and reordering, on an 880 MHz dual-core MIPS chip that is already the
bottleneck for plain NAT routing.

### If you genuinely need seamless failover

It needs different hardware, and I would be glad to scope that separately:

- **Router:** x86 mini-PC (N100-class) or MT7986/Filogic with ≥256 MB flash and AES-NI or an
  equivalent crypto engine.
- **Endpoint:** a VPS with bandwidth at least equal to your combined uplinks.
- **Software:** OpenMPTCProuter, or glorytun-udp with a hand-rolled setup.
- **Ongoing cost:** VPS hosting, plus all your traffic transiting a third party.
- **Realistic result:** true session survival across an uplink failure.

That is a different project. This router cannot be it.

---

## 6. What you actually get, stated plainly

**Delivered:**

- Automatic priority failover across three uplinks, WAN1 → WAN2 → WAN3.
- Detection in 4–10 seconds, well under a third of the usual default.
- Automatic failback to WAN1 in 6–14 seconds once it is genuinely healthy.
- Anti-flapping via asymmetric hysteresis and a 2-of-4 reliability requirement.
- Established sessions stay on their current uplink after WAN1 returns; only new connections
  follow priority back.
- DNS that does not change identity across a failover.

**Not delivered, and not deliverable on this device:**

- Zero-interruption failover. Calls drop, downloads fail, SSH dies.
- Gigabit routed throughput — mwan3 forecloses hardware offload; expect 300–500 Mbps.
- Bonded or aggregate bandwidth across uplinks.
- Sub-second detection.

**The honest summary:** if WAN1 goes down at 3pm, you notice — a call drops, a page hangs — and
by roughly ten seconds later everything you restart works normally over WAN2. When WAN1 comes
back, new connections quietly return to it while whatever is already running stays put. That is a
good outcome for this hardware. It is not invisible.

---

## Sources

- [cyyself/wg-bench — WireGuard throughput incl. MT7621 devices](https://github.com/cyyself/wg-bench)
- [OpenWrt forum — mwan3 doesn't work with hardware offloading](https://forum.openwrt.org/t/mwan3-doesnt-work-with-hardware-offloading/241422)
- [openwrt/packages issue #5943 — mwan3 flow_offloading](https://github.com/openwrt/packages/issues/5943)
- [OpenWrt forum — Slow PPPoE on MT7621 (software routing throughput)](https://forum.openwrt.org/t/slow-pppoe-on-mt7621/154688)
