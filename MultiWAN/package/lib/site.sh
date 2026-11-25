#!/bin/sh
# site.sh — site identity for this router: where it is, what each internet
# line is called, and which line gets which priority slot.
#
# A "line" is an upstream connection, identified by its gateway (IP address
# plus the gateway's MAC), NOT by the socket the cable happens to be in. That
# is what lets a name follow the line: label the fibre "Office Fibre", move
# its cable from one WAN port to another, and the label moves with it. Two
# modems that both hand out 192.168.1.1 are still told apart by MAC.
#
# Each line also remembers the best download speed ever measured on it
# (portdetect.sh's test, which already runs whenever a WAN comes up). With
# auto_slot on, priority slots are re-ordered so the fastest measured line
# carries traffic first.
#
# Sourced by api.sh for the /site endpoints; run directly by portdetect.sh
# ("site.sh after-test <iface>") once a port test finishes.

. /usr/lib/mwadmin/common.sh

SITE_WANS="wan1 wan2 wan3"

site_ensure() {
    [ -f /etc/config/mwadmin ] || touch /etc/config/mwadmin
    if [ "$(uget mwadmin.site)" != "site" ]; then
        uci set mwadmin.site='site'
        uci set mwadmin.site.auto_slot='1'
        uci commit mwadmin
    fi
}

# Layer-3 device and default gateway for a logical WAN, as netifd sees them
# (correct for PPPoE too, where the L3 device is not the physical port).
site_l3dev() {
    local d
    d=$(ubus -S call "network.interface.$1" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -z "$d" ] && d=$(uget "network.$1.device")
    printf '%s' "$d"
}

site_gateway() {
    local gw dev
    gw=$(ubus -S call "network.interface.$1" status 2>/dev/null | \
         jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null | head -n1)
    if [ -z "$gw" ]; then
        dev=$(site_l3dev "$1")
        [ -n "$dev" ] && gw=$(ip -4 route show dev "$dev" 2>/dev/null | awk '/default/{print $3; exit}')
    fi
    printf '%s' "$gw"
}

# "<gateway ip>/<gateway mac>" for the line currently plugged into this WAN,
# or nothing if the WAN is down. $2 = "probe" pings the gateway once when its
# MAC is not in the neighbour table yet; the status poll never passes it, so
# a 4-second poll never turns into a ping.
site_line_key() {
    local iface="$1" probe="$2" gw dev mac
    gw=$(site_gateway "$iface")
    [ -z "$gw" ] && return 1
    dev=$(site_l3dev "$iface")
    mac=$(ip neigh show "$gw" dev "$dev" 2>/dev/null | \
          awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}')
    if [ -z "$mac" ] && [ "$probe" = "probe" ]; then
        ping -c 1 -W 1 -I "$dev" "$gw" >/dev/null 2>&1
        mac=$(ip neigh show "$gw" dev "$dev" 2>/dev/null | \
              awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}')
    fi
    printf '%s/%s' "$gw" "$mac"
}

site_line_id() {
    printf 'line_%s' "$(printf '%s' "$1" | md5sum | cut -c1-12)"
}

# uci section id of the line on this WAN ("" if down).
site_iface_line() {
    local key
    key=$(site_line_key "$1" "$2") || return 1
    site_line_id "$key"
}

# The name given to whatever line is on this WAN right now ("" if unnamed).
site_label() {
    local id
    id=$(site_iface_line "$1") || return 0
    uget "mwadmin.$id.name"
}

# mwan3 member section for a WAN: wan1 -> wan1_m1
site_member() { printf '%s_m%s' "$1" "${1#wan}"; }

site_priority() { uget "mwan3.$(site_member "$1").metric"; }

