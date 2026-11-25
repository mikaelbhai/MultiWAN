#!/bin/sh
# nodewatch.sh - watches the nodes listed in the panel (switches, access
# points, other routers) and records an event when one stops answering for
# about two minutes, or comes back. The website turns those events into
# alerts.
#
#   sh nodewatch.sh tick        one pass (events.sh runs it once a minute)
#
# Rules that keep it quiet:
#   * only a node that has answered since the router started can "go down";
#     a node that is simply not on this network (an old entry) never alerts
#   * it takes two failed minutes in a row to count as down
#   * ping is tried first, then the neighbour (ARP) table, so a device that
#     ignores ping but is plugged in is still seen as there

. /usr/lib/mwadmin/common.sh

NW_DIR="$MW_RUN/nodes"

nw_ip() {
    local target _e _mac _ip _n _i _hw _flags _mask _dev
    target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    while read -r _e _mac _ip _n _i; do
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return; }
    done < /tmp/dhcp.leases 2>/dev/null
    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "br-lan" ] || continue
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return; }
    done < /proc/net/arp
}

nw_present() {
    ping -c 1 -W 1 "$1" >/dev/null 2>&1 && return 0
    ping -c 1 -W 2 "$1" >/dev/null 2>&1 && return 0
    ip neigh show "$1" dev br-lan 2>/dev/null | grep -qE "REACHABLE|DELAY|PROBE" && return 0
    return 1
}

nw_history() {   # keep the panel's "line and node history" in step
    local hf="$MW_STATE/history/nodes.log"
    mkdir -p "$MW_STATE/history" 2>/dev/null
    printf '%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$hf"
    [ "$(wc -l < "$hf" 2>/dev/null)" -gt 500 ] 2>/dev/null && { tail -n 500 "$hf" > "$hf.tmp" && mv "$hf.tmp" "$hf"; }
}

nw_tick() {
    local n name mac kind ip st fails last f
    mkdir -p "$NW_DIR"
    for n in $(uci show mwadmin 2>/dev/null | sed -n 's/^mwadmin\.\([a-z0-9_]*\)=node$/\1/p'); do
        name=$(uget "mwadmin.$n.name"); mac=$(uget "mwadmin.$n.mac"); kind=$(uget_d "mwadmin.$n.kind" other)
        f="$NW_DIR/$n"
        st=$(cat "$f.state" 2>/dev/null); fails=$(cat "$f.fails" 2>/dev/null); fails=${fails:-0}
        ip=$(nw_ip "$mac")
        if [ -n "$ip" ] && nw_present "$ip"; then
            date +%s > "$f.last"; echo "$ip" > "$f.ip"; echo 0 > "$f.fails"
            if [ "$st" = "down" ]; then
                sh /usr/lib/mwadmin/events.sh add node info "Node $name ($kind) is back"
                nw_history "$mac" "$name" up
            fi
            echo up > "$f.state"
        else
            [ "$st" = "up" ] || continue          # never seen since boot: stay quiet
            fails=$((fails + 1)); echo "$fails" > "$f.fails"
            if [ "$fails" -ge 2 ]; then
                last=$(cat "$f.last" 2>/dev/null)
                sh /usr/lib/mwadmin/events.sh add node error "Node $name ($kind) went down - reason: no answer to ping or ARP for about $fails min (last seen $(date -d @"${last:-0}" '+%H:%M' 2>/dev/null), address $(cat "$f.ip" 2>/dev/null))"
                nw_history "$mac" "$name" down
                echo down > "$f.state"
            fi
        fi
    done
}

case "${0##*/}" in
    nodewatch.sh) case "$1" in tick) nw_tick ;; *) echo "usage: nodewatch.sh tick" >&2; exit 1 ;; esac ;;
esac
