#!/bin/sh
# 10-network.sh — 3 WAN interfaces + LAN bridge on DSA ports.
#
# Archer C6 v3 uses DSA, so every physical port is an independent netdev
# (wan, lan1..lan4) and the "WAN" silkscreen on the case carries no meaning.
# Roles below are pure software assignment.

. "$(dirname "$0")/mwan.env"

set -e
say() { echo "[net] $*"; }

# --- Guard against unconfigured placeholders --------------------------------
# Only the fields the chosen WAN1 proto actually uses are validated.
WAN1_PROTO="${WAN1_PROTO:-static}"
case "$WAN1_PROTO" in
    static)
        case "$WAN1_IPADDR" in
            203.0.113.*)
                echo "[net] FATAL: WAN1_IPADDR is still the documentation placeholder." >&2
                echo "       Edit config/mwan.env and set your real static IP details," >&2
                echo "       or set WAN1_PROTO=dhcp / pppoe if WAN1 is not a static line." >&2
                exit 1
                ;;
        esac
        [ -n "$WAN1_GATEWAY" ] || { echo "[net] FATAL: WAN1_GATEWAY is empty." >&2; exit 1; }
        [ -n "$WAN1_NETMASK" ] || { echo "[net] FATAL: WAN1_NETMASK is empty." >&2; exit 1; }
        ;;
    dhcp)
        : # nothing to validate — the upstream supplies everything
        ;;
    pppoe)
        [ -n "$WAN1_PPPOE_USER" ] || {
            echo "[net] FATAL: WAN1_PROTO=pppoe but WAN1_PPPOE_USER is empty." >&2; exit 1; }
        [ -n "$WAN1_PPPOE_PASS" ] || {
            echo "[net] FATAL: WAN1_PROTO=pppoe but WAN1_PPPOE_PASS is empty." >&2; exit 1; }
        ;;
    *)
        echo "[net] FATAL: WAN1_PROTO='$WAN1_PROTO' is not one of: static dhcp pppoe" >&2
        exit 1
        ;;
esac

# --- Sanity: do the named ports actually exist? ------------------------------
for p in $PORT_WAN1 $PORT_WAN2 $PORT_WAN3 $PORTS_LAN; do
    [ -e "/sys/class/net/$p" ] || {
        echo "[net] FATAL: port '$p' does not exist on this device." >&2
        echo "       Available: $(ls /sys/class/net | tr '\n' ' ')" >&2
        exit 1
    }
done

# --- Sanity: no port assigned twice ------------------------------------------
dupes=$(for p in $PORT_WAN1 $PORT_WAN2 $PORT_WAN3 $PORTS_LAN; do echo "$p"; done | sort | uniq -d)
[ -n "$dupes" ] && {
    echo "[net] FATAL: port(s) assigned to more than one role: $dupes" >&2
    exit 1
}

say "WAN1=$PORT_WAN1  WAN2=$PORT_WAN2  WAN3=$PORT_WAN3  LAN=$PORTS_LAN"

# --- Clear the stock layout ---------------------------------------------------
# The default config bridges lan1-4 and puts 'wan' on its own interface. We are
# rebuilding both, so remove the stock sections rather than trying to patch them.
uci -q delete network.wan || true
uci -q delete network.wan6 || true
uci -q delete network.wan1 || true
uci -q delete network.wan2 || true
uci -q delete network.wan3 || true

# Drop any existing br-lan device section (found by name, since the section id
# differs between releases).
brsect=$(uci show network 2>/dev/null | sed -n "s/^network\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)\.name='br-lan'$/\1/p" | head -n1)
[ -n "$brsect" ] && uci -q delete "network.$brsect" || true

# --- LAN bridge ---------------------------------------------------------------
uci set network.br_lan='device'
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports || true
for p in $PORTS_LAN; do
    uci add_list network.br_lan.ports="$p"
