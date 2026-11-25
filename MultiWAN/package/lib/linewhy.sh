#!/bin/sh
# linewhy.sh - the router's own opinion on WHY an internet line is down.
#
#   sh linewhy.sh wan1|wan2|wan3     prints one plain sentence
#
# Run by events.sh the moment mwan3 marks a line offline, so the reason is
# logged with the event, uploaded to the website and shown in the alert.
# It looks at the line from the cable up, and stops at the first thing wrong:
#
#   1. the port was switched off from the admin panel (a person did it)
#   2. the line is disabled in the router's settings
#   3. no cable link (unplugged, or the device at the other end is off)
#   4. link is up but there is no address (modem gave none / provider login failed)
#   5. the modem or gateway does not answer
#   6. the gateway answers but no test server on the internet does (provider fault)
#   7. some test servers answer and some do not (flaky or filtered)
#
# Pings are bound to the line's own device (-I), so the test cannot be
# answered by the other line.

. /usr/lib/mwadmin/common.sh

lw_l3() {
    local d
    d=$(ubus -S call "network.interface.$1" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -n "$d" ] || d=$(uget "network.$1.device")
    printf '%s' "$d"
}

lw_reason() {
    local i="$1" dev l3 carrier ostate addr gw targets t ok=0 n=0
    dev=$(uget "network.$i.device")
    [ -n "$dev" ] || { echo "this line is not set up on the router"; return; }

    if grep -qx "$dev" /etc/mwadmin/ports_off 2>/dev/null; then
        echo "the port ($dev) was switched off from the admin panel"; return
    fi
    if [ "$(uget "network.$i.disabled")" = "1" ] || [ "$(uget "network.$i.auto")" = "0" ]; then
        echo "the line is switched off in the router's settings"; return
    fi
    # an administratively-down port has no readable carrier at all, so "no
    # value" counts as no link too
    carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)
    ostate=$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)
    if [ "$carrier" = "0" ] || [ -z "$carrier" ] || [ "$ostate" = "down" ] || [ "$ostate" = "lowerlayerdown" ]; then
        echo "no link on port $dev: the cable is unplugged, the modem or switch at the other end is off, or the port is switched down"; return
    fi

    l3=$(lw_l3 "$i")
    addr=$(ip -4 -o addr show dev "$l3" 2>/dev/null | awk '{print $4}' | head -n1)
    if [ -z "$addr" ]; then
        case "$(uget "network.$i.proto")" in
            dhcp)  echo "the cable is connected but the modem gave this router no address (DHCP failed)" ;;
            pppoe) echo "the cable is connected but the provider login (PPPoE) did not come up" ;;
            *)     echo "the cable is connected but the line has no address" ;;
        esac
        return
    fi

    gw=$(ubus -S call "network.interface.$i" status 2>/dev/null | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null | head -n1)
    if [ -n "$gw" ] && ! ping -c 2 -W 1 -I "$l3" "$gw" >/dev/null 2>&1; then
        echo "the cable is connected but the modem/gateway ($gw) does not answer: it is frozen, restarting, or its own link is down"; return
    fi

    targets=$(uci -q get "mwan3.$i.track_ip")
    for t in $targets; do
        n=$((n + 1))
        # "mwan3 use <line>" pins the ping to this line. A plain ping bound to the
        # port (-I) is silently re-routed by mwan3 whenever another line is forced,
        # and would report a healthy line as dead.
        if command -v mwan3 >/dev/null 2>&1; then
            mwan3 use "$i" ping -c 1 -W 2 "$t" >/dev/null 2>&1 && ok=$((ok + 1))
        else
            ping -c 1 -W 2 -I "$l3" "$t" >/dev/null 2>&1 && ok=$((ok + 1))
        fi
    done
    if [ "$n" -gt 0 ] && [ "$ok" -eq 0 ]; then
        echo "the modem answers but nothing on the internet does (0 of $n test servers): a fault on the provider's side"
    elif [ "$ok" -gt 0 ] && [ "$ok" -lt "$n" ]; then
        echo "the line is flaky: $ok of $n test servers answered when checked"
    elif [ "$ok" -gt 0 ]; then
        echo "no fault could be found: the line had already recovered when the router checked (all $n test servers answered)"
    else
        echo "the line stopped answering and the router could not narrow down why"
    fi
}

case "${0##*/}" in
    linewhy.sh)
        case "$1" in
            wan1|wan2|wan3) lw_reason "$1" ;;
            *) echo "usage: linewhy.sh wan1|wan2|wan3" >&2; exit 1 ;;
        esac ;;
esac
