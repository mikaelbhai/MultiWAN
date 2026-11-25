#!/bin/sh
# devlimit.sh — per-device INTERNET bandwidth caps.
#
# ===========================================================================
# WHAT THIS DELIBERATELY DOES NOT TOUCH: LAN-TO-LAN
# ===========================================================================
# A cap here is an *internet allowance*, not a speed limit on the device. A
# capped device still talks to every other device on this LAN at full line
# rate — NAS copies, peer-to-peer LAN file transfer, casting, local backups.
#
# That is enforced by filter priority, not by hoping. On both shaping points
# the first matching u32 filter wins, and priority 1 is always "LAN subnet to
# LAN subnet -> default (unshaped) class". The per-device rule sits at
# priority 10 and is therefore only ever reached by traffic with one end
# outside the LAN.
#
# Two things reinforce this on real hardware:
#
#   - Wired LAN-to-LAN between switch ports never reaches the CPU at all on a
#     DSA device (see docs/01 section 4 — it is switched inside the MT7530
#     fabric), so it is physically incapable of being shaped here.
#   - Wi-Fi-to-Wi-Fi and Wi-Fi-to-wired DO traverse br-lan, which is exactly
#     why the priority-1 exemption has to exist rather than being assumed.
#
# ===========================================================================
# HOW THE TWO DIRECTIONS ARE SHAPED
# ===========================================================================
#   download (internet -> device)   br-lan EGRESS, matched on dst ip
#   upload   (device -> internet)   br-lan INGRESS, which cannot be shaped
#                                   directly, so it is mirrored to an IFB
#                                   device and shaped there, matched on src ip
#
# Everything is rebuilt from scratch on every apply. A tc tree is cheap to
# construct and almost impossible to mutate correctly in place, so "tear down
# and rebuild" is both simpler and the only version that stays correct after
# a device's DHCP lease moves it to a new address.

. /usr/lib/mwadmin/common.sh

LAN_DEV="br-lan"
IFB_DEV="ifb-mwlimit"
ROOT_RATE="1000mbit"        # ceiling for the unshaped default class
DEFAULT_MINOR=99            # classid 1:99 — everything not explicitly capped

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The LAN CIDR both exemption filters are built from. Derived live rather than
# stored, so renumbering the LAN cannot silently leave the exemption pointing
# at the old subnet and start shaping local traffic.
lan_cidr() {
    local ip mask bits=0 o
    ip=$(uget network.lan.ipaddr)
    mask=$(uget_d network.lan.netmask 255.255.255.0)
    [ -z "$ip" ] && return 1
    for o in $(printf '%s' "$mask" | tr '.' ' '); do
        case "$o" in
            255) bits=$((bits+8)) ;; 254) bits=$((bits+7)) ;; 252) bits=$((bits+6)) ;;
            248) bits=$((bits+5)) ;; 240) bits=$((bits+4)) ;; 224) bits=$((bits+3)) ;;
            192) bits=$((bits+2)) ;; 128) bits=$((bits+1)) ;; 0) ;;
            *) return 1 ;;
        esac
    done
    # Network address, not the router's own host address.
    local i1 i2 i3 i4 m1 m2 m3 m4
    IFS=. read -r i1 i2 i3 i4 <<IPEOF
$ip
IPEOF
    IFS=. read -r m1 m2 m3 m4 <<MASKEOF
$mask
MASKEOF
    printf '%d.%d.%d.%d/%d' "$((i1&m1))" "$((i2&m2))" "$((i3&m3))" "$((i4&m4))" "$bits"
}

# Current address for a MAC, from the same two sources /devices uses. Keyed by
# MAC rather than IP because a lease renewal legitimately moves a device, and a
# cap that silently detaches itself from its device is worse than no cap.
ip_for_mac() {
    local target; target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    local _e _mac _ip _n _i
    while read -r _e _mac _ip _n _i; do
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return 0; }
    done < /tmp/dhcp.leases 2>/dev/null
    local _hw _flags _mask _dev
    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "$LAN_DEV" ] || continue
        case "$_flags" in 0x0|"") continue ;; esac
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return 0; }
    done < /proc/net/arp 2>/dev/null
    return 1
}