done
# STP off: this is a leaf network with a single bridge. Enabling it only adds
# ~30 s of forwarding delay on every port that comes up.
uci set network.br_lan.stp='0'

uci set network.lan='interface'
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$LAN_IPADDR"
uci set network.lan.netmask="$LAN_NETMASK"
# Deliberately NOT setting ip6assign. Neither WAN provides real IPv6 (no
# DHCPv6-PD, mwan3's own ipv6 policy is permanently "unreachable") — assigning
# a ULA prefix here anyway just hands LAN clients an IPv6 address that goes
# nowhere. IPv6-preferring devices (Pixels notably) try that dead address
# first, get an instant failure, and report "limited connectivity" even
# though IPv4 is completely fine — confirmed as the actual cause of exactly
# that symptom on this network. Not offering IPv6 at all is the correct fix
# when there is no working upstream v6 to back it with; see 50-system-dhcp.sh
# for the matching dhcp.lan.ra/dhcpv6 settings.

# --- Dedicated LAN alias for the admin UI on port 80 -------------------------
# LuCI already owns port 80 (wildcard-bound to 0.0.0.0, which on Linux blocks
# any other process from taking that port on any address at all). To let
# ROUTER_HOSTNAME (e.g. multiwan.router) work with no ":8080" suffix — the whole
# point of it — the admin UI gets a second, dedicated address on the same LAN
# and claims port 80 there. package/init.d/mwadmin then narrows LuCI's own
# plain-HTTP bind down to just the primary LAN address (freeing the wildcard),
# the moment it detects this alias exists — LuCI keeps working exactly as
# before on the primary address, just no longer also listening everywhere.
#
# ADMIN_ALIAS_HOST is just the last octet, combined with whatever subnet
# LAN_IPADDR is currently in — so it tracks a LAN IP change automatically
# (package/init.d/mwadmin recomputes and repoints it, same as the hostname).
# Default .254 sits above the DHCP pool documented in mwan.env (.2-.201) but
# check for a collision with any static reservation you've made by hand in
# the .202-.253 range before relying on the default.
if [ -n "$ROUTER_HOSTNAME" ]; then
    ADMIN_ALIAS_HOST="${ADMIN_ALIAS_HOST:-254}"
    say "admin UI alias: ${LAN_IPADDR%.*}.$ADMIN_ALIAS_HOST:80 (for $ROUTER_HOSTNAME)"
    uci set network.lan_admin='interface'
    uci set network.lan_admin.device='br-lan'
    uci set network.lan_admin.proto='static'
    uci set network.lan_admin.ipaddr="${LAN_IPADDR%.*}.$ADMIN_ALIAS_HOST"
    uci set network.lan_admin.netmask='255.255.255.255'
else
    uci -q delete network.lan_admin || true
fi

# --- WAN1: highest priority ---------------------------------------------------
# metric 10/20/30 orders the default routes in the main table. mwan3 does the
# real steering, but a sane metric ordering means the box still behaves
# correctly if mwan3 is ever stopped.
#
# Under pppoe the L3 interface is ppp0, not the raw port, so mwan3 and the
# firewall must track the logical interface name (wan1) rather than the device.
# Every consumer in this project already does; nothing else needs changing.
uci set network.wan1='interface'
uci set network.wan1.metric='10'

