#!/bin/sh
# allow.sh - devices that are never blocked, in any way:
#   * blocked sites and apps (block.sh)          - skipped by its rules
#   * adult / games lists and the ad blocker     - their DNS goes to a clean
#                                                  resolver with no lists
#   * "sign in to network" (guest.sh)            - counted as signed in
# Speed limits and line choices still apply: those are not blocks.
#
# Also here: /wifi/keys, the Wi-Fi passwords for the owner's main page.
#
#   allow.sh boot    write the clean resolver config (run by /etc/init.d/mwexempt)

. /usr/lib/mwadmin/common.sh

EX_F=/etc/mwadmin/exempt_devices        # mac <TAB> name
EX_DIR=/tmp/mwadmin/exempt
EX_PORT=5390
EX_NFT=/etc/nftables.d/21-mwexempt.nft

ex_macs() { cut -f1 "$EX_F" 2>/dev/null | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u; }

# A small resolver of its own, with none of the block lists, for these devices.
ex_conf() {
    mkdir -p "$EX_DIR"
    rm -f "$EX_DIR/dnsmasq.conf"
    [ -n "$(ex_macs)" ] || return 0
    local s any=0
    {
        echo "port=$EX_PORT"
        echo "interface=br-lan"
        echo "bind-dynamic"
        echo "no-resolv"
        echo "no-hosts"
        echo "cache-size=1000"
        echo "user=dnsmasq"
        echo "group=dnsmasq"
        echo "pid-file=$EX_DIR/dnsmasq.pid"
        for s in $(uci -q get dhcp.@dnsmasq[0].server); do echo "server=$s"; any=1; done
        [ $any -eq 1 ] || { echo "server=1.1.1.1"; echo "server=8.8.8.8"; }
        # local names (device names, multiwan.router) still come from the main resolver
        echo "server=/lan/127.0.0.1"
        echo "server=/router/127.0.0.1"
        echo "server=/in-addr.arpa/127.0.0.1"
        # activity tracking is not blocking: keep recording these devices too
        if [ "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = "1" ] && [ -n "$(uci -q get dhcp.@dnsmasq[0].logfacility)" ]; then
            echo "log-queries=extra"
            echo "log-facility=$(uci -q get dhcp.@dnsmasq[0].logfacility)"
        fi
    } > "$EX_DIR/dnsmasq.conf"
}

# Their DNS goes to that resolver (loaded with the firewall, so it survives reloads).
ex_nft() {
    local macs; macs=$(ex_macs | tr '\n' ',' | sed 's/,$//')
    if [ -z "$macs" ]; then rm -f "$EX_NFT"; return; fi
    {
        echo "set mw_exempt { type ether_addr; elements = { $macs }; }"
        echo "chain mw_exempt_nat {"
        echo "    type nat hook prerouting priority dstnat - 20; policy accept;"
        echo "    iifname \"br-lan\" ether saddr @mw_exempt meta l4proto { tcp, udp } th dport 53 redirect to :$EX_PORT"
        echo "}"
    } > "$EX_NFT"
}

ex_apply() {
    ex_conf
    ex_nft
    fw4 -q reload >/dev/null 2>&1
    /etc/init.d/mwexempt enable >/dev/null 2>&1
    /etc/init.d/mwexempt restart >/dev/null 2>&1
    sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/block.sh; block_apply' >/dev/null 2>&1
    sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/guest.sh; guest_apply' >/dev/null 2>&1
    # a device keeps re-using its DNS connection, which stays sent to wherever
    # it went before; forget those so the new rules apply at once
    conntrack -D -p udp --dport 53 >/dev/null 2>&1
    conntrack -D -p tcp --dport 53 >/dev/null 2>&1
}

api_exempt_get() {
    local out="" mac name first=1
    while IFS='	' read -r mac name; do
        [ -n "$mac" ] || continue
        [ $first -eq 0 ] && out="$out,"
        first=0
        out="$out{$(jstr mac "$mac"),$(jstr name "$name"),$(jstr ip "$(awk -v m="$mac" 'tolower($2) == m { print $3; exit }' /tmp/dhcp.leases 2>/dev/null)")}"
    done < "$EX_F" 2>/dev/null
    printf '{"ok":true,"devices":[%s]}\n' "$out"
}

api_exempt_add() {
    local mac name
    mac=$(bodyval mac | tr 'A-F' 'a-f'); name=$(bodyval name | tr -d '\t\r\n' | cut -c1-40)
    printf '%s' "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { json_error "Choose a device."; return; }
    mkdir -p /etc/mwadmin; touch "$EX_F"; chmod 600 "$EX_F"
    grep -q "^$mac	" "$EX_F" && { json_error "That device is already on the list."; return; }
    printf '%s\t%s\n' "$mac" "$name" >> "$EX_F"
    ex_apply
    log "never blocked: $mac ($name)"
    json_ok "$(jstr message "${name:-This device} is never blocked now. It may need a minute, or to reconnect, to forget old blocked answers.")"
}

api_exempt_del() {
    local mac; mac=$(bodyval mac | tr 'A-F' 'a-f')
    # (grep -v "fails" when nothing is left, so the move must not depend on it)
    if [ -f "$EX_F" ]; then grep -v "^$mac	" "$EX_F" > "$EX_F.new"; mv "$EX_F.new" "$EX_F"; fi
    ex_apply
    log "removed from never-blocked: $mac"
    json_ok "$(jstr message 'Removed. Blocks apply to this device again.')"
}

api_wifi_keys() {
    local out="" s first=1 enc
    for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
        [ "$(uci -q get wireless.$s.mode)" = "ap" ] || continue
        enc=$(uci -q get wireless.$s.encryption)
        [ $first -eq 0 ] && out="$out,"
        first=0
        out="$out{$(jstr ssid "$(uci -q get wireless.$s.ssid)"),$(jstr band "$(uci -q get wireless.$(uci -q get wireless.$s.device).band)"),$(jstr encryption "$enc"),$(jstr key "$(uci -q get wireless.$s.key)"),$(jbool disabled "$( { [ "$(uci -q get wireless.$s.disabled)" = "1" ] || [ "$(uci -q get wireless.$(uci -q get wireless.$s.device).disabled)" = "1" ]; } && echo 1)"),$(jbool hidden "$(uci -q get wireless.$s.hidden)")}"
    done
    printf '{"ok":true,"networks":[%s]}\n' "$out"
}

case "${0##*/}" in
    allow.sh) [ "$1" = "boot" ] && { ex_conf; ex_nft; } ;;
esac
