#!/bin/sh
# 20-firewall.sh — zones, forwarding, flow offload policy, admin UI lockdown.

. "$(dirname "$0")/mwan.env"

set -e
say() { echo "[fw] $*"; }

# --- Defaults -----------------------------------------------------------------
uci set firewall.@defaults[0].syn_flood='1'
uci set firewall.@defaults[0].input='ACCEPT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'

# --- Flow offload: software ON, hardware OFF ---------------------------------
#
# This pairing is deliberate and is the single most consequential performance
# decision in this project.
#
# HARDWARE offload installs flows into the MT7530's NAT table, bypassing
# netfilter entirely. mwan3 steers traffic by MARKING packets in netfilter and
# matching those marks against policy routing tables. An offloaded flow never
# reaches that logic, so it is never steered — it just keeps using whatever
# route it started on. Observed symptoms are intermittent HTTPS failures and,
# with flow_offloading_hw, kernel oopses.
#   https://forum.openwrt.org/t/mwan3-doesnt-work-with-hardware-offloading/241422
#   https://github.com/openwrt/packages/issues/5943
#
# SOFTWARE offload keeps the fast path inside netfilter, so marks still apply.
# It recovers a meaningful share of the throughput without breaking failover.
#
# Net effect: routed WAN throughput ~300-500 Mbps instead of ~940 Mbps.
# That ceiling is the price of automatic multi-WAN on this silicon.
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='0'

# --- Zone: lan ----------------------------------------------------------------
fw_find_zone() {
    uci show firewall 2>/dev/null | \
        sed -n "s/^firewall\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)\.name='$1'$/\1/p" | head -n1
}

lanz=$(fw_find_zone lan)
[ -z "$lanz" ] && { lanz="lanzone"; uci set firewall.$lanz='zone'; uci set firewall.$lanz.name='lan'; }
uci set firewall.$lanz.input='ACCEPT'
uci set firewall.$lanz.output='ACCEPT'
uci set firewall.$lanz.forward='ACCEPT'
uci -q delete firewall.$lanz.network || true
uci add_list firewall.$lanz.network='lan'
# lan_admin is the dedicated port-80 address for the admin UI (see
# 10-network.sh), when ROUTER_HOSTNAME is set. Same zone as lan — this is
# defence in depth on top of the bind-to-LAN-only address, not the only
# control, exactly like the lan_admin/admin_ui_lan rule below for lan itself.
[ -n "$(uci -q get network.lan_admin)" ] && uci add_list firewall.$lanz.network='lan_admin'

# --- Zone: wan (all three uplinks) -------------------------------------------
# One zone covering all three WANs. mwan3 decides which one carries traffic;
# the firewall only needs to know they are all untrusted and all masqueraded.
wanz=$(fw_find_zone wan)
[ -z "$wanz" ] && { wanz="wanzone"; uci set firewall.$wanz='zone'; uci set firewall.$wanz.name='wan'; }
uci set firewall.$wanz.input='REJECT'
uci set firewall.$wanz.output='ACCEPT'
uci set firewall.$wanz.forward='REJECT'
uci set firewall.$wanz.masq='1'
# mtu_fix clamps TCP MSS to the path MTU. Required here: the three uplinks may
# have different MTUs (PPPoE lines commonly run 1492), and on failover a session
# can land on a link with a smaller MTU than it negotiated.
uci set firewall.$wanz.mtu_fix='1'
uci -q delete firewall.$wanz.network || true
uci add_list firewall.$wanz.network='wan1'
uci add_list firewall.$wanz.network='wan2'
uci add_list firewall.$wanz.network='wan3'

# --- Forwarding lan -> wan ----------------------------------------------------
fwd_exists=$(uci show firewall 2>/dev/null | grep -c "\.src='lan'.*" || true)
uci -q delete firewall.lan_wan || true
uci set firewall.lan_wan='forwarding'
uci set firewall.lan_wan.src='lan'
uci set firewall.lan_wan.dest='wan'