case "$WAN1_PROTO" in
    static)
        say "WAN1 proto=static  ip=$WAN1_IPADDR  gw=$WAN1_GATEWAY"
        uci set network.wan1.device="$PORT_WAN1"
        uci set network.wan1.proto='static'
        uci set network.wan1.ipaddr="$WAN1_IPADDR"
        uci set network.wan1.netmask="$WAN1_NETMASK"
        uci set network.wan1.gateway="$WAN1_GATEWAY"
        uci -q delete network.wan1.username || true
        uci -q delete network.wan1.password || true
        ;;
    dhcp)
        say "WAN1 proto=dhcp on $PORT_WAN1"
        uci set network.wan1.device="$PORT_WAN1"
        uci set network.wan1.proto='dhcp'
        uci -q delete network.wan1.ipaddr || true
        uci -q delete network.wan1.netmask || true
        uci -q delete network.wan1.gateway || true
        uci -q delete network.wan1.username || true
        uci -q delete network.wan1.password || true
        ;;
    pppoe)
        say "WAN1 proto=pppoe on $PORT_WAN1  user=$WAN1_PPPOE_USER"
        uci set network.wan1.device="$PORT_WAN1"
        uci set network.wan1.proto='pppoe'
        uci set network.wan1.username="$WAN1_PPPOE_USER"
        uci set network.wan1.password="$WAN1_PPPOE_PASS"
        [ -n "$WAN1_PPPOE_SERVICE" ] && uci set network.wan1.service="$WAN1_PPPOE_SERVICE"
        # Keep the session up and recover from a dead peer without a reboot.
        uci set network.wan1.keepalive='5 20'
        uci -q delete network.wan1.ipaddr || true
        uci -q delete network.wan1.netmask || true
        uci -q delete network.wan1.gateway || true
        ;;
esac

# DNS is pinned for every proto. peerdns 0 stops a dhcp/pppoe WAN1 from
# injecting ISP resolvers into dnsmasq mid-session.
uci set network.wan1.peerdns='0'
uci -q delete network.wan1.dns || true
for d in $WAN1_DNS; do
    uci add_list network.wan1.dns="$d"
done
# No working IPv6 upstream — see the LAN comment above. Some ISP-side gear
# (a Huawei ONT on WAN2, confirmed on this deployment) advertises real
# DHCPv6-PD/RA even though we don't want it. Without this, netifd accepts
# the delegation, odhcpd assigns the prefix to LAN, and the resulting route
# outlives every LAN-side fix (ra/dhcpv6 disabled, ip6assign removed) because
# it's a kernel route with its own expiry timer, not just config — odhcpd
# re-touches it from its own cached PIO state independent of what's asked of
# it downstream. Stopping the WAN side from ever accepting v6 in the first
# place is the only fix that actually holds.
uci set network.wan1.ipv6='0'

# --- WAN2 / WAN3: DHCP --------------------------------------------------------
# peerdns 0: we do NOT want three ISPs each injecting their own resolvers into
# dnsmasq. DNS is pinned centrally in 50-system-dhcp.sh so that name resolution
# does not silently change identity on failover.
uci set network.wan2='interface'
uci set network.wan2.device="$PORT_WAN2"
uci set network.wan2.proto='dhcp'
uci set network.wan2.metric='20'
uci set network.wan2.peerdns='0'
uci set network.wan2.ipv6='0'   # see the WAN1 comment above

uci set network.wan3='interface'
uci set network.wan3.device="$PORT_WAN3"
uci set network.wan3.proto='dhcp'
uci set network.wan3.metric='30'
uci set network.wan3.peerdns='0'
uci set network.wan3.ipv6='0'   # see the WAN1 comment above

# --- Guest network (bridge-less, wireless-only) -------------------------------
if [ "$WIFI_GUEST_ENABLE" = "1" ]; then
    uci set network.guest='interface'
    uci set network.guest.proto='static'
    uci set network.guest.device='br-guest'
    uci set network.guest.ipaddr="$GUEST_IPADDR"
    uci set network.guest.netmask="$GUEST_NETMASK"

    uci set network.br_guest='device'
    uci set network.br_guest.name='br-guest'
    uci set network.br_guest.type='bridge'
    uci set network.br_guest.bridge_empty='1'   # no wired ports; wifi joins later
fi

uci commit network
say "network config written. Applying..."

# Reload rather than restart: restart tears every interface down at once and
# will drop your SSH session if you are connected over LAN.
/etc/init.d/network reload

say "done. Verify with: ip -br addr ; ip route show table main"