site_portval() {
    # one field out of the last port-test result for this WAN
    local f="$MW_STATE/portdata/$1.json"
    [ -f "$MW_RUN/ports/$1.json" ] && f="$MW_RUN/ports/$1.json"
    [ -f "$f" ] || return 0
    jsonfilter -i "$f" -e "@.$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Which devices use which line, and forcing a line safely.
#
# "Use only this line" changes the routing for NEW connections. Connections
# that are already open keep their old line until they close (a phone's push
# connection, an open web page), so after forcing a line a speed test could
# still show the other line's address. Forcing therefore also resets the
# connections that are on the other line(s); apps reconnect through the
# forced line within seconds. Then it checks, within 30 s, that the forced
# line really carries traffic, and if it does not it puts everything back
# by itself.
# ---------------------------------------------------------------------------

# mwan3's connection mark for a line (its routing-table number x 256): the
# number conntrack shows as mark=256 for connections on that line.
site_line_mark() {
    local l3 t
    l3=$(site_l3dev "$1")
    [ -n "$l3" ] || return 0
    t=$(ip rule show 2>/dev/null | sed -n "s/^[0-9]*:[[:space:]]*from all iif $l3 lookup \([0-9][0-9]*\).*/\1/p" | head -n1)
    [ -n "$t" ] && echo $((t * 256))
}

# "<mark> <devices>" for each line and "all <devices>": how many different
# LAN devices have a connection open on each line right now. A device with
# connections on both lines counts on both; everything behind another router
# (the Google Wifi) counts as one. Cached for 8 s.
site_devices_by_line() {
    local f="$MW_RUN/line_devices" lan _k ts
    if [ -s "$f" ]; then
        read -r _k ts < "$f"
        if [ $(( $(date +%s) - ${ts:-0} )) -lt 8 ]; then tail -n +2 "$f"; return; fi
    fi
    lan=$(uci -q get network.lan.ipaddr); lan="${lan%%/*}"
    {
        echo "ts $(date +%s)"
        awk -v lan="$lan" '
            BEGIN { n = split(lan, o, "."); pre = o[1] "." o[2] "." o[3] "." }
            $3 == "tcp" || $3 == "udp" || $3 == "icmp" {
                src = ""; mark = 0
                for (i = 1; i <= NF; i++) {
                    if (src == "" && $i ~ /^src=/) src = substr($i, 5)
                    if ($i ~ /^mark=/) mark = substr($i, 6) + 0
                }
                if (src != lan && index(src, pre) == 1 && mark >= 256 && mark < 15872 && mark % 256 == 0) {
                    if (!((mark " " src) in s)) { s[mark " " src] = 1; c[mark]++ }
                    if (!(src in a)) { a[src] = 1; all++ }
                }
            }
            END { for (m in c) print m, c[m]; print "all", all + 0 }' /proc/net/nf_conntrack
    } > "$f.tmp" && mv "$f.tmp" "$f"
    tail -n +2 "$f"
}

# Reset the open connections on every line except $1; prints how many.
site_flush_other_lines() {
    local keep="$1" i m n=0 out c
    command -v conntrack >/dev/null 2>&1 || { echo 0; return; }
    for i in $SITE_WANS; do
        [ "$i" = "$keep" ] && continue
        m=$(site_line_mark "$i"); [ -n "$m" ] || continue
        out=$(conntrack -D -m "$m" 2>&1)
        c=$(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) flow entries have been deleted.*/\1/p')
        n=$((n + ${c:-0}))
    done
    echo "$n"
}

site_iface_state() {
    mwan3_status_cached 2>/dev/null | sed -n "s/^[[:space:]]*interface $1 is \([a-z]*\).*/\1/p" | head -n1
}

# The line the router's normal routing policy is using first right now.
site_policy_first() {
    mwan3_status_cached 2>/dev/null | awk '
        /^Current ipv4 policies/ { v4 = 1; next }
        /^Current ipv6 policies/ { v4 = 0 }
        v4 && /^prio_failover:/ { f = 1; next }
        v4 && f && /\(/ { print $1; exit }
        v4 && /^[a-z_0-9]+:$/ { f = 0 }'
}

# Put the line order back to normal and say why (event -> website alert).
site_force_revert() {
    local was i
    was=$(uget mwadmin.site.forced)
    [ -n "$was" ] || return 0
    uci -q delete mwadmin.site.forced
    for i in $SITE_WANS; do
        [ -n "$(uget "mwan3.$(site_member "$i")")" ] && uci set "mwan3.$(site_member "$i").metric=${i#wan}"
    done
    uci commit mwadmin
    uci commit mwan3
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    rm -f "$MW_RUN/force_down"
    log "forcing $was undone: $1"
    sh /usr/lib/mwadmin/events.sh add force warn "Forcing everything onto $was was switched off automatically: $1. Back to the normal line order."
}

# After forcing $1: within ~30 s the line must be online, be the one the
# policy uses, and really carry traffic (the public address seen through it
# must equal the one seen by the router's normal route). Otherwise undo.
site_verify_force() {
    local iface="$1" tries=0 why="the check did not finish" st first pinned dflt
    while [ "$tries" -lt 10 ]; do
        sleep 3; tries=$((tries + 1))
        [ "$(uget mwadmin.site.forced)" = "$iface" ] || return 0     # changed meanwhile
        st=$(site_iface_state "$iface")
        [ "$st" = "online" ] || { why="$iface is not online (${st:-unknown})"; continue; }
        first=$(site_policy_first)
        [ "$first" = "$iface" ] || { why="the router still sends traffic through ${first:-no line}, not $iface"; continue; }
        pinned=$(mwan3 use "$iface" curl -s -m 8 http://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
        [ -n "$pinned" ] || { why="$iface is up but could not reach the internet"; continue; }
        dflt=$(curl -s -m 8 http://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
        [ "$pinned" = "$dflt" ] || { why="traffic is not leaving through $iface (its public address $pinned is not the one the router uses)"; continue; }
        log "force check passed: $iface carries traffic (public address $pinned)"
        sh /usr/lib/mwadmin/events.sh add force info "Everything now goes through $iface (checked: public address $pinned)"
        return 0
    done
    site_force_revert "the check failed: $why"
}

# Called every few seconds by the watcher. If the forced line stops working,
# traffic has already moved to the next line (mwan3); if it stays down for a
# minute the forcing is switched off, so it does not snap back unannounced.
site_force_watch() {
    local forced st now since mark="$MW_RUN/force_down"
    forced=$(uget mwadmin.site.forced)
    [ -n "$forced" ] || { rm -f "$mark"; return 0; }
    st=$(site_iface_state "$forced")
    [ "$st" = "online" ] && { rm -f "$mark"; return 0; }
    now=$(date +%s)
    if [ ! -f "$mark" ]; then
        echo "$now" > "$mark"
        sh /usr/lib/mwadmin/events.sh add force warn "The forced line $forced stopped working. Traffic moved to the next line by itself."
        return 0
    fi
    since=$(cat "$mark" 2>/dev/null)
    [ $(( now - ${since:-$now} )) -ge 60 ] && site_force_revert "$forced has been down for a minute"
}

# A line whose cable is fine but which mwan3 still calls offline or disabled
# because its ROUTES never came back after the port was cycled (found
# 2026-11-25: after a port was taken down and up again, the route monitor kept
# failing with "ip route replace ... dead" and the line stayed out of use for
# 25 minutes with a working cable). A real unplug/replug normally recovers by
# itself; this covers the cases where it does not. After 60 s of that, and
# only when the line's default route is missing or flagged dead (so not when
# the provider is simply down), the interface is set up again with ifup, at
# most once every 10 minutes per line. A port switched off from the panel is
# left alone: that is on purpose.
site_selfheal() {
    local i dev l3 st f now since last r
    now=$(date +%s)
    for i in $SITE_WANS; do
        [ -n "$(uget "network.$i")" ] || continue
        dev=$(uget "network.$i.device"); [ -n "$dev" ] || continue
        f="$MW_RUN/heal.$i"
        if grep -qx "$dev" /etc/mwadmin/ports_off 2>/dev/null; then rm -f "$f"; continue; fi
        st=$(site_iface_state "$i")
        if [ "$st" = "online" ] || [ "$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)" != "1" ]; then rm -f "$f"; continue; fi
        [ -f "$f" ] || { echo "$now" > "$f"; continue; }
        since=$(cat "$f" 2>/dev/null)
        [ $(( now - ${since:-$now} )) -ge 60 ] || continue
        last=$(cat "$f.last" 2>/dev/null); last=${last:-0}
        [ $(( now - last )) -ge 600 ] || continue
        l3=$(site_l3dev "$i")
        r=$(ip -4 route show dev "$l3" 2>/dev/null | grep '^default')
        case "$r" in *dead*|"") ;; *) rm -f "$f"; continue ;; esac          # routes look fine: leave it
        echo "$now" > "$f.last"; rm -f "$f"
        log "selfheal: $i has a cable but no usable routes; setting it up again"
        sh /usr/lib/mwadmin/events.sh add info info "Line $i: the cable was connected but the line had no usable routes (mwan3 still called it ${st:-down}); the router set it up again"
        ifup "$i" >/dev/null 2>&1
    done
}

# ---------------------------------------------------------------------------
# After a port test: remember the result against the LINE, then re-slot.
# ---------------------------------------------------------------------------
site_after_test() {
    local iface="$1" key id down isp oldmax
    case "$iface" in wan1|wan2|wan3) ;; *) return 1 ;; esac
    site_ensure
    key=$(site_line_key "$iface" probe) || return 0
    id=$(site_line_id "$key")
    down=$(site_portval "$iface" down_mbps)
    isp=$(site_portval "$iface" isp)

    [ "$(uget "mwadmin.$id")" = "line" ] || uci set "mwadmin.$id=line"
    uci set "mwadmin.$id.key=$key"
    uci set "mwadmin.$id.last_iface=$iface"
    [ -n "$isp" ] && uci set "mwadmin.$id.isp=$isp"
    case "$down" in
        ''|null|*[!0-9.]*) ;;
        *)
            uci set "mwadmin.$id.last_down=$down"
            oldmax=$(uget "mwadmin.$id.max_down")
            if [ -z "$oldmax" ] || awk -v a="$down" -v b="$oldmax" 'BEGIN { exit !(a > b) }'; then
                uci set "mwadmin.$id.max_down=$down"
            fi
            ;;
    esac
    uci commit mwadmin
    site_auto_slot
}