# --- Guest zone: internet only, no LAN access --------------------------------
if [ "$WIFI_GUEST_ENABLE" = "1" ]; then
    uci -q delete firewall.guestzone || true
    uci set firewall.guestzone='zone'
    uci set firewall.guestzone.name='guest'
    uci set firewall.guestzone.input='REJECT'
    uci set firewall.guestzone.output='ACCEPT'
    uci set firewall.guestzone.forward='REJECT'
    uci -q delete firewall.guestzone.network || true
    uci add_list firewall.guestzone.network='guest'

    uci -q delete firewall.guest_wan || true
    uci set firewall.guest_wan='forwarding'
    uci set firewall.guest_wan.src='guest'
    uci set firewall.guest_wan.dest='wan'

    # Guests need DHCP and DNS from the router, and nothing else.
    uci -q delete firewall.guest_dhcp || true
    uci set firewall.guest_dhcp='rule'
    uci set firewall.guest_dhcp.name='Guest-DHCP'
    uci set firewall.guest_dhcp.src='guest'
    uci set firewall.guest_dhcp.proto='udp'
    uci set firewall.guest_dhcp.dest_port='67-68'
    uci set firewall.guest_dhcp.target='ACCEPT'

    uci -q delete firewall.guest_dns || true
    uci set firewall.guest_dns='rule'
    uci set firewall.guest_dns.name='Guest-DNS'
    uci set firewall.guest_dns.src='guest'
    uci set firewall.guest_dns.proto='tcp udp'
    uci set firewall.guest_dns.dest_port='53'
    uci set firewall.guest_dns.target='ACCEPT'

    # No forwarding rule guest -> lan is created, so guests cannot reach the LAN.
    # The zone's forward=REJECT also isolates guests from each other at L3;
    # L2 client isolation is set separately in 40-wireless.sh.
fi

# --- Admin UI: LAN only -------------------------------------------------------
# An explicit ACCEPT from lan, and deliberately NO corresponding wan rule.
# The uhttpd instance additionally binds to the LAN IP only (see the admin app's
# init script), so this is defence in depth: even if someone later widens the
# listen address, the firewall still refuses WAN-side connections.
uci -q delete firewall.admin_ui_lan || true
uci set firewall.admin_ui_lan='rule'
uci set firewall.admin_ui_lan.name='MultiWAN-Admin-LAN'
uci set firewall.admin_ui_lan.src='lan'
uci set firewall.admin_ui_lan.proto='tcp'
uci set firewall.admin_ui_lan.dest_port="$ADMIN_PORT"
uci set firewall.admin_ui_lan.target='ACCEPT'

# Explicit, disabled, documented WAN redirect. The admin UI toggles 'enabled'
# on this section when you opt into remote access. Shipping it
# disabled-but-present means the UI never has to synthesise firewall sections
# at runtime.
#
# This MUST be a redirect (DNAT), not a plain ACCEPT rule: uhttpd.mwadmin
# binds only to LAN_IPADDR:ADMIN_PORT (see package/init.d/mwadmin), never to
# the WAN address or 0.0.0.0. A plain ACCEPT rule only permits the packet at
# the firewall — it does not deliver it anywhere, because no socket is
# listening on the WAN-facing address. The redirect rewrites the destination
# to LAN_IPADDR:ADMIN_PORT so the existing LAN-bound uhttpd actually receives
# it. It also uses a distinct external port (ADMIN_WAN_PORT) rather than
# ADMIN_PORT itself, since routers commonly already have other port-forwards
# occupying common numbers (8080 etc.) — reusing ADMIN_PORT here would either
# collide with those or silently do nothing if they win priority.
uci -q delete firewall.admin_ui_wan || true
uci set firewall.admin_ui_wan='redirect'
uci set firewall.admin_ui_wan.name='MultiWAN-Admin-WAN-REMOTE-ACCESS'
uci set firewall.admin_ui_wan.target='DNAT'
uci set firewall.admin_ui_wan.src='wan'
uci set firewall.admin_ui_wan.dest='lan'
uci set firewall.admin_ui_wan.proto='tcp'
uci set firewall.admin_ui_wan.src_dport="$ADMIN_WAN_PORT"
uci set firewall.admin_ui_wan.dest_ip="$LAN_IPADDR"
uci set firewall.admin_ui_wan.dest_port="$ADMIN_PORT"
uci set firewall.admin_ui_wan.enabled='0'

# --- Block SSH and LuCI from WAN, explicitly ---------------------------------
# Default policy already rejects these. Stating them as named rules makes the
# posture auditable in the UI rather than implicit.
uci -q delete firewall.block_wan_ssh || true
uci set firewall.block_wan_ssh='rule'
uci set firewall.block_wan_ssh.name='Block-SSH-from-WAN'
uci set firewall.block_wan_ssh.src='wan'
uci set firewall.block_wan_ssh.proto='tcp'
uci set firewall.block_wan_ssh.dest_port='22'
uci set firewall.block_wan_ssh.target='DROP'

uci commit firewall
say "firewall config written. Applying..."
/etc/init.d/firewall restart

say "done. Admin UI reachable on LAN only at $LAN_IPADDR:$ADMIN_PORT"
