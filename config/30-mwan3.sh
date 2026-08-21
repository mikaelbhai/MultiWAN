#!/bin/sh
# 30-mwan3.sh — priority failover across WAN1 > WAN2 > WAN3, with an optional
# toggle to weighted load-balance across whichever WANs are enabled instead.
# See MWAN_MODE in mwan.env.
#
# ===========================================================================
# WHY EACH HEALTH-CHECK VALUE WAS CHOSEN
# ===========================================================================
#
# Your brief: as fast as possible without false-positive switches; a rare
# unnecessary switch is preferable to a slow real one. That asymmetry drives
# every number below.
#
# The mwan3 tracker loop per interface is:
#     for each cycle:
#         ping every track_ip (count pings, timeout seconds each)
#         if >= reliability targets replied -> cycle PASS, else cycle FAIL
#         sleep interval
#     down consecutive FAIL cycles  -> interface marked offline
#     up   consecutive PASS cycles  -> interface marked online
#
# A healthy cycle costs ~interval (replies arrive in milliseconds).
# A failing cycle costs ~interval + timeout (you wait out the timeout).
#
# ---------------------------------------------------------------------------
# WAN1 — tuned aggressively, because this is the link that matters
# ---------------------------------------------------------------------------
# interval=2     Poll every 2 s. Cost is 4 ICMP packets every 2 s per uplink,
#                which is nothing. Going to 1 s roughly doubles sensitivity to
#                ordinary internet jitter for a ~2 s gain — a bad trade.
#
# timeout=2      Generous relative to a real RTT (<30 ms on a healthy line).
#                A target must be 60x slower than normal to register a miss,
#                so ordinary latency spikes cannot produce a false failure.
#
# count=1        One ping per target per cycle. Redundancy comes from having
#                FOUR targets, not from repeat-pinging one. Four independent
#                probes per cycle beat four probes at a single destination.
#
# reliability=2  Require 2 of 4 targets to answer. This is the anti-false-
#                positive mechanism. For a cycle to fail, THREE of four
#                independent anycast resolvers (Cloudflare, Google, Quad9,
#                OpenDNS — separate companies, separate networks, separate
#                transit) must all fail to answer within 2 s. When three of
#                those are simultaneously unreachable, your link genuinely is
#                down. reliability=1 would be slower to trip but would also
#                keep declaring "up" while 3/4 of the internet is unreachable.
#
# down=2         Two consecutive failed cycles. Combined with reliability=2
#                that means 6 of 8 probes across 2 separate cycles must be
#                lost. down=1 would trip on a single unlucky moment; down=3
#                costs ~4 s of extra outage for protection reliability=2
#                already provides.
#
# up=3           Deliberately SLOWER than down. This asymmetry is the point.
#                Failing over late is expensive (you are offline). Failing
#                BACK late is nearly free (traffic already flows on WAN2). A
#                flapping WAN1 that comes up for 4 s must not yank every new
#                connection back and then drop them again. Requiring 3 clean
#                cycles means WAN1 has been continuously healthy for ~6 s.
#
# RESULTING TIMING (arithmetic in docs/03-failover-expectations.md):
#     Failover WAN1 -> WAN2 : ~4 s best,  ~10 s worst
#     Failback WAN2 -> WAN1 : ~6 s best,  ~14 s worst
#
# ---------------------------------------------------------------------------
# WAN2 / WAN3 — tuned conservatively, on purpose
# ---------------------------------------------------------------------------
# interval=5, timeout=3, down=3, reliability=1.
# These are backups on 100 Mb lines. Detecting their failure quickly buys
# nothing (traffic is on WAN1 anyway) and probing them hard wastes capacity on
# the links you will need most when WAN1 fails. Slower and steadier is correct.
#
# ===========================================================================

. "$(dirname "$0")/mwan.env"

set -e
say() { echo "[mwan3] $*"; }

command -v mwan3 >/dev/null 2>&1 || {
    echo "[mwan3] FATAL: mwan3 not installed. Run 00-packages.sh first." >&2
    exit 1
}

# Start from a clean slate — leftover members/policies from the stock sample
# config will otherwise silently participate in routing decisions.
rm -f /etc/config/mwan3
touch /etc/config/mwan3