# ---------------------------------------------------------------------------
# Speed-based slots. Only in priority-failover mode (in balance mode every
# member shares metric 1 on purpose). A line must beat the one above it by
# 20% before anything moves, so two similar lines whose measurements wobble
# do not trade places — every re-slot restarts mwan3, which is not free.
# ---------------------------------------------------------------------------
site_auto_slot() {
    [ "$(uget_d mwadmin.site.auto_slot 1)" = "1" ] || return 0
    # the owner picked a line by hand: speed results must not override it
    [ -n "$(uget mwadmin.site.forced)" ] && return 0

    local i m id sp rows="" metrics=""
    for i in $SITE_WANS; do
        m=$(site_priority "$i")
        [ -z "$m" ] && continue
        sp=0
        if id=$(site_iface_line "$i"); then
            sp=$(uget_d "mwadmin.$id.last_down" 0)
        fi
        rows="$rows$m $sp $i
"
        metrics="$metrics $m"
    done
    [ -z "$rows" ] && return 0

    # balance mode: all metrics equal -> leave alone
    [ "$(printf '%s\n' $metrics | sort -u | wc -l)" -le 1 ] && \
        [ "$(printf '%s\n' $metrics | wc -l)" -gt 1 ] && return 0

    # Is the current order already good enough?
    local need
    need=$(printf '%s' "$rows" | sort -n -k1,1 | awk '
        NR > 1 && $2 > prev * 1.2 && $2 > 0 { bad = 1 }
        { prev = $2 }
        END { print bad ? 1 : 0 }')
    [ "$need" = "1" ] || return 0

    local n=0 changed=""
    for i in $(printf '%s' "$rows" | sort -k2,2nr -k1,1n | awk '{print $3}'); do
        n=$((n + 1))
        uci set "mwan3.$(site_member "$i").metric=$n"
        changed="$changed $i=$n"
    done
    uci commit mwan3
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    log "auto slot: priorities re-ordered by measured speed:$changed"
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
api_site_get() {
    site_ensure
    local states active_list
    states=$(mwan3_iface_states)
    active_list=$(mwan3_active_ifaces)
    local active; active=$(printf '%s\n' "$active_list" | head -n1)

    local i first=1 body="" active_label="" active_max="" best_max="" active_seen="" active_isp="" active_ip="" active_geo=""
    local devmap dtot; devmap=$(site_devices_by_line); dtot=$(printf '%s\n' "$devmap" | sed -n 's/^all //p')
    for i in $SITE_WANS; do
        [ -z "$(uget "network.$i")" ] && continue
        local dev key id name maxd lastd st addr gw is_active=0 a
        dev=$(uget "network.$i.device")
        key=$(site_line_key "$i" probe) || key=""
        id=""; name=""; maxd=""; lastd=""
        if [ -n "$key" ]; then
            id=$(site_line_id "$key")
            name=$(uget "mwadmin.$id.name")
            maxd=$(uget "mwadmin.$id.max_down")
            lastd=$(uget "mwadmin.$id.last_down")
        fi
        st=$(printf '%s\n' "$states" | sed -n "s/^$i://p")
        addr=$(ip -4 -o addr show dev "$(site_l3dev "$i")" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
        gw="${key%%/*}"
        for a in $active_list; do [ "$a" = "$i" ] && is_active=1; done
        # Where this line's public IP geolocates to. Independent of the
        # location the owner types in: that one says where the box sits, this
        # one says where the ISP thinks the connection comes out.
        local geo gc gr gn
        gc=$(site_portval "$i" geo_city); gr=$(site_portval "$i" geo_region); gn=$(site_portval "$i" geo_country)
        geo="$gc"
        [ -n "$gr" ] && [ "$gr" != "$gc" ] && geo="${geo:+$geo, }$gr"
        [ -n "$gn" ] && geo="${geo:+$geo, }$gn"
        if [ "$is_active" = "1" ] && [ -z "$active_seen" ]; then
            active_seen=1
            active_label="$name"; active_max="$maxd"
            active_isp=$(site_portval "$i" isp); active_ip=$(site_portval "$i" public_ip); active_geo="$geo"
        fi
        if [ -n "$maxd" ]; then
            if [ -z "$best_max" ] || awk -v a="$maxd" -v b="$best_max" 'BEGIN { exit !(a > b) }'; then
                best_max="$maxd"
            fi
        fi

        [ $first -eq 0 ] && body="$body,"
        first=0
        local mk dc; mk=$(site_line_mark "$i"); dc=0
        [ -n "$mk" ] && dc=$(printf '%s\n' "$devmap" | sed -n "s/^$mk //p" | head -n1)
        body="$body$(printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
            "$(jstr iface "$i")" \
            "$(jstr device "$dev")" \
            "$(jstr label "$name")" \
            "$(jstr line_id "$id")" \
            "$(jbool connected "$([ -n "$key" ] && echo 1 || echo 0)")" \
            "$(jstr gateway "$gw")" \
            "$(jstr address "$addr")" \
            "$(jstr public_ip "$(site_portval "$i" public_ip)")" \
            "$(jstr isp "$(site_portval "$i" isp)")" \
            "$(jstr ip_location "$geo")" \
            "$(jnum down_mbps "$lastd")" \
            "$(jnum max_down_mbps "$maxd")" \
            "$(jnum priority "$(site_priority "$i")")" \
            "$(jstr tracker "${st:-unknown}")" \
            "$(jbool active "$is_active")" \
            "$(jnum devices "${dc:-0}")")"
    done

    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"wans":[%s]}\n' \
        "$(jnum devices_total "${dtot:-0}")" \
        "$(jstr location "$(uget mwadmin.site.location)")" \
        "$(jstr forced "$(uget mwadmin.site.forced)")" \
        "$(jbool auto_slot "$(uget_d mwadmin.site.auto_slot 1)")" \
        "$(jstr mwan_mode "$(mwan3_mode 2>/dev/null)")" \
        "$(jstr hostname "$(uget system.@system[0].hostname)")" \
        "$(jbool internet "$([ -n "$active" ] && echo 1 || echo 0)")" \
        "$(jstr active_wan "${active:-none}")" \
        "$(jstr active_label "$active_label")" \
        "$(jstr active_isp "$active_isp")" \
        "$(jstr public_ip "$active_ip")" \
        "$(jstr ip_location "$active_geo")" \
        "$(jnum active_max_down_mbps "$active_max")" \
        "$(jnum max_down_mbps "$best_max")" \
        "$body"
}

# Free text that ends up in uci and in JSON: drop control characters and the
# two quote characters rather than trying to escape them through three layers.
site_clean() {
    printf '%s' "$1" | tr -d '\000-\037"\\' | sed "s/'//g" | cut -c1-"$2"
}

api_site_set() {
    site_ensure
    local raw has_loc auto
    # "location" may legitimately be set to empty, so presence is tested on
    # the raw body rather than on the extracted value.
    case "$BODY" in *'"location"'*) has_loc=1 ;; *) has_loc=0 ;; esac
    if [ "$has_loc" = "1" ]; then
        raw=$(site_clean "$(bodyval location)" 120)
        uci set "mwadmin.site.location=$raw"
    fi
    auto=$(bodyval auto_slot)
    case "$auto" in
        1|true)  uci set mwadmin.site.auto_slot='1' ;;
        0|false) uci set mwadmin.site.auto_slot='0' ;;
    esac
    uci commit mwadmin
    case "$auto" in 1|true) ( site_auto_slot ) >/dev/null 2>&1 ;; esac
    log "site settings saved"
    json_ok "$(jstr message 'Saved.')"
}