limit_sections() {
    uci show mwadmin 2>/dev/null | sed -n "s/^mwadmin\.\([a-z0-9_]*\)=devlimit$/\1/p"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
clear_all() {
    tc qdisc del dev "$LAN_DEV" root    >/dev/null 2>&1
    tc qdisc del dev "$LAN_DEV" ingress >/dev/null 2>&1
    tc qdisc del dev "$IFB_DEV" root    >/dev/null 2>&1
    ip link set "$IFB_DEV" down         >/dev/null 2>&1
    ip link del "$IFB_DEV"              >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# Build — one side of the tree.
#   $1 device   $2 "down" (match dst) | "up" (match src)   $3 LAN cidr
# ---------------------------------------------------------------------------
build_side() {
    local dev="$1" dir="$2" cidr="$3"

    # r2q is raised so HTB's derived quantum stays sane at gigabit rates;
    # without it every class add prints "quantum ... is big".
    tc qdisc add dev "$dev" root handle 1: htb default $DEFAULT_MINOR r2q 1500 >/dev/null 2>&1 || return 1
    tc class add dev "$dev" parent 1: classid 1:1 htb \
        rate "$ROOT_RATE" ceil "$ROOT_RATE" quantum 1514 >/dev/null 2>&1
    tc class add dev "$dev" parent 1:1 classid "1:$DEFAULT_MINOR" htb \
        rate "$ROOT_RATE" ceil "$ROOT_RATE" quantum 1514 >/dev/null 2>&1

    # --- THE EXEMPTION. Priority 1, tested before any per-device rule.
    # Both ends inside the LAN -> default class, never shaped.
    if [ -n "$cidr" ]; then
        tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 \
            match ip src "$cidr" match ip dst "$cidr" \
            flowid "1:$DEFAULT_MINOR" >/dev/null 2>&1
    fi

    local minor=10 sect mac enabled addr rate
    for sect in $(limit_sections); do
        enabled=$(uget_d "mwadmin.$sect.enabled" 1)
        [ "$enabled" = "1" ] || continue
        mac=$(uget "mwadmin.$sect.mac")
        [ -n "$mac" ] || continue

        case "$dir" in
            down) rate=$(uget "mwadmin.$sect.down_mbit") ;;
            up)   rate=$(uget "mwadmin.$sect.up_mbit") ;;
        esac
        # 0 or empty means "no cap in this direction" — a device can be capped
        # on download only, which is the common case.
        case "$rate" in ''|0) minor=$((minor+1)); continue ;; esac

        addr=$(ip_for_mac "$mac") || {
            log "devlimit: $mac has no current address; cap not applied this round"
            minor=$((minor+1))
            continue
        }

        tc class add dev "$dev" parent 1:1 classid "1:$minor" htb \
            rate "${rate}mbit" ceil "${rate}mbit" quantum 1514 burst 32k >/dev/null 2>&1
        # fq_codel inside the cap keeps a saturated device's own latency low
        # rather than letting it build a bufferbloat queue against its ceiling.
        tc qdisc add dev "$dev" parent "1:$minor" handle "$minor:" fq_codel >/dev/null 2>&1

        if [ "$dir" = "down" ]; then
            tc filter add dev "$dev" parent 1: protocol ip prio 10 u32 \
                match ip dst "$addr/32" flowid "1:$minor" >/dev/null 2>&1
        else
            tc filter add dev "$dev" parent 1: protocol ip prio 10 u32 \
                match ip src "$addr/32" flowid "1:$minor" >/dev/null 2>&1
        fi

        minor=$((minor+1))
    done
    return 0
}

apply_all() {
    [ -e "/sys/class/net/$LAN_DEV" ] || { log "devlimit: $LAN_DEV does not exist"; return 1; }

    clear_all

    # Nothing configured means nothing to install. Leaving the LAN with no
    # qdisc at all is strictly better than an HTB tree that caps nobody.
    local any=0 sect d u
    for sect in $(limit_sections); do
        [ "$(uget_d "mwadmin.$sect.enabled" 1)" = "1" ] || continue
        d=$(uget "mwadmin.$sect.down_mbit"); u=$(uget "mwadmin.$sect.up_mbit")
        case "${d:-0}${u:-0}" in *[1-9]*) any=1; break ;; esac
    done
    [ "$any" = "1" ] || { log "devlimit: no active caps; shaping left off"; return 0; }

    local cidr; cidr=$(lan_cidr)

    # Download side: br-lan egress.
    build_side "$LAN_DEV" down "$cidr"

    # Upload side: br-lan ingress mirrored onto an IFB device.
    if ip link add "$IFB_DEV" type ifb >/dev/null 2>&1 || [ -e "/sys/class/net/$IFB_DEV" ]; then
        ip link set "$IFB_DEV" up >/dev/null 2>&1
        tc qdisc add dev "$LAN_DEV" handle ffff: ingress >/dev/null 2>&1
        tc filter add dev "$LAN_DEV" parent ffff: protocol ip u32 \
            match u32 0 0 action mirred egress redirect dev "$IFB_DEV" >/dev/null 2>&1
        build_side "$IFB_DEV" up "$cidr"
    else
        log "devlimit: could not create $IFB_DEV; upload caps not applied"
    fi

    log "devlimit: applied (lan=$cidr)"
    return 0
}

# ---------------------------------------------------------------------------
# Status — what is configured, plus whether it is actually live in the kernel
# ---------------------------------------------------------------------------
status_json() {
    local active=0
    tc qdisc show dev "$LAN_DEV" 2>/dev/null | grep -q 'htb' && active=1

    printf '{"ok":true,%s,%s,"limits":[' \
        "$(jbool shaping_active "$active")" \
        "$(jstr lan_cidr "$(lan_cidr)")"

    local first=1 sect mac addr
    for sect in $(limit_sections); do
        [ $first -eq 0 ] && printf ','
        first=0
        mac=$(uget "mwadmin.$sect.mac")
        addr=$(ip_for_mac "$mac" 2>/dev/null)
        printf '{%s,%s,%s,%s,%s,%s,%s}' \
            "$(jstr id "$sect")" \
            "$(jstr mac "$mac")" \
            "$(jstr name "$(uget mwadmin.$sect.name)")" \
            "$(jnum down_mbit "$(uget_d mwadmin.$sect.down_mbit 0)")" \
            "$(jnum up_mbit "$(uget_d mwadmin.$sect.up_mbit 0)")" \
            "$(jbool enabled "$(uget_d mwadmin.$sect.enabled 1)")" \
            "$(jstr address "${addr:-}")"
    done
    printf ']}\n'
}

case "$1" in
    apply)  apply_all ;;
    clear)  clear_all; log "devlimit: cleared" ;;
    status) status_json ;;
    *)      echo "usage: devlimit.sh {apply|clear|status}" >&2; exit 1 ;;
esac