uci set mwan3.globals='globals'
uci set mwan3.globals.mmx_mask='0x3F00'
uci set mwan3.globals.rtmon_interval='5'

# --- Per-interface trackers ---------------------------------------------------
cfg_iface() {
    local name="$1" interval="$2" timeout="$3" count="$4"
    local down="$5" up="$6" rel="$7" targets="$8" enabled="$9"

    uci set mwan3.$name='interface'
    uci set mwan3.$name.enabled="$enabled"
    uci set mwan3.$name.family='ipv4'
    uci set mwan3.$name.track_method='ping'
    uci set mwan3.$name.interval="$interval"
    uci set mwan3.$name.timeout="$timeout"
    uci set mwan3.$name.count="$count"
    uci set mwan3.$name.down="$down"
    uci set mwan3.$name.up="$up"
    uci set mwan3.$name.reliability="$rel"
    uci set mwan3.$name.initial_state='online'

    uci -q delete mwan3.$name.track_ip || true
    for t in $targets; do
        uci add_list mwan3.$name.track_ip="$t"
    done

    # --- STICKY SESSION HANDLING (this is the important part) ---------------
    # Flush conntrack when a link goes DOWN, never when one comes UP.
    #
    # On DOWN: sessions carry an mwan3 mark pinning them to the dead uplink.
    # Without a flush those marks survive and client retransmissions keep being
    # steered into a black hole. Flushing forces retries to be re-evaluated and
    # land on the new active WAN, which is what makes failover feel fast.
    #
    # On UP: do NOT flush. Established sessions currently running over WAN2
    # keep their marks and stay on WAN2 until they end naturally. Only NEW
    # connections follow the restored priority back to WAN1. This is the
    # "in-progress sessions stay where they are" behaviour you asked for.
    uci -q delete mwan3.$name.flush_conntrack || true
    uci add_list mwan3.$name.flush_conntrack='ifdown'
    uci add_list mwan3.$name.flush_conntrack='disconnected'
}

# PING_SERVER, if set, rides along on every enabled WAN's track list.
EXTRA=""
[ -n "$PING_SERVER" ] && EXTRA="$PING_SERVER"

W1EN="${WAN1_ENABLED:-1}"; W2EN="${WAN2_ENABLED:-1}"; W3EN="${WAN3_ENABLED:-1}"
[ "$W1EN" = "1" ] || [ "$W2EN" = "1" ] || [ "$W3EN" = "1" ] || {
    echo "[mwan3] FATAL: all three WANs are disabled (WAN1_ENABLED/2/3 all 0)." >&2
    echo "        At least one WAN must be enabled or there is nothing to route through." >&2
    exit 1
}

cfg_iface wan1 "$W1_INTERVAL" "$W1_TIMEOUT" "$W1_COUNT" "$W1_DOWN" "$W1_UP" "$W1_RELIABILITY" "$TRACK_WAN1 $EXTRA" "$W1EN"
cfg_iface wan2 "$W2_INTERVAL" "$W2_TIMEOUT" "$W2_COUNT" "$W2_DOWN" "$W2_UP" "$W2_RELIABILITY" "$TRACK_WAN2 $EXTRA" "$W2EN"
cfg_iface wan3 "$W3_INTERVAL" "$W3_TIMEOUT" "$W3_COUNT" "$W3_DOWN" "$W3_UP" "$W3_RELIABILITY" "$TRACK_WAN3 $EXTRA" "$W3EN"

# --- Members --------------------------------------------------------------
# All three members always exist. Which WANs actually carry traffic is
# controlled by two independent knobs, both live-toggleable from the admin UI
# without ever regenerating this file:
#
#   mwan3.wanN.enabled   — is this WAN in the pool at all? (the ON/OFF toggle)
#   member metric/weight — HOW is the pool shared? (failover vs balance)
#
# A disabled interface is never tracked and never carries traffic regardless
# of its member's metric — mwan3 simply skips it. That means the live toggle
# API only ever has to flip one flag and restart mwan3; it can never drift
# from what this script would produce on a clean re-run, because it never
# touches the member/policy sections at all.
#
# failover: three DISTINCT metrics. Lower metric always wins while online, so
#           WAN1 carries everything, WAN2 only if WAN1 is down, etc.
# balance:  all three share the SAME metric. mwan3 splits new flows across
#           same-metric members in proportion to weight.
say "mode=$MWAN_MODE  wan1_enabled=$W1EN wan2_enabled=$W2EN wan3_enabled=$W3EN"