# "Use only this line": everything goes through the chosen WAN. The other
# lines stay behind it as backup - if the chosen line dies, the next takes
# over within seconds, so the router (and this website) never loses the
# internet because of a forced line. Body: {"iface":"wan2"} or {"iface":""}
# to go back to normal (fixed order, or fastest-first when that is on).
api_site_force() {
    site_ensure
    local iface i n=1 st
    iface=$(bodyval iface)
    case "$iface" in
        wan1|wan2|wan3)
            [ -n "$(uget "mwan3.$(site_member "$iface")")" ] || { json_error "$iface is not set up on this router."; return; }
            st=$(mwan3_iface_states 2>/dev/null | sed -n "s/^$iface://p")
            [ "$st" = "online" ] || { json_error "${iface} is ${st:-down} right now, so it can't carry traffic. Pick a working line."; return; }
            uci set "mwan3.$(site_member "$iface").metric=1"
            # the rest keep their current order behind it
            for i in $(for i in $SITE_WANS; do
                           [ "$i" = "$iface" ] && continue
                           m=$(site_priority "$i"); [ -n "$m" ] && echo "$m $i"
                       done | sort -n | awk '{print $2}'); do
                n=$((n + 1)); uci set "mwan3.$(site_member "$i").metric=$n"
            done
            uci set mwadmin.site.forced="$iface"
            ;;
        ''|none|auto)
            uci -q delete mwadmin.site.forced
            for i in $SITE_WANS; do
                [ -n "$(uget "mwan3.$(site_member "$i")")" ] && uci set "mwan3.$(site_member "$i").metric=${i#wan}"
            done
            ;;
        *) json_error "Unknown line."; return ;;
    esac
    uci commit mwadmin
    uci commit mwan3
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    if [ -n "$(uget mwadmin.site.forced)" ]; then
        # Connections already open on the other line(s) would otherwise stay
        # there: reset them so every app reconnects through the forced line.
        local moved; moved=$(site_flush_other_lines "$iface")
        log "line forced: everything on $iface ($moved open connections reset)"
        sh /usr/lib/mwadmin/events.sh add force info "All traffic forced onto ${iface}; ${moved} open connections were reset so they move over" >/dev/null 2>&1
        # within ~30 s: is the line really carrying traffic? if not, undo by itself
        ( sh /usr/lib/mwadmin/site.sh verify-force "$iface" </dev/null >/dev/null 2>&1 & )
        json_ok "$(jstr message "Everything now goes through ${iface}. ${moved} open connections were reset so they move over; calls and downloads may pause for a few seconds. The router checks within 30 seconds that the line really works and switches back by itself if it does not. The other line only steps in if this one fails.")"
    else
        ( site_auto_slot ) >/dev/null 2>&1
        log "line forcing turned off"
        rm -f "$MW_RUN/force_down"
        sh /usr/lib/mwadmin/events.sh add force info "Line forcing turned off" >/dev/null 2>&1
        json_ok "$(jstr message 'Back to normal line order.')"
    fi
}

