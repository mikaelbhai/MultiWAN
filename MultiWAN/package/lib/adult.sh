#!/bin/sh
# adult.sh - the 18+ filter. Applies to EVERY device, including the
# "never blocked" ones: it is not part of the site blocker, which they skip.
#
#   adult.sh apply     put the current setting in place (install / boot)
#
# How:
#  * All DNS the router forwards goes to family-filter resolvers
#    (CleanBrowsing Adult Filter, OpenDNS FamilyShield as backup). They keep
#    lists of millions of adult sites up to date - far more than a list on
#    this router could hold - and answer "no such site" for them.
#    CleanBrowsing also turns on Google/Bing SafeSearch; YouTube is untouched.
#    The never-blocked devices' resolver copies the same server list, so it
#    is filtered too.
#  * A device cannot dodge it with its own DNS: every DNS request from the
#    LAN is answered by the router (no device is exempt), DNS-over-TLS is
#    refused, the public DNS-over-HTTPS services are blocked by name and by
#    address, and Firefox / iCloud Private Relay are told to fall back.
#
# Setting: uci mwadmin.adult.enabled (missing = on). The DNS servers used
# before are kept in mwadmin.adult.prev and put back when it is turned off.

. /usr/lib/mwadmin/common.sh

AD_DNS="185.228.168.10 185.228.169.11 208.67.222.123 208.67.220.123"
# answered "no such site" locally (dnsmasq server=/name/ with no address)
AD_NAMES="dns.google dns.google.com 8888.google cloudflare-dns.com one.one.one.one
dns.quad9.net dns9.quad9.net dns10.quad9.net dns11.quad9.net doh.opendns.com
dns.adguard.com dns.adguard-dns.com unfiltered.adguard-dns.com dns.nextdns.io
doh.cleanbrowsing.org doh.dns.sb dns.sb doh.mullvad.net dns.mullvad.net
dns.controld.com freedns.controld.com doh.xfinity.com doh.libredns.gr
use-application-dns.net mask.icloud.com mask-h2.icloud.com"
AD_NFT=/etc/nftables.d/22-mwadult.nft

ad_on() { [ "$(uget_d mwadmin.adult.enabled 1)" = "1" ]; }

ad_want() {
    local s n
    for s in $AD_DNS; do echo "$s"; done
    for n in $AD_NAMES; do echo "/$n/"; done
}

ad_nft() {
    if ! ad_on; then rm -f "$AD_NFT"; return; fi
    cat > "$AD_NFT" <<'EOF'
# 18+ filter (adult.sh): no device skips the router's DNS
set mw_doh4 {
    type ipv4_addr; flags interval;
    elements = { 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1, 1.1.1.2, 1.0.0.2, 1.1.1.3, 1.0.0.3,
                 9.9.9.9, 9.9.9.10, 9.9.9.11, 149.112.112.112, 149.112.112.10, 149.112.112.11,
                 208.67.222.222, 208.67.220.220, 94.140.14.14, 94.140.15.15, 94.140.14.140, 94.140.14.141,
                 185.228.168.9, 185.228.169.9, 185.228.168.168, 185.228.169.168,
                 45.90.28.0/24, 45.90.30.0/24, 76.76.2.0/24, 76.76.10.0/24, 194.242.2.0/24 }
}
chain mw_adult_nat {
    # runs after the site blocker / never-blocked redirects: catches whatever
    # DNS they did not already send to one of the router's resolvers
    type nat hook prerouting priority dstnat + 10; policy accept;
    iifname "br-lan" meta l4proto { tcp, udp } th dport 53 redirect to :53
}
chain mw_adult_fwd {
    type filter hook forward priority filter - 20; policy accept;
    iifname "br-lan" tcp dport 853 reject with tcp reset
    iifname "br-lan" udp dport 853 reject
    iifname "br-lan" ip daddr @mw_doh4 tcp dport 443 reject with tcp reset
    iifname "br-lan" ip daddr @mw_doh4 udp dport 443 reject
}
EOF
}

ad_apply() {
    local cur want s changed=0
    cur=$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' '\n')
    if ad_on; then
        want=$(ad_want)
        if [ "$cur" != "$want" ]; then
            # remember the owner's servers once (never our own list)
            if [ -z "$(uget mwadmin.adult.prev)" ]; then
                [ "$(uget mwadmin.adult)" = "adult" ] || uci set mwadmin.adult='adult'
                for s in $cur; do
                    case "$s" in /*|185.228.168.10|185.228.169.11|208.67.222.123|208.67.220.123) continue ;; esac
                    uci add_list mwadmin.adult.prev="$s"
                done
                uci set mwadmin.adult.prev_noresolv="$(uget_d dhcp.@dnsmasq[0].noresolv 0)"
                [ -z "$(uget mwadmin.adult.prev)" ] && uci add_list mwadmin.adult.prev='1.1.1.1'
                uci commit mwadmin
            fi
            uci -q delete dhcp.@dnsmasq[0].server
            for s in $want; do uci add_list dhcp.@dnsmasq[0].server="$s"; done
            changed=1
        fi
        # the ISP's own DNS is not filtered: never use it on the side
        [ "$(uget dhcp.@dnsmasq[0].noresolv)" = "1" ] || { uci set dhcp.@dnsmasq[0].noresolv='1'; changed=1; }
    else
        if printf '%s\n' "$cur" | grep -qx '185.228.168.10'; then
            uci -q delete dhcp.@dnsmasq[0].server
            for s in $(uci -q get mwadmin.adult.prev); do uci add_list dhcp.@dnsmasq[0].server="$s"; done
            [ -z "$(uci -q get dhcp.@dnsmasq[0].server)" ] && { uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'; uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'; }
            uci set dhcp.@dnsmasq[0].noresolv="$(uget_d mwadmin.adult.prev_noresolv 1)"
            uci -q delete mwadmin.adult.prev
            uci commit mwadmin
            changed=1
        fi
    fi
    ad_nft
    if [ "$changed" = "1" ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        /etc/init.d/mwexempt restart >/dev/null 2>&1
    fi
    fw4 -q reload >/dev/null 2>&1
    # devices keep re-using their DNS connection; make them start fresh
    conntrack -D -p udp --dport 53 >/dev/null 2>&1
    conntrack -D -p tcp --dport 53 >/dev/null 2>&1
    return 0
}

api_adult_get() {
    printf '{"ok":true,%s}\n' "$(jbool enabled "$(ad_on && echo 1 || echo 0)")"
}

api_adult_set() {
    local e; e=$(bodyval enabled)
    case "$e" in 1|true) e=1 ;; 0|false) e=0 ;; *) json_error "Say on or off."; return ;; esac
    [ "$(uget mwadmin.adult)" = "adult" ] || uci set mwadmin.adult='adult'
    uci set mwadmin.adult.enabled="$e"
    uci commit mwadmin
    ad_apply
    log "18+ filter $([ "$e" = 1 ] && echo on || echo off)"
    sh /usr/lib/mwadmin/events.sh add info warn "18+ filter turned $([ "$e" = 1 ] && echo on || echo off)" >/dev/null 2>&1
    json_ok "$(jstr message "18+ filter $([ "$e" = 1 ] && echo 'on, for every device' || echo off).")"
}

case "${0##*/}" in
    adult.sh) [ "$1" = "apply" ] && ad_apply ;;
esac