add_member() {
    local sect="$1" iface="$2" metric="$3" weight="$4"
    uci set mwan3.$sect='member'
    uci set mwan3.$sect.interface="$iface"
    uci set mwan3.$sect.metric="$metric"
    uci set mwan3.$sect.weight="$weight"
}

if [ "$MWAN_MODE" = "balance" ]; then
    add_member wan1_m1 wan1 1 "${WEIGHT_WAN1:-10}"
    add_member wan2_m2 wan2 1 "${WEIGHT_WAN2:-1}"
    add_member wan3_m3 wan3 1 "${WEIGHT_WAN3:-1}"
else
    add_member wan1_m1 wan1 1 1
    add_member wan2_m2 wan2 2 1
    add_member wan3_m3 wan3 3 1
fi

# --- Policy -------------------------------------------------------------------
# last_resort=unreachable: if every enabled uplink is down, return ICMP
# unreachable rather than silently blackholing. Clients fail immediately with
# a clear error instead of hanging until their own timeout, and your
# monitoring notices in seconds rather than minutes.
uci set mwan3.prio_failover='policy'
uci -q delete mwan3.prio_failover.use_member || true
uci add_list mwan3.prio_failover.use_member='wan1_m1'
uci add_list mwan3.prio_failover.use_member='wan2_m2'
uci add_list mwan3.prio_failover.use_member='wan3_m3'
uci set mwan3.prio_failover.last_resort='unreachable'

# --- Rules --------------------------------------------------------------------
# Rules are evaluated top to bottom; first match wins.

# 1. Traffic between local subnets must never be policy-routed out a WAN.
uci set mwan3.rule_localnets='rule'
uci set mwan3.rule_localnets.dest_ip='192.168.0.0/16'
uci set mwan3.rule_localnets.proto='all'
uci set mwan3.rule_localnets.use_policy='default'

uci set mwan3.rule_rfc1918_10='rule'
uci set mwan3.rule_rfc1918_10.dest_ip='10.0.0.0/8'
uci set mwan3.rule_rfc1918_10.proto='all'
uci set mwan3.rule_rfc1918_10.use_policy='default'

uci set mwan3.rule_rfc1918_172='rule'
uci set mwan3.rule_rfc1918_172.dest_ip='172.16.0.0/12'
uci set mwan3.rule_rfc1918_172.proto='all'
uci set mwan3.rule_rfc1918_172.use_policy='default'

# 2. HTTPS pinned sticky for 10 minutes.
#    Many services (banking, streaming DRM, some SSO) invalidate a session when
#    its source IP changes mid-flight. Stickiness keeps a client on one uplink
#    for the life of its browsing session rather than per-connection.
uci set mwan3.rule_https='rule'
uci set mwan3.rule_https.dest_ip='0.0.0.0/0'
uci set mwan3.rule_https.proto='tcp'
uci set mwan3.rule_https.dest_port='443'
uci set mwan3.rule_https.sticky='1'
uci set mwan3.rule_https.timeout='600'
uci set mwan3.rule_https.use_policy='prio_failover'

# 3. Everything else.
uci set mwan3.rule_default='rule'
uci set mwan3.rule_default.dest_ip='0.0.0.0/0'
uci set mwan3.rule_default.proto='all'
uci set mwan3.rule_default.sticky='1'
uci set mwan3.rule_default.timeout='600'
uci set mwan3.rule_default.use_policy='prio_failover'

# NOTE ON STICKY, HONESTLY: mwan3's 'sticky' flag primarily governs member
# selection within a load-balancing policy. In a strict-priority policy there is
# only ever one eligible member, so sticky does comparatively little on its own.
# The real session persistence here comes from the flush_conntrack choice above.
# The flag is set because it costs nothing and matters if you ever move two
# members to the same metric.

uci commit mwan3
say "mwan3 config written. Starting..."

/etc/init.d/mwan3 enable
/etc/init.d/mwan3 restart

say "done."
say ""
say "Verify with:"
say "  mwan3 status          # interface up/down + active policy"
say "  mwan3 interfaces      # tracker state per uplink"
say "  mwan3 policies        # which member is carrying traffic"