api_site_name() {
    site_ensure
    local iface name key id
    iface=$(bodyval iface)
    case "$iface" in wan1|wan2|wan3) ;; *) json_error "Unknown WAN."; return ;; esac
    name=$(site_clean "$(bodyval name)" 32)
    key=$(site_line_key "$iface" probe) || {
        json_error "Nothing is connected on ${iface} right now. Plug the line in first — a name belongs to the line, not to the port."
        return
    }
    id=$(site_line_id "$key")
    [ "$(uget "mwadmin.$id")" = "line" ] || uci set "mwadmin.$id=line"
    uci set "mwadmin.$id.key=$key"
    uci set "mwadmin.$id.last_iface=$iface"
    uci set "mwadmin.$id.name=$name"
    uci commit mwadmin
    log "line on $iface named '$name'"
    json_ok "$(jstr message 'Name saved. It follows this line to whichever port it is plugged into.')"
}

# ---------------------------------------------------------------------------
# Peak tracker ("site.sh watch", run by /etc/init.d/mwsite).
#
# The active port test tops out near this CPU's TLS speed (one encrypted
# download, measured ON the router), well below what a fast line really
# delivers to devices behind it — routed traffic never touches that
# bottleneck. So "max download" is taken from real traffic instead: the
# highest 5-second average ever seen arriving on the line.
#
# Cost when idle: one awk over /proc/net/dev every 5 s, nothing else. The
# line lookup and any flash write only happen while a WAN is actually moving
# more than 5 Mbit/s, and flash is only written when the stored record is
# beaten by more than 5%, so a busy line converges in a few writes and then
# stops writing.
# ---------------------------------------------------------------------------
site_peak() {
    local dev="$1" rate="$2" i id old plan
    for i in $SITE_WANS; do
        [ "$(uget "network.$i.device")" = "$dev" ] || [ "$dev" = "pppoe-$i" ] || continue
        id=$(site_iface_line "$i") || return 0
        # the line's plan speed (Mbps), when known: nothing real beats it by 25%
        plan=$(uget "mwadmin.$id.plan_mbps")
        [ -n "$plan" ] && awk -v a="$rate" -v p="$plan" 'BEGIN { exit !(a > p * 1.25) }' && return 0
        old=$(uget "mwadmin.$id.max_down")
        if [ -z "$old" ] || awk -v a="$rate" -v b="$old" 'BEGIN { exit !(a > b * 1.05) }'; then
            [ "$(uget "mwadmin.$id")" = "line" ] || uci set "mwadmin.$id=line"
            uci set "mwadmin.$id.max_down=$rate"
            uci set "mwadmin.$id.last_iface=$i"
            uci commit mwadmin
            log "new peak on $i: $rate Mbps (was ${old:-none})"
        fi
        return 0
    done
}

