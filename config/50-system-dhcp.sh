#!/bin/sh
# 50-system-dhcp.sh — DHCP server, DNS policy, NTP, hostname, log buffer.

. "$(dirname "$0")/mwan.env"

set -e
say() { echo "[sys] $*"; }

# --- System -------------------------------------------------------------------
uci set system.@system[0].hostname='multiwan'
uci set system.@system[0].timezone='UTC'
uci set system.@system[0].zonename='UTC'

# Log buffer sized for the UI's log viewer. 128 KB in RAM is affordable with
# 128 MB installed, and gives enough history to actually see a failover event
# after the fact rather than only while watching live.
uci set system.@system[0].log_size='128'
uci set system.@system[0].conloglevel='7'

uci set system.ntp.enabled='1'
uci set system.ntp.enable_server='0'
uci -q delete system.ntp.server || true
for s in 0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org 2.openwrt.pool.ntp.org; do
    uci add_list system.ntp.server="$s"
done
uci commit system

# --- DHCP / DNS ---------------------------------------------------------------
uci set dhcp.@dnsmasq[0].domain='lan'
uci set dhcp.@dnsmasq[0].local='/lan/'
uci set dhcp.@dnsmasq[0].expandhosts='1'
uci set dhcp.@dnsmasq[0].authoritative='1'
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].localise_queries='1'

# Strip AAAA records from every answer. Neither WAN has a working IPv6 path
# and LAN's own ra/dhcpv6 are disabled below, but dnsmasq will still forward
# real AAAA answers for public sites (queried over IPv4 transport — DNS
# doesn't care) unless told not to. A client that receives one tries that
# dead IPv6 address first and stalls before falling back to IPv4; on pages
# with many parallel small fetches (YouTube thumbnails were the confirmed
# case) this reads as broken loading rather than just "a bit slow". Filtering
# AAAA here means clients only ever see A records and never attempt IPv6.
uci set dhcp.@dnsmasq[0].filter_aaaa='1'

# --- Central DNS policy — this one matters for multi-WAN ---------------------
# noresolv=1 tells dnsmasq to ignore /etc/resolv.conf entirely and use only the
# servers listed here.
#
# Why: with three uplinks, two of them DHCP, each ISP would otherwise push its
# own resolvers into resolv.conf. Resolution would then change identity on every
# failover, producing intermittent and extremely hard-to-diagnose DNS behaviour
# (some names resolving, captive-portal hijacks, inconsistent TTLs). Pinning
# resolvers centrally means DNS behaves identically no matter which WAN is live.
#
# This pairs with peerdns='0' on wan2/wan3 in 10-network.sh.
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
for d in $WAN1_DNS; do
    uci add_list dhcp.@dnsmasq[0].server="$d"
done
# Secondary resolvers on different networks, so DNS survives WAN1 being down.
uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'
uci add_list dhcp.@dnsmasq[0].server='149.112.112.112'

# --- LAN DHCP pool ------------------------------------------------------------
uci set dhcp.lan='dhcp'
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start="$LAN_DHCP_START"
uci set dhcp.lan.limit="$LAN_DHCP_LIMIT"
uci set dhcp.lan.leasetime="$LAN_DHCP_LEASE"
uci set dhcp.lan.dhcpv4='server'
uci -q delete dhcp.lan.ignore || true
# No working upstream IPv6 on either WAN — see the matching note in
# 10-network.sh. Explicitly disabling RA/DHCPv6 here (rather than just
# omitting ip6assign) stops odhcpd from advertising IPv6 by its own default
# behavior, which is to self-generate a ULA prefix the moment it sees any
# IPv6-capable LAN interface, regardless of whether ip6assign was set.
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'

# --- Guest DHCP pool ----------------------------------------------------------
if [ "$WIFI_GUEST_ENABLE" = "1" ]; then
    uci set dhcp.guest='dhcp'
    uci set dhcp.guest.interface='guest'
    uci set dhcp.guest.start='100'
    uci set dhcp.guest.limit='50'
    uci set dhcp.guest.leasetime='4h'
    uci set dhcp.guest.dhcpv4='server'
fi

# --- Never run DHCP on a WAN --------------------------------------------------
# Explicit ignore sections. If a port is later reassigned from WAN to LAN and
# back, these guarantee the router never starts handing out addresses to an ISP.
for w in wan1 wan2 wan3; do
    uci set dhcp.$w='dhcp'
    uci set dhcp.$w.interface="$w"
    uci set dhcp.$w.ignore='1'
done

# --- Friendly hostname for the admin UI, always pointing at the LAN address --
# The same idea as tplinkwifi.net: a name that survives a LAN IP change so
# "where do I browse to" doesn't depend on remembering the current subnet.
# This is a local-only dnsmasq answer, never a real registrable domain — it
# only resolves for clients that use this router as their DNS server (the
# LAN default). package/init.d/mwadmin keeps mwadmin_alias.ip in sync with
# LAN_IPADDR any time the LAN address changes after install, from any source.
if [ -n "$ROUTER_HOSTNAME" ]; then
    uci set dhcp.mwadmin_alias='domain'
    uci set dhcp.mwadmin_alias.name="$ROUTER_HOSTNAME"
    # Points at the dedicated port-80 admin address (10-network.sh's
    # lan_admin) when that exists, so the hostname needs no ":8080" — else
    # falls back to the plain LAN address.
    if [ -n "$ADMIN_ALIAS_HOST" ]; then
        uci set dhcp.mwadmin_alias.ip="${LAN_IPADDR%.*}.$ADMIN_ALIAS_HOST"
    else
        uci set dhcp.mwadmin_alias.ip="$LAN_IPADDR"
    fi
fi

uci commit dhcp
say "dhcp/dns config written. Applying..."
/etc/init.d/dnsmasq restart
/etc/init.d/system reload

say "done. LAN DHCP: ${LAN_IPADDR%.*}.$LAN_DHCP_START - ${LAN_IPADDR%.*}.$((LAN_DHCP_START + LAN_DHCP_LIMIT - 1)), lease $LAN_DHCP_LEASE"