site_watch() {
    local snap="$MW_RUN/peak.snap" iv=5 dev rate tick=0
    site_ensure
    rm -f "$snap"
    while :; do
        # Rate = bytes / REAL elapsed time (the loop also runs the minute jobs
        # below, so a gap is often well over 5 s; dividing by a fixed 5 once
        # recorded 2641 Mbps on a 1 Gbps port). A reading only counts when the
        # previous window was as fast too (min of two windows), and never
        # above the port's link speed - one counter hiccup can't set a record.
        awk -v snap="$snap" '
            BEGIN {
                getline up < "/proc/uptime"; split(up, u, " "); now = u[1]
                while ((getline l < snap) > 0) {
                    split(l, a, " ")
                    if (a[1] == "@") then_t = a[2]; else { prev[a[1]] = a[2]; prate[a[1]] = a[3] }
                }
                close(snap)
                el = now - then_t
            }
            NR > 2 {
                line = $0; sub(/^ +/, "", line)
                n = index(line, ":"); d = substr(line, 1, n - 1)
                split(substr(line, n + 1), f, " "); rx = f[1]
                r = 0
                if (then_t > 0 && el >= 1 && (d in prev) && rx >= prev[d]) {
                    r = (rx - prev[d]) * 8 / el / 1000000
                    sp = 0; sf = "/sys/class/net/" d "/speed"
                    if ((getline sp < sf) > 0 && sp + 0 > 0 && r > sp * 1.02) r = 0
                    close(sf)
                    s = (r < prate[d] + 0) ? r : prate[d] + 0
                    if (s >= 5) printf "%s %.1f\n", d, s
                }
                out = out d " " rx " " r "\n"
            }
            END { printf "@ %s\n%s", now, out > snap }' /proc/net/dev | \
        while read -r dev rate; do
            site_peak "$dev" "$rate"
        done
        # a forced line that dies: say so, and drop the forcing after a minute
        site_force_watch
        # a line with a good cable that never came back after a port cycle
        site_selfheal
        # Ports switched off in the admin panel stay off (boot, network
        # reloads, the LAN-change port cycle all bring links back up).
        if [ -s /etc/mwadmin/ports_off ]; then
            for dev in $(cat /etc/mwadmin/ports_off); do
                [ -e "/sys/class/net/$dev/flags" ] || continue
                [ $(( $(cat "/sys/class/net/$dev/flags") & 1 )) -eq 1 ] && ip link set dev "$dev" down 2>/dev/null
            done
        fi
        # Once a minute: credit new traffic to (device, app). See insight.sh.
        tick=$((tick + 1))
        if [ "$tick" -ge 12 ]; then
            tick=0
            # These take 25+ s together (block.sh alone ~20 s). Run them beside
            # the loop, never inside it: the loop also watches the forced line
            # and the line speeds, and must keep its 5 s beat. One copy at a time.
            if ! kill -0 "$(cat "$MW_RUN/minute.pid" 2>/dev/null)" 2>/dev/null; then
                (
                    sh /usr/lib/mwadmin/insight.sh sample >/dev/null 2>&1
                    sh /usr/lib/mwadmin/guest.sh tick >/dev/null 2>&1
                    sh /usr/lib/mwadmin/block.sh tick >/dev/null 2>&1
                ) &
                echo $! > "$MW_RUN/minute.pid"
            fi
        fi
        sleep "$iv"
    done
}

# Run directly (not sourced): portdetect.sh calls this when a test finishes.
case "${0##*/}" in
    site.sh)
        # mwan3 helpers live in api.sh, which expects to be sourced by the CGI;
        # the one function needed here is small enough to carry.
        case "$1" in
            after-test) site_after_test "$2" ;;
            auto-slot)  site_auto_slot ;;
            verify-force) site_verify_force "$2" ;;
            watch)      site_watch ;;
        esac
        ;;
esac
