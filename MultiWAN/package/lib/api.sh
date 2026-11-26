#!/bin/sh
# api.sh — endpoint implementations for the MultiWAN admin API.
# Sourced by the CGI after authentication has already succeeded.

ALL_PORTS="wan lan1 lan2 lan3 lan4"

# ===========================================================================
# DASHBOARD / STATUS
# ===========================================================================

# Parse `mwan3 status` into structured state.
# Output format is: name:status:enabled per line.
mwan3_iface_states() {
    mwan3_status_cached | \
        sed -n 's/^[[:space:]]*interface \([a-z0-9]*\) is \([a-z]*\).*/\1:\2/p'
}

# Every member currently carrying traffic — plural, deliberately. In
# priority-failover mode this is a single interface. In balance mode it can
# be two or three at once, and reporting only the first (as this used to)
# makes the dashboard flatly wrong: it shows one WAN as idle while it is
# actually carrying half your traffic.
mwan3_active_ifaces() {
    mwan3_status_cached | awk '
        /Current ipv4 policies/ { inpol = 1; next }
        inpol && /^$/            { exit }
        inpol && /^[a-zA-Z_0-9]+:/ { pol = $1; next }
        # line_wanN policies only pin chosen devices/calls to one line; they
        # always list their own line and say nothing about what is in use
        inpol && /\(/ && pol !~ /^line_/ { gsub(/^[ \t]+/, ""); print $1 }
    '
}

# failover: three distinct metrics. balance: all three tied. Mirrors the
# same detection api_mwan_get uses, kept here too so /status doesn't have to
# make a second round trip just to know which label to show.
mwan3_mode() {
    # balance when every line that exists has the same metric (a router
    # with no WAN3 has no wan3_m3, which must not count as "different")
    local w m first="" n=0
    for w in 1 2 3; do
        m=$(uget mwan3.wan${w}_m$w.metric)
        [ -n "$m" ] || continue
        n=$((n + 1))
        [ -z "$first" ] && first="$m"
        [ "$m" = "$first" ] || { printf 'failover'; return; }
    done
    [ "$n" -gt 1 ] && printf 'balance' || printf 'failover'
}

# Site identity: location, named lines, speed-based slots (/site endpoints).
. /usr/lib/mwadmin/site.sh
# Call-quality test and per-device app usage (/quality, /apps endpoints).
. /usr/lib/mwadmin/insight.sh
# One-time "sign in to network" for new devices (/guests endpoints).
. /usr/lib/mwadmin/guest.sh
# Blocked sites with per-device access requests (/sites endpoints).
. /usr/lib/mwadmin/block.sh
# Software upgrade from the management website (/fw endpoints).
. /usr/lib/mwadmin/fw.sh
# SSH keys, services, schedule, packages, processes, restore/reset/flash, config files.
. /usr/lib/mwadmin/sysadmin.sh
# Which line carries calls / which device (/lines endpoints, mwan3 rules).
. /usr/lib/mwadmin/lines.sh
# Never-blocked devices and the Wi-Fi password view (/exempt, /wifi/keys).
. /usr/lib/mwadmin/allow.sh
. /usr/lib/mwadmin/adult.sh
# USB drives shared on the network, who may view or add files (/drives).
. /usr/lib/mwadmin/drive.sh
# Join a website with a one-time key (/connect).
. /usr/lib/mwadmin/connect.sh
# What this router can do, for a website to match itself to (/capabilities).
. /usr/lib/mwadmin/caps.sh

api_status() {
    # [a-z0-9]: the name "router2" has a digit (with [a-z] alone it read as no mode and the panel showed "Main router")
    local mode; mode=$(sh /usr/lib/mwadmin/modeswitch.sh mode | sed -n 's/.*"mode":"\([a-z0-9]*\)".*/\1/p')
    local active_list; active_list=$(mwan3_active_ifaces)
    local active; active=$(printf '%s\n' "$active_list" | head -n1)
    local mwmode; mwmode=$(mwan3_mode)
    local states; states=$(mwan3_iface_states)

    local uptime load memtotal memfree
    uptime=$(awk '{printf "%d", $1}' /proc/uptime)
    load=$(awk '{print $1}' /proc/loadavg)
    memtotal=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    memfree=$(awk '/MemAvailable/{print $2}' /proc/meminfo)

    printf '{"ok":true,'
    # The session id doubles as the CSRF token. Returning it here lets a page
    # reload restore a still-valid session without asking for the password
    # again — the cookie is HttpOnly, so the script cannot read it directly.
    printf '%s,' "$(jstr session "$SID")"
    printf '%s,' "$(jstr mode "${mode:-router}")"
    printf '%s,' "$(jstr mwan_mode "$mwmode")"
    printf '%s,' "$(jstr active_wan "${active:-none}")"
    printf '"active_wans":['
    local af=1 a
    for a in $active_list; do
        [ $af -eq 0 ] && printf ','
        af=0
        printf '"%s"' "$(json_escape "$a")"
    done
    printf '],'
    printf '%s,' "$(jnum uptime_s "$uptime")"
    printf '%s,' "$(jstr load1 "$load")"
    printf '%s,' "$(jnum mem_total_kb "$memtotal")"
    printf '%s,' "$(jnum mem_avail_kb "$memfree")"
    printf '%s,' "$(jstr hostname "$(uget system.@system[0].hostname)")"
    printf '%s,' "$(jstr openwrt "$(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")")"

    printf '"rollback":%s,' "$(sh /usr/lib/mwadmin/modeswitch.sh rollback-status)"

    # Per-WAN detail: priority, tracker state, address, link speed.
    printf '"wans":['
    local first=1 i
    for i in wan1 wan2 wan3; do
        [ -z "$(uget network.$i)" ] && continue
        [ $first -eq 0 ] && printf ','
        first=0

        local dev st addr gw metric carrier speed
        dev=$(uget "network.$i.device")
        st=$(printf '%s\n' "$states" | sed -n "s/^$i://p")
        addr=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
        gw=$(ip -4 route show dev "$dev" 2>/dev/null | awk '/default/{print $3; exit}')
        metric=$(uget "network.$i.metric")
        carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)
        speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
        case "$speed" in ''|*[!0-9]*) speed="" ;; esac

        local is_active=0 a2
        for a2 in $active_list; do [ "$a2" = "$i" ] && is_active=1; done

        printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
            "$(jstr name "$i")" \
            "$(jstr label "$(site_label "$i")")" \
            "$(jnum priority "$(site_priority "$i")")" \
            "$(jstr device "$dev")" \
            "$(jstr proto "$(uget "network.$i.proto")")" \
            "$(jstr tracker "${st:-unknown}")" \
            "$(jbool carrier "$carrier")" \
            "$(jnum link_speed_mbps "$speed")" \
            "$(jstr address "$addr")" \
            "$(jstr gateway "$gw")" \
            "$(jnum metric "$metric")" \
            "$(jbool active "$is_active")"
    done
    printf ']}\n'
}

# ===========================================================================
# WAN CONNECTION SETTINGS (static / dhcp / pppoe, per uplink)
# ===========================================================================
api_wan_get() {
    local iface; iface=$(qsval iface)
    case "$iface" in wan1|wan2|wan3) ;; *) json_error "iface must be wan1, wan2, or wan3."; return ;; esac
    [ -z "$(uget network.$iface)" ] && { json_error "$iface is not currently configured."; return; }

    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(jstr iface "$iface")" \
        "$(jstr proto "$(uget "network.$iface.proto")")" \
        "$(jstr ipaddr "$(uget "network.$iface.ipaddr")")" \
        "$(jstr netmask "$(uget "network.$iface.netmask")")" \
        "$(jstr gateway "$(uget "network.$iface.gateway")")" \
        "$(jstr dns "$(uget "network.$iface.dns")")" \
        "$(jstr pppoe_user "$(uget "network.$iface.username")")" \
        "$(jbool pppoe_has_password "$([ -n "$(uget "network.$iface.password")" ] && echo 1 || echo 0)")"
}

api_wan_set() {
    local iface proto ipaddr netmask gateway dns user pass d
    iface=$(bodyval iface); proto=$(bodyval proto)
    ipaddr=$(bodyval ipaddr); netmask=$(bodyval netmask); gateway=$(bodyval gateway); dns=$(bodyval dns)
    user=$(bodyval pppoe_user); pass=$(bodyval pppoe_password)

    case "$iface" in wan1|wan2|wan3) ;; *) json_error "iface must be wan1, wan2, or wan3."; return ;; esac
    [ -z "$(uget network.$iface)" ] && { json_error "$iface is not currently configured."; return; }

    # Every branch clears the fields the OTHER protocols use, so switching
    # from static to dhcp (or back) never leaves a stale gateway/IP sitting
    # in the config where netifd might still read it.
    case "$proto" in
        static)
            valid_ipv4 "$ipaddr"  || { json_error "Invalid IP address."; return; }
            valid_ipv4 "$netmask" || { json_error "Invalid netmask."; return; }
            valid_ipv4 "$gateway" || { json_error "Invalid gateway."; return; }
            uci set network.$iface.proto='static'
            uci set network.$iface.ipaddr="$ipaddr"
            uci set network.$iface.netmask="$netmask"
            uci set network.$iface.gateway="$gateway"
            uci set network.$iface.peerdns='0'
            uci -q delete network.$iface.dns
            for d in $dns; do
                valid_ipv4 "$d" || { json_error "Invalid DNS server: $d"; return; }
                uci add_list network.$iface.dns="$d"
            done
            uci -q delete network.$iface.username
            uci -q delete network.$iface.password
            uci -q delete network.$iface.keepalive
            ;;
        dhcp)
            uci set network.$iface.proto='dhcp'
            uci -q delete network.$iface.ipaddr
            uci -q delete network.$iface.netmask
            uci -q delete network.$iface.gateway
            uci -q delete network.$iface.username
            uci -q delete network.$iface.password
            uci -q delete network.$iface.keepalive
            if [ -n "$dns" ]; then
                # Pin DNS even over DHCP, same reasoning as at install time:
                # otherwise a failover changes which resolvers are in play.
                uci set network.$iface.peerdns='0'
                uci -q delete network.$iface.dns
                for d in $dns; do
                    valid_ipv4 "$d" || { json_error "Invalid DNS server: $d"; return; }
                    uci add_list network.$iface.dns="$d"
                done
            else
                uci set network.$iface.peerdns='1'
                uci -q delete network.$iface.dns
            fi
            ;;
        pppoe)
            [ -n "$user" ] || { json_error "PPPoE username is required."; return; }
            uci set network.$iface.proto='pppoe'
            uci set network.$iface.username="$user"
            [ -n "$pass" ] && uci set network.$iface.password="$pass"
            uci set network.$iface.keepalive='5 20'
            uci -q delete network.$iface.ipaddr
            uci -q delete network.$iface.netmask
            uci -q delete network.$iface.gateway
            uci set network.$iface.peerdns='0'
            uci -q delete network.$iface.dns
            for d in $dns; do
                valid_ipv4 "$d" || { json_error "Invalid DNS server: $d"; return; }
                uci add_list network.$iface.dns="$d"
            done
            ;;
        *) json_error "Protocol must be static, dhcp, or pppoe."; return ;;
    esac

    uci commit network
    ( sleep 1; /etc/init.d/network reload ) >/dev/null 2>&1 &
    log "$iface protocol changed to $proto"
    json_ok "$(jstr message "$iface updated to $proto. The network is reloading.")"
}

# ===========================================================================
# PORTS
# ===========================================================================
# Who is plugged in behind a port. A port with more than one device behind it
# is carrying a switch or an access point. Bridge ports (LAN sockets) are read
# from the bridge's forwarding table; routed ports (WAN1/WAN2) from the ARP
# table, which shows the neighbours on that cable, usually just the modem.
# Output is a JSON fragment: "devices":[...],"device_count":N
port_devices_json() {
    local p="$1" macs="" pn hx m ip name n=0 out=""
    if [ -d "/sys/class/net/$p/brport" ]; then
        pn=$(cat "/sys/class/net/$p/brport/port_no" 2>/dev/null)
        hx=$(printf '%02x' "$((pn))" 2>/dev/null)
        macs=$(hexdump -ve '16/1 "%02x " "\n"' /sys/class/net/br-lan/brforward 2>/dev/null | \
            awk -v want="$hx" '$8 == "00" && $7 == want { printf "%s:%s:%s:%s:%s:%s\n", $1,$2,$3,$4,$5,$6 }' | sort -u)
    else
        macs=$(ip -4 neigh show dev "$p" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ { for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i+1) }' | sort -u)
    fi
    for m in $macs; do
        ip=$(awk -v m="$m" 'tolower($2) == m { print $3; exit }' /tmp/dhcp.leases 2>/dev/null)
        name=$(awk -v m="$m" 'tolower($2) == m { print $4; exit }' /tmp/dhcp.leases 2>/dev/null)
        [ "$name" = "*" ] && name=""
        [ -z "$ip" ] && ip=$(ip -4 neigh show dev "$p" 2>/dev/null | awk -v m="$m" '$0 ~ m { print $1; exit }')
        [ -z "$ip" ] && ip=$(ip -4 neigh show 2>/dev/null | awk -v m="$m" '$0 ~ m { print $1; exit }')
        [ $n -gt 0 ] && out="$out,"
        out="$out{$(jstr mac "$m"),$(jstr ip "$ip"),$(jstr name "$name")}"
        n=$((n + 1))
    done
    printf '"devices":[%s],"device_count":%s' "$out" "$n"
}

# ---------------------------------------------------------------------------
# Port power: switch a physical socket off and on. The list of switched-off
# ports lives in flash (PORTS_OFF); site.sh's watcher re-applies it every few
# seconds, so it survives reboots and network reloads.
# Two things are refused, because both would cut off the person pressing the
# button: the socket their own connection comes in through (e.g. the Google
# Wifi on lan3 when they browse from behind it), and - for internet ports -
# the last line that still works (the website reaches the router over it).
# ---------------------------------------------------------------------------
PORTS_OFF=/etc/mwadmin/ports_off

port_is_off() { grep -qx "$1" "$PORTS_OFF" 2>/dev/null; }

# Bridge socket a MAC was last seen on ("" if none / Wi-Fi).
port_of_mac() {
    local mac="$1" p pn hx
    for p in $ALL_PORTS; do
        [ -d "/sys/class/net/$p/brport" ] || continue
        pn=$(cat "/sys/class/net/$p/brport/port_no" 2>/dev/null)
        hx=$(printf '%02x' "$((pn))" 2>/dev/null)
        hexdump -ve '16/1 "%02x " "\n"' /sys/class/net/br-lan/brforward 2>/dev/null | \
            awk -v want="$hx" -v m="$mac" '$8 == "00" && $7 == want && ($1":"$2":"$3":"$4":"$5":"$6) == m { f = 1 } END { exit !f }' && { echo "$p"; return; }
    done
}

# The socket this request came in through. Requests relayed from the
# website arrive from the router itself and have no LAN socket.
port_of_requester() {
    local ra="${REMOTE_ADDR:-}" mac lanip
    lanip=$(uget network.lan.ipaddr); lanip="${lanip%%/*}"
    case "$ra" in ''|127.0.0.1|::1|"$lanip") return ;; esac
    ra="${ra#::ffff:}"
    mac=$(ip neigh show "$ra" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print tolower($(i + 1)); exit }}')
    [ -n "$mac" ] && port_of_mac "$mac"
}

# Internet line (wanN) using this socket, if any.
port_wan_iface() {
    local i
    for i in wan1 wan2 wan3; do
        [ "$(uget "network.$i.device")" = "$1" ] && { echo "$i"; return; }
    done
}

# Why this socket may not be switched off right now ("" = it may).
port_off_block() {
    local p="$1" mine="$2" w st i others=0
    [ -n "$mine" ] && [ "$p" = "$mine" ] && { echo "You are connected through ${p} right now. Switching it off would cut you off."; return; }
    w=$(port_wan_iface "$p")
    if [ -n "$w" ]; then
        # mwan3 status takes ~1.5 s; the port list reads it once (PORT_STATES)
        st="${PORT_STATES:-$(mwan3_iface_states)}"
        for i in wan1 wan2 wan3; do
            [ "$i" = "$w" ] && continue
            printf '%s\n' "$st" | grep -qx "$i:online" && others=1
        done
        [ "$others" = "0" ] && echo "${p} carries ${w}, the only working internet line. Switching it off would take the internet (and the website) down."
    fi
}

api_ports_power() {
    local p on why w
    p=$(bodyval port); on=$(bodyval on)
    case " $ALL_PORTS " in *" $p "*) ;; *) json_error "Unknown port."; return ;; esac
    [ -e "/sys/class/net/$p" ] || { json_error "There is no $p on this router."; return; }
    case "$on" in
        0|false)
            why=$(port_off_block "$p" "$(port_of_requester)")
            [ -n "$why" ] && { json_error "$why"; return; }
            mkdir -p /etc/mwadmin
            port_is_off "$p" || echo "$p" >> "$PORTS_OFF"
            ip link set dev "$p" down
            log "port $p switched off"
            sh /usr/lib/mwadmin/events.sh add wire warn "Port $p switched off from the admin panel" >/dev/null 2>&1
            json_ok "$(jstr message "$p is off.")"
            ;;
        1|true)
            if [ -f "$PORTS_OFF" ]; then grep -vx "$p" "$PORTS_OFF" > "$PORTS_OFF.new"; mv "$PORTS_OFF.new" "$PORTS_OFF"; fi
            ip link set dev "$p" up
            # an internet port: have netifd bring its line back (DHCP / static)
            w=$(port_wan_iface "$p"); [ -n "$w" ] && ( sleep 2; ifup "$w" ) >/dev/null 2>&1 &
            log "port $p switched on"
            sh /usr/lib/mwadmin/events.sh add wire info "Port $p switched on from the admin panel" >/dev/null 2>&1
            json_ok "$(jstr message "$p is on. A device on it needs a few seconds to reconnect.")"
            ;;
        *) json_error "Say on or off."; return ;;
    esac
}

api_ports() {
    printf '{"ok":true,"ports":['
    local first=1 p mine
    mine=$(port_of_requester)
    PORT_STATES=$(mwan3_iface_states)
    for p in $ALL_PORTS; do
        [ -e "/sys/class/net/$p" ] || continue
        [ $first -eq 0 ] && printf ','
        first=0
        local link role
        link=$(sh /usr/lib/mwadmin/portdetect.sh link "$p")
        role=$(sh -c ". /usr/lib/mwadmin/portdetect.sh >/dev/null 2>&1; port_role '$p'" 2>/dev/null)
        [ -z "$role" ] && role=unassigned
        # Splice the role and the devices behind the port into the link object.
        local devs; devs=$(port_devices_json "$p")
        printf '%s,"role":"%s",%s,%s,%s,%s}' "${link%\}}" "$role" "$devs" \
            "$(jbool enabled "$(port_is_off "$p" && echo 0 || echo 1)")" \
            "$(jbool yours "$([ -n "$mine" ] && [ "$p" = "$mine" ] && echo 1 || echo 0)")" \
            "$(jstr off_blocked "$(port_is_off "$p" || port_off_block "$p" "$mine")")"
    done
    printf '],"results":{'
    first=1
    for i in wan1 wan2 wan3; do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '"%s":%s' "$i" "$(sh /usr/lib/mwadmin/portdetect.sh result "$i")"
    done
    printf '}}\n'
}

# Reassign physical ports to roles. Accepts a full desired layout so the result
# is always internally consistent — partial reassignment is how you end up with
# a port in two bridges or an interface with no device.
api_ports_assign() {
    local w1 w2 w3 lanports
    w1=$(bodyval wan1); w2=$(bodyval wan2); w3=$(bodyval wan3); lanports=$(bodyval lan)

    for p in $w1 $w2 $w3 $lanports; do
        valid_port "$p" || { json_error "Invalid port name: $p"; return; }
    done
    [ -z "$lanports" ] && { json_error "At least one LAN port is required, or you will lose access."; return; }

    local dupes
    dupes=$(for p in $w1 $w2 $w3 $lanports; do echo "$p"; done | sort | uniq -d)
    [ -n "$dupes" ] && { json_error "Port assigned to more than one role: $dupes"; return; }

    # A WAN slot left blank here, that currently HAS a device assigned, is
    # being retired back to LAN. Tear its mwan3 member/tracker and firewall
    # zone membership down completely rather than leaving them pointing at a
    # port that may now also be bridged into LAN — that combination is a
    # silent routing conflict (one physical port configured as both a WAN
    # interface and a LAN bridge member), not just leftover config.
    local i requested
    for i in wan1 wan2 wan3; do
        case "$i" in wan1) requested="$w1" ;; wan2) requested="$w2" ;; wan3) requested="$w3" ;; esac
        if [ -z "$requested" ] && [ -n "$(uget network.$i.device)" ]; then
            retire_wan_slot "$i"
        fi
    done

    # The mirror image: a WAN slot being assigned a port here that has no
    # existing network.wanN section (either never configured, or just torn
    # down by retire_wan_slot above in this very call, or in a previous one)
    # needs full provisioning — network interface, mwan3 tracker + policy
    # member, firewall zone membership, DHCP guard — not just a device
    # assignment on a section that does not exist. Only fresh/retired slots
    # go through this: a slot that already exists (the normal case — moving
    # WAN1 from one cable to another) is left exactly as it is apart from
    # its device, so its proto/static-IP/DNS configuration is never touched.
    for i in wan1 wan2 wan3; do
        case "$i" in wan1) requested="$w1" ;; wan2) requested="$w2" ;; wan3) requested="$w3" ;; esac
        if [ -n "$requested" ] && [ -z "$(uget network.$i)" ]; then
            provision_wan_slot "$i" "$requested"
        fi
    done

    [ -n "$w1" ] && uci set network.wan1.device="$w1"
    [ -n "$w2" ] && uci set network.wan2.device="$w2"
    [ -n "$w3" ] && uci set network.wan3.device="$w3"

    uci -q delete network.br_lan.ports
    for p in $lanports; do uci add_list network.br_lan.ports="$p"; done

    uci commit network
    uci commit mwan3
    uci commit firewall
    uci commit dhcp
    ( sleep 1; /etc/init.d/network reload; /etc/init.d/mwan3 restart; /etc/init.d/firewall reload ) >/dev/null 2>&1 &
    log "port roles reassigned: wan1=$w1 wan2=$w2 wan3=$w3 lan='$lanports'"
    json_ok "$(jstr message 'Port roles updated. The network is reloading.')"
}

# Fully retires a WAN slot (wan1/wan2/wan3): removes the network interface,
# its mwan3 tracker and policy member, its firewall zone membership, and its
# "never DHCP a WAN" dhcp guard. Leaves nothing pointing at the port, so it
# is genuinely free to become a plain LAN port with nothing left to conflict.
retire_wan_slot() {
    local i="$1" msect
    case "$i" in
        wan1) msect="wan1_m1" ;;
        wan2) msect="wan2_m2" ;;
        wan3) msect="wan3_m3" ;;
        *) return ;;
    esac

    uci -q delete network.$i
    uci -q delete mwan3.$i
    uci -q delete mwan3.$msect

    # Pull it out of whichever policy lists it as a member.
    local polsect remaining m
    polsect=$(uci show mwan3 2>/dev/null | \
        sed -n "s/^mwan3\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)=policy$/\1/p")
    for polsect in $polsect; do
        remaining=$(uci -q get mwan3.$polsect.use_member 2>/dev/null)
        uci -q delete mwan3.$polsect.use_member
        for m in $remaining; do
            [ "$m" = "$msect" ] && continue
            uci add_list mwan3.$polsect.use_member="$m"
        done
    done

    # Pull it out of the firewall's wan zone member list.
    local wanz fwremain n
    wanz=$(uci show firewall 2>/dev/null | \
        sed -n "s/^firewall\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)\.name='wan'$/\1/p" | head -n1)
    if [ -n "$wanz" ]; then
        fwremain=$(uci -q get firewall.$wanz.network 2>/dev/null)
        uci -q delete firewall.$wanz.network
        for n in $fwremain; do
            [ "$n" = "$i" ] && continue
            uci add_list firewall.$wanz.network="$n"
        done
    fi

    uci -q delete dhcp.$i
    log "$i retired: its port returns to the LAN pool with no leftover WAN config"
}

# The reverse of retire_wan_slot: brings a WAN slot into existence from
# nothing (a port that was previously LAN-only, or a WAN slot that was
# retired at some point). Provisions everything retire_wan_slot removes:
# the network interface, an mwan3 tracker + policy member, firewall zone
# membership, and the "never DHCP a WAN" guard.
#
# New WANs default to DHCP with conservative tracking (the same preset the
# original install gives WAN2/WAN3) rather than trying to guess a static
# configuration — this endpoint has no way to know an IP/gateway/DNS for a
# link it has never seen. If the new link genuinely needs static addressing,
# that is a WAN & failover page edit after the fact, same as it would be for
# any other WAN.
provision_wan_slot() {
    local i="$1" dev="$2" msect metric

    case "$i" in
        wan1) msect="wan1_m1"; metric=10 ;;
        wan2) msect="wan2_m2"; metric=20 ;;
        wan3) msect="wan3_m3"; metric=30 ;;
        *) return ;;
    esac

    uci set network.$i='interface'
    uci set network.$i.device="$dev"
    uci set network.$i.proto='dhcp'
    uci set network.$i.metric="$metric"
    uci set network.$i.peerdns='0'

    uci set mwan3.$i='interface'
    uci set mwan3.$i.enabled='1'
    uci set mwan3.$i.family='ipv4'
    uci set mwan3.$i.track_method='ping'
    uci set mwan3.$i.interval='5'
    uci set mwan3.$i.timeout='3'
    uci set mwan3.$i.count='1'
    uci set mwan3.$i.down='3'
    uci set mwan3.$i.up='3'
    uci set mwan3.$i.reliability='1'
    uci set mwan3.$i.initial_state='online'
    for t in 1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222; do
        uci add_list mwan3.$i.track_ip="$t"
    done
    uci add_list mwan3.$i.flush_conntrack='ifdown'
    uci add_list mwan3.$i.flush_conntrack='disconnected'

    # Match whichever mode the pool is already running: same metric as the
    # existing members if balance, next priority tier down if failover.
    local mode; mode=$(mwan3_mode)
    uci set mwan3.$msect='member'
    uci set mwan3.$msect.interface="$i"
    if [ "$mode" = "balance" ]; then
        uci set mwan3.$msect.metric='1'
        uci set mwan3.$msect.weight='1'
    else
        case "$i" in
            wan1) uci set mwan3.$msect.metric='1' ;;
            wan2) uci set mwan3.$msect.metric='2' ;;
            wan3) uci set mwan3.$msect.metric='3' ;;
        esac
        uci set mwan3.$msect.weight='1'
    fi

    # Add the new member to every policy that exists (in practice just
    # prio_failover), rather than assuming its exact name.
    local polsect
    for polsect in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)=policy$/\1/p"); do
        uci add_list mwan3.$polsect.use_member="$msect"
    done

    local wanz
    wanz=$(uci show firewall 2>/dev/null | \
        sed -n "s/^firewall\.\(@\?[a-z0-9_-]*\(\[[0-9]*\]\)\?\)\.name='wan'$/\1/p" | head -n1)
    [ -n "$wanz" ] && uci add_list firewall.$wanz.network="$i"

    uci set dhcp.$i='dhcp'
    uci set dhcp.$i.interface="$i"
    uci set dhcp.$i.ignore='1'

    log "$i provisioned on $dev: dhcp, mode=$mode, conservative tracking (interval=5s down=3 up=3)"
}

api_port_test() {
    local iface; iface=$(bodyval iface)
    valid_iface "$iface" || { json_error "Invalid interface."; return; }
    ( setsid /usr/lib/mwadmin/portdetect.sh test "$iface" >/dev/null 2>&1 & ) &
    json_ok "$(jstr message "Test started on $iface. Poll /api/ports for the result.")"
}

# ===========================================================================
# MWAN MODE (priority failover / load balance) + per-WAN enable toggle
# ===========================================================================
# See config/30-mwan3.sh for the full design note. The short version: all
# three mwan3 members always exist, in either failover metrics (1/2/3) or
# balance metrics (all 1, split by weight). A disabled WAN is skipped by
# mwan3 regardless of its metric, so these two endpoints only ever flip
# existing flags/values and restart mwan3 — they never add or remove
# sections, so live state can never drift from what the install script would
# produce on a clean run.
api_mwan_get() {
    local mode

    mode=$(mwan3_mode)

    # only lines this router has: a switch for a missing WAN3 on the Easy
    # setup page sent a toggle that failed with "uci: Invalid argument"
    local out="" w
    for w in 1 2 3; do
        [ "$(uget mwan3.wan$w)" = "interface" ] || continue
        out="$out${out:+,}{$(jstr iface wan$w),$(jbool enabled "$(uget_d mwan3.wan$w.enabled 1)"),$(jnum metric "$(uget mwan3.wan${w}_m$w.metric)"),$(jnum weight "$(uget mwan3.wan${w}_m$w.weight)")}"
    done
    printf '{"ok":true,%s,"wans":[%s]}\n' "$(jstr mode "$mode")" "$out"
}

api_mwan_mode_set() {
    local mode m w; mode=$(bodyval mode)
    case "$mode" in failover|balance) ;; *) json_error "Mode must be 'failover' or 'balance'."; return ;; esac
    # Only lines that exist: setting an option on a missing member (a router
    # with no WAN3) fails with "uci: Invalid argument" in the system log.
    for w in 1 2 3; do
        m="wan${w}_m$w"
        [ "$(uget mwan3.$m)" = "member" ] || continue
        if [ "$mode" = failover ]; then
            uci set mwan3.$m.metric="$w"
        else
            uci set mwan3.$m.metric='1'
            # Weights only matter once metrics tie. Seed sensible defaults
            # (gigabit vs 100 Mb) the first time balance mode is used; leave
            # them alone if you already customised them.
            [ -z "$(uget mwan3.$m.weight)" ] && uci set mwan3.$m.weight="$([ "$w" = 1 ] && echo 10 || echo 1)"
        fi
    done
    uci -q delete mwadmin.site.forced; uci commit mwadmin   # a mode choice ends a forced line
    uci commit mwan3
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    log "mwan3 mode changed to $mode"
    json_ok "$(jstr message "Switched to $([ "$mode" = balance ] && echo 'load balancing' || echo 'priority failover').")"
}

api_mwan_wan_toggle() {
    local iface enabled
    iface=$(bodyval iface); enabled=$(bodyval enabled)
    case "$iface" in wan1|wan2|wan3) ;; *) json_error "Only wan1, wan2, or wan3 can be toggled."; return ;; esac
    [ "$(uget mwan3.$iface)" = "interface" ] || { json_error "$(echo "$iface" | tr a-z A-Z) is not set up on this router."; return; }

    # Refuse to leave every WAN disabled. From a one-tap toggle UI this is an
    # easy accident, and the result is "no internet," not "smaller pool."
    if [ "$enabled" = "0" ]; then
        local others_on=0 i
        for i in wan1 wan2 wan3; do
            [ "$i" = "$iface" ] && continue
            [ "$(uget_d mwan3.$i.enabled 1)" = "1" ] && others_on=1
        done
        [ "$others_on" = "0" ] && { json_error "At least one WAN must stay enabled."; return; }
    fi

    uci set mwan3.$iface.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit mwan3
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    log "mwan3 $iface enabled=$enabled (via admin UI)"
    json_ok "$(jstr message "$iface $([ "$enabled" = "1" ] && echo enabled || echo disabled).")"
}

# ===========================================================================
# PROTOCOL-BASED WAN SPLIT — pin TCP and/or UDP to a specific uplink,
# independent of (and layered on top of) the failover/balance mode above.
# ===========================================================================
# mwan3's per-member metric IS the member section (mwan3.wan1_m1.metric etc.)
# — every policy that references that same member sees the same priority.
# The existing prio_failover policy, rule_https, and rule_default all share
# wan1_m1/wan2_m2/wan3_m3, so giving TCP or UDP its own independent WAN
# preference needs its own dedicated member set (named *_tcppref/*_udppref
# below), not a second use of those same three sections.
#
# Regenerates every mwan3 rule_* section from scratch on every change — same
# approach as blocklist_regenerate elsewhere in this file — so rule
# evaluation order (first match wins; local subnets, then HTTPS stickiness,
# then any protocol split, then everything else) can never silently drift
# after repeated live edits, the way hand-reordering existing uci sections
# could.
mwan_build_pref_policy() {
    local policy="$1" preferred="$2" suffix="$3" order w metric=1 mname

    uci set mwan3.$policy='policy'
    uci -q delete mwan3.$policy.use_member
    uci set mwan3.$policy.last_resort='unreachable'

    order="$preferred"
    for w in wan1 wan2 wan3; do
        [ "$w" = "$preferred" ] && continue
        order="$order $w"
    done

    for w in $order; do
        [ "$(uget mwan3.$w)" = "interface" ] || continue
        [ "$(uget_d mwan3.$w.enabled 1)" = "1" ] || continue
        mname="${w}_${suffix}"
        uci set mwan3.$mname='member'
        uci set mwan3.$mname.interface="$w"
        uci set mwan3.$mname.metric="$metric"
        uci set mwan3.$mname.weight='1'
        uci add_list mwan3.$policy.use_member="$mname"
        metric=$((metric + 1))
    done
}

mwan_rules_regenerate() {
    local udp_wan tcp_wan s
    udp_wan=$(uget_d mwadmin.mwan_protocol.udp_wan auto)
    tcp_wan=$(uget_d mwadmin.mwan_protocol.tcp_wan auto)

    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\(rule_[a-z0-9_]*\)=rule$/\1/p"); do
        uci -q delete mwan3.$s
    done
    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\([a-z0-9_]*_tcppref\)=member$/\1/p"); do
        uci -q delete mwan3.$s
    done
    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\([a-z0-9_]*_udppref\)=member$/\1/p"); do
        uci -q delete mwan3.$s
    done
    uci -q delete mwan3.policy_tcp_pref
    uci -q delete mwan3.policy_udp_pref

    uci set mwan3.rule_localnets='rule'
    uci set mwan3.rule_localnets.dest_ip='192.168.0.0/16'
    uci set mwan3.rule_localnets.proto='all'
    uci set mwan3.rule_localnets.use_policy='default'

    uci set mwan3.rule_rfc1918_10='rule'
    uci set mwan3.rule_rfc1918_10.dest_ip='10.0.0.0/8'
    uci set mwan3.rule_rfc1918_10.proto='all'
    uci set mwan3.rule_rfc1918_10.use_policy='default'

    # mwan3 skips any rule whose name is over 15 characters
    # (rule_rfc1918_172 was 16 and never applied)
    uci set mwan3.rule_rfc172='rule'
    uci set mwan3.rule_rfc172.dest_ip='172.16.0.0/12'
    uci set mwan3.rule_rfc172.proto='all'
    uci set mwan3.rule_rfc172.use_policy='default'

    # calls and per-device line choices (lines.sh), before everything else
    lines_rules

    uci set mwan3.rule_https='rule'
    uci set mwan3.rule_https.dest_ip='0.0.0.0/0'
    uci set mwan3.rule_https.proto='tcp'
    uci set mwan3.rule_https.dest_port='443'
    uci set mwan3.rule_https.sticky='1'
    uci set mwan3.rule_https.timeout='600'
    uci set mwan3.rule_https.use_policy='prio_failover'

    if [ "$tcp_wan" != "auto" ]; then
        mwan_build_pref_policy policy_tcp_pref "$tcp_wan" tcppref
        uci set mwan3.rule_tcp_split='rule'
        uci set mwan3.rule_tcp_split.dest_ip='0.0.0.0/0'
        uci set mwan3.rule_tcp_split.proto='tcp'
        uci set mwan3.rule_tcp_split.sticky='1'
        uci set mwan3.rule_tcp_split.timeout='600'
        uci set mwan3.rule_tcp_split.use_policy='policy_tcp_pref'
    fi

    if [ "$udp_wan" != "auto" ]; then
        mwan_build_pref_policy policy_udp_pref "$udp_wan" udppref
        uci set mwan3.rule_udp_split='rule'
        uci set mwan3.rule_udp_split.dest_ip='0.0.0.0/0'
        uci set mwan3.rule_udp_split.proto='udp'
        uci set mwan3.rule_udp_split.sticky='1'
        uci set mwan3.rule_udp_split.timeout='600'
        uci set mwan3.rule_udp_split.use_policy='policy_udp_pref'
    fi

    uci set mwan3.rule_default='rule'
    uci set mwan3.rule_default.dest_ip='0.0.0.0/0'
    uci set mwan3.rule_default.proto='all'
    uci set mwan3.rule_default.sticky='1'
    uci set mwan3.rule_default.timeout='600'
    uci set mwan3.rule_default.use_policy='prio_failover'

    uci commit mwan3
}

api_mwan_protocol_get() {
    printf '{"ok":true,%s,%s}\n' \
        "$(jstr udp_wan "$(uget_d mwadmin.mwan_protocol.udp_wan auto)")" \
        "$(jstr tcp_wan "$(uget_d mwadmin.mwan_protocol.tcp_wan auto)")"
}

api_mwan_protocol_set() {
    local udp_wan tcp_wan
    udp_wan=$(bodyval udp_wan); tcp_wan=$(bodyval tcp_wan)
    [ -z "$udp_wan" ] && udp_wan=auto
    [ -z "$tcp_wan" ] && tcp_wan=auto
    case "$udp_wan" in auto|wan1|wan2|wan3) ;; *) json_error "Invalid UDP WAN assignment."; return ;; esac
    case "$tcp_wan" in auto|wan1|wan2|wan3) ;; *) json_error "Invalid TCP WAN assignment."; return ;; esac

    uci set mwadmin.mwan_protocol='mwan_protocol'
    uci set mwadmin.mwan_protocol.udp_wan="$udp_wan"
    uci set mwadmin.mwan_protocol.tcp_wan="$tcp_wan"
    uci commit mwadmin

    mwan_rules_regenerate
    /etc/init.d/mwan3 restart >/dev/null 2>&1
    log "protocol WAN split: udp=$udp_wan tcp=$tcp_wan"
    json_ok "$(jstr message 'Protocol WAN assignment saved.')"
}

# ===========================================================================
# DEVICES — per-device live throughput, for the admin UI's Devices tab.
# ===========================================================================
# Byte counting comes from nlbwmon (net/nlbwmon), an existing OpenWrt package
# that already does conntrack-based per-host accounting with layer-7
# classification and persistent history — deliberately used here instead of
# a hand-rolled nftables accounting table, which would have duplicated a
# well-maintained tool for no benefit.
#
# nlbwmon itself only reports CUMULATIVE totals since its last database
# commit, not a live rate. The Mbps shown here comes from sampling that
# cumulative counter on every poll and diffing it against the previous
# sample, persisted in $MW_RUN/devrates.prev between requests — the same
# delta-over-time approach the dashboard's interface bandwidth graphs
# already use, just applied per MAC instead of per interface.
#
# rx = bytes received BY the local address = download to the device.
# tx = bytes sent BY the local address = upload from the device. This
# follows from nlbwmon's local_network setting, which is the LAN.

# One nlbw invocation for the whole request, not one per device — this
# endpoint gets polled every few seconds. Extracts each
# ["mac",conns,rx_bytes,rx_pkts,tx_bytes,tx_pkts] row with a plain regex
# rather than full JSON parsing: the shape is fixed and MACs cannot contain
# characters that would make that ambiguous.
nlbw_snapshot() {
    nlbw -c json -g mac 2>/dev/null | \
        grep -oE '\["[0-9a-fA-F:]+",[0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+\]'
}

nlbw_bytes_for_mac() {
    local target line
    target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    line=$(printf '%s\n' "$NLBW_RAW" | grep -i "\"$target\"" | head -n1)
    [ -z "$line" ] && { printf '0 0'; return; }
    printf '%s' "$line" | sed 's/^\["[^"]*",[0-9]*,\([0-9]*\),[0-9]*,\([0-9]*\),[0-9]*\]$/\1 \2/'
}

api_devices() {
    local static_ids; static_ids=$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([a-z0-9_]*\)=host$/\1/p")
    NLBW_RAW=$(nlbw_snapshot)

    # Every MAC seen live right now, from either source — this is what
    # "online" means below, independent of whether a device also happens to
    # have a reservation.
    LIVE_MACS=" "
    local _e _mac _ip _n _i
    while read -r _e _mac _ip _n _i; do
        [ -n "$_mac" ] && LIVE_MACS="$LIVE_MACS$(printf '%s' "$_mac" | tr 'A-Z' 'a-z') "
    done < /tmp/dhcp.leases 2>/dev/null
    local _flags _dev
    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "br-lan" ] || continue
        case "$_flags" in 0x0|"") continue ;; esac
        case "$_mac" in ''|00:00:00:00:00:00) continue ;; esac
        LIVE_MACS="$LIVE_MACS$(printf '%s' "$_mac" | tr 'A-Z' 'a-z') "
    done < /proc/net/arp

    NOW=$(date +%s)
    PREV_FILE="$MW_RUN/devrates.prev"
    NEW_STATE=""
    FIRST=1
    SEEN_MACS=" "

    printf '{"ok":true,"devices":['

    for s in $static_ids; do
        devices_emit "$(uget dhcp.$s.name)" "$(uget dhcp.$s.mac)" "$(uget dhcp.$s.ip)"
    done

    local _expiry _mac _ip _name _id
    while read -r _expiry _mac _ip _name _id; do
        [ -z "$_mac" ] && continue
        [ "$_name" = "*" ] && _name=""
        devices_emit "${_name:-unnamed}" "$_mac" "$_ip"
    done < /tmp/dhcp.leases 2>/dev/null

    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "br-lan" ] || continue
        case "$_flags" in 0x0|"") continue ;; esac
        case "$_mac" in ''|00:00:00:00:00:00) continue ;; esac
        devices_emit "unnamed" "$_mac" "$_ip"
    done < /proc/net/arp

    printf ']}\n'
    printf '%s' "$NEW_STATE" > "$PREV_FILE"
}

# Emits one device row, skipping duplicates by MAC (a device can legitimately
# appear in both the reservation list and the live lease/ARP data — only the
# first, most-authoritative sighting wins, which is why reservations are fed
# in before the live-only passes above).
devices_emit() {
    local name="$1" mac="$2" ip="$3"
    local mac_l; mac_l=$(printf '%s' "$mac" | tr 'A-Z' 'a-z')
    case "$SEEN_MACS" in *" $mac_l "*) return ;; esac
    SEEN_MACS="$SEEN_MACS$mac_l "

    local online=0
    case "$LIVE_MACS" in *" $mac_l "*) online=1 ;; esac

    local down_mbps="null" up_mbps="null"
    if [ "$online" = "1" ]; then
        local rx tx
        set -- $(nlbw_bytes_for_mac "$mac")
        rx="${1:-0}"; tx="${2:-0}"

        local prev_line
        prev_line=$(grep -i "^$mac_l " "$PREV_FILE" 2>/dev/null | head -n1)
        if [ -n "$prev_line" ]; then
            local _pm prx ptx pt dt
            set -- $prev_line
            prx="$2"; ptx="$3"; pt="$4"
            dt=$((NOW - pt))
            if [ "$dt" -gt 0 ] && [ "$rx" -ge "$prx" ] && [ "$tx" -ge "$ptx" ]; then
                down_mbps=$(awk -v a="$rx" -v b="$prx" -v t="$dt" 'BEGIN{printf "%.2f", (a-b)*8/t/1000000}')
                up_mbps=$(awk -v a="$tx" -v b="$ptx" -v t="$dt" 'BEGIN{printf "%.2f", (a-b)*8/t/1000000}')
            fi
        fi
        NEW_STATE="$NEW_STATE$mac_l $rx $tx $NOW
"
    fi

    [ $FIRST -eq 0 ] && printf ','
    FIRST=0
    printf '{%s,%s,%s,%s,"down_mbps":%s,"up_mbps":%s}' \
        "$(jstr name "$name")" "$(jstr mac "$mac")" "$(jstr ip "$ip")" \
        "$(jbool online "$online")" "$down_mbps" "$up_mbps"
}

# ===========================================================================
# NODES — downstream router/AP management, for the "Nodes & Networks" page.
# ===========================================================================
# A node is metadata this app owns about a specific device you've flagged as
# a router or AP worth watching: a friendly name, what kind it is, and where
# its own (vendor) admin panel lives. It is deliberately NOT a new kind of
# network configuration — nothing here changes routing, firewalling, or
# DHCP. Storage lives in the mwadmin uci config (same file as mwadmin.alerts)
# as a lightweight bookmark-plus-live-status layer on top of devices this
# router already sees via ARP/DHCP and nlbwmon, reusing exactly those same
# mechanisms (see the DEVICES section above for how each one works).

# A node's IP can legitimately change (DHCP renewal, a reservation made
# elsewhere) — resolving it live from the same sources /devices uses, rather
# than storing an IP that can go stale, is why nodes are keyed by MAC.
node_ip_for_mac() {
    local target; target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    local _e _mac _ip _n _i
    while read -r _e _mac _ip _n _i; do
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return; }
    done < /tmp/dhcp.leases 2>/dev/null
    local _hw _flags _mask _dev
    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "br-lan" ] || continue
        [ "$(printf '%s' "$_mac" | tr 'A-Z' 'a-z')" = "$target" ] && { printf '%s' "$_ip"; return; }
    done < /proc/net/arp
}

api_nodes_get() {
    NLBW_RAW=$(nlbw_snapshot)

    LIVE_MACS=" "
    local _e _mac _ip _n _i
    while read -r _e _mac _ip _n _i; do
        [ -n "$_mac" ] && LIVE_MACS="$LIVE_MACS$(printf '%s' "$_mac" | tr 'A-Z' 'a-z') "
    done < /tmp/dhcp.leases 2>/dev/null
    local _flags _dev
    while read -r _ip _hw _flags _mac _mask _dev; do
        [ "$_dev" = "br-lan" ] || continue
        case "$_flags" in 0x0|"") continue ;; esac
        case "$_mac" in ''|00:00:00:00:00:00) continue ;; esac
        LIVE_MACS="$LIVE_MACS$(printf '%s' "$_mac" | tr 'A-Z' 'a-z') "
    done < /proc/net/arp

    # Own prev-sample file, separate from devices_emit's — /devices and
    # /nodes can legitimately be polled in the same few seconds from two open
    # tabs, and sharing one file would make each one's delta calculation
    # consume samples meant for the other.
    NOW=$(date +%s)
    local prev_file="$MW_RUN/noderates.prev" new_state="" first=1
    # Node presence is poll-driven, not event-driven like mwan3's WAN tracking
    # — this is what turns "online flipped since last poll" into a real
    # history event, same rotate-at-500 approach as package/etc/mwan3.user's
    # WAN history.
    local online_file="$MW_RUN/node_online.state" online_state_new=""

    printf '{"ok":true,"nodes":['
    local n
    for n in $(uci show mwadmin 2>/dev/null | sed -n "s/^mwadmin\.\([a-z0-9_]*\)=node$/\1/p"); do
        local name mac kind admin_url ip mac_l online down_mbps up_mbps
        name=$(uget mwadmin.$n.name); mac=$(uget mwadmin.$n.mac)
        kind=$(uget_d mwadmin.$n.kind other); admin_url=$(uget mwadmin.$n.admin_url)
        mac_l=$(printf '%s' "$mac" | tr 'A-Z' 'a-z')
        ip=$(node_ip_for_mac "$mac")

        online=0
        case "$LIVE_MACS" in *" $mac_l "*) online=1 ;; esac

        local prev_online
        prev_online=$(grep -i "^$mac_l " "$online_file" 2>/dev/null | head -n1 | awk '{print $2}')
        if [ -n "$prev_online" ] && [ "$prev_online" != "$online" ]; then
            local hdir="$MW_STATE/history" hf
            mkdir -p "$hdir" 2>/dev/null
            hf="$hdir/nodes.log"
            printf '%s|%s|%s|%s\n' "$NOW" "$mac" "$name" "$([ "$online" = "1" ] && echo up || echo down)" >> "$hf"
            if [ "$(wc -l < "$hf" 2>/dev/null)" -gt 500 ] 2>/dev/null; then
                tail -n 500 "$hf" > "$hf.tmp" && mv "$hf.tmp" "$hf"
            fi
        fi
        online_state_new="$online_state_new$mac_l $online
"

        down_mbps="null"; up_mbps="null"
        if [ "$online" = "1" ]; then
            local rx tx
            set -- $(nlbw_bytes_for_mac "$mac")
            rx="${1:-0}"; tx="${2:-0}"
            local prev_line
            prev_line=$(grep -i "^$mac_l " "$prev_file" 2>/dev/null | head -n1)
            if [ -n "$prev_line" ]; then
                local prx ptx pt dt
                set -- $prev_line
                prx="$2"; ptx="$3"; pt="$4"
                dt=$((NOW - pt))
                if [ "$dt" -gt 0 ] && [ "$rx" -ge "$prx" ] && [ "$tx" -ge "$ptx" ]; then
                    down_mbps=$(awk -v a="$rx" -v b="$prx" -v t="$dt" 'BEGIN{printf "%.2f", (a-b)*8/t/1000000}')
                    up_mbps=$(awk -v a="$tx" -v b="$ptx" -v t="$dt" 'BEGIN{printf "%.2f", (a-b)*8/t/1000000}')
                fi
            fi
            new_state="$new_state$mac_l $rx $tx $NOW
"
        fi

        [ -z "$admin_url" ] && [ -n "$ip" ] && admin_url="http://$ip/"

        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s,%s,%s,"down_mbps":%s,"up_mbps":%s}' \
            "$(jstr id "$n")" "$(jstr name "$name")" "$(jstr mac "$mac")" \
            "$(jstr kind "$kind")" "$(jstr ip "${ip:-}")" "$(jstr admin_url "$admin_url")" \
            "$(jbool online "$online")" "$down_mbps" "$up_mbps"
    done
    printf '%s' "$new_state" > "$prev_file"
    printf '%s' "$online_state_new" > "$online_file"
    printf ']}\n'
}

# ===========================================================================
# PER-DEVICE INTERNET CAPS
# ===========================================================================
# A cap is an INTERNET allowance, not a device speed limit: LAN-to-LAN stays
# at full line rate. The enforcement lives in devlimit.sh, which puts a
# "both ends inside the LAN -> unshaped" filter at a higher priority than any
# per-device rule. See that file's header for why that is reliable rather
# than best-effort.
#
# Stored in the mwadmin uci config as 'devlimit' sections keyed by MAC, for
# the same reason nodes are: a DHCP renewal legitimately moves a device, and
# a cap pinned to a stale IP would silently stop applying — or worse, start
# applying to whoever inherited the address.

api_devlimit_get() {
    sh /usr/lib/mwadmin/devlimit.sh status
}

api_devlimit_set() {
    local mac name down up enabled
    mac=$(bodyval mac); name=$(bodyval name)
    down=$(bodyval down_mbit); up=$(bodyval up_mbit)
    enabled=$(bodyval enabled)

    case "$mac" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
        *) json_error "Invalid MAC address (expected aa:bb:cc:dd:ee:ff)."; return ;;
    esac

    # Empty is accepted and means "no cap in this direction" — capping only
    # the download is the common case and should not require sending a 0.
    [ -z "$down" ] && down=0
    [ -z "$up" ] && up=0
    valid_int "$down" || { json_error "Download cap must be a whole number of Mbit/s."; return; }
    valid_int "$up"   || { json_error "Upload cap must be a whole number of Mbit/s."; return; }
    # 1000 is the LAN link rate; a cap at or above it is not a cap, and the
    # HTB root is built at exactly that ceiling.
    [ "$down" -gt 1000 ] 2>/dev/null && { json_error "Download cap cannot exceed 1000 Mbit/s."; return; }
    [ "$up" -gt 1000 ] 2>/dev/null && { json_error "Upload cap cannot exceed 1000 Mbit/s."; return; }
    case "$name" in *[!a-zA-Z0-9_\ .-]*) json_error "Name may contain only letters, digits, space, dot, hyphen and underscore."; return ;; esac

    local sect; sect="lim_$(echo "$mac" | tr -d ':' | tr 'A-Z' 'a-z')"

    # Both directions zero means "remove the cap" rather than "store a cap of
    # nothing" — otherwise the config accumulates dead sections that the UI
    # then has to filter out on every render.
    if [ "$down" = "0" ] && [ "$up" = "0" ]; then
        uci -q delete "mwadmin.$sect"
        uci commit mwadmin
        sh /usr/lib/mwadmin/devlimit.sh apply >/dev/null 2>&1
        log "devlimit removed: $mac"
        json_ok "$(jstr message 'Limit removed. This device is back to full internet speed.')"
        return
    fi

    uci set "mwadmin.$sect=devlimit"
    uci set "mwadmin.$sect.mac=$mac"
    [ -n "$name" ] && uci set "mwadmin.$sect.name=$name"
    uci set "mwadmin.$sect.down_mbit=$down"
    uci set "mwadmin.$sect.up_mbit=$up"
    uci set "mwadmin.$sect.enabled=$([ "$enabled" = "0" ] && echo 0 || echo 1)"
    uci commit mwadmin

    sh /usr/lib/mwadmin/devlimit.sh apply >/dev/null 2>&1
    log "devlimit set: $mac down=${down}M up=${up}M"

    local msg="Limit saved."
    [ "$down" != "0" ] && msg="$msg Download capped at ${down} Mb/s."
    [ "$up" != "0" ] && msg="$msg Upload capped at ${up} Mb/s."
    json_ok "$(jstr message "$msg Local network transfers are unaffected.")"
}

api_nodes_add() {
    local name mac kind admin_url
    name=$(bodyval name); mac=$(bodyval mac); kind=$(bodyval kind); admin_url=$(bodyval admin_url)

    case "$mac" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
        *) json_error "Invalid MAC address (expected aa:bb:cc:dd:ee:ff)."; return ;;
    esac
    case "$name" in ''|*[!a-zA-Z0-9_" "-]*) json_error "Name may contain only letters, digits, space, hyphen and underscore."; return ;; esac
    case "$kind" in router|ap|other) ;; *) kind=other ;; esac
    if [ -n "$admin_url" ]; then
        case "$admin_url" in
            http://*|https://*) ;;
            *) json_error "Admin panel URL must start with http:// or https://"; return ;;
        esac
    fi

    mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')

    # Saving a node also keeps its address (a DHCP reservation, so the node
    # and its admin link never move) and gives it this name everywhere.
    local ip reserve hsect="" other
    ip=$(bodyval ip); reserve=$(bodyval reserve)
    [ -z "$ip" ] && ip=$(node_ip_for_mac "$mac")
    if [ "$reserve" != "0" ] && [ -n "$ip" ]; then
        valid_ipv4 "$ip" || { json_error "Invalid IP address."; return; }
        local lan mask
        lan=$(uget network.lan.ipaddr); mask=$(uget_d network.lan.netmask 255.255.255.0)
        case "$lan" in */*) mask="${lan#*/}"; lan="${lan%/*}" ;; esac
        [ "$(ipcalc.sh "$ip" "$mask" | sed -n 's/^NETWORK=//p')" = "$(ipcalc.sh "$lan" "$mask" | sed -n 's/^NETWORK=//p')" ] ||
            { json_error "$ip is not on this router's network."; return; }
        case "$ip" in "$lan"|"${lan%.*}.253"|"${lan%.*}.254") json_error "$ip belongs to the router itself."; return ;; esac
        # the reservation this MAC already has (any section name), and anyone else holding the address
        hsect=$(uci show dhcp 2>/dev/null | awk -F"[.=]" -v m="$mac" 'tolower($0) ~ "\\.mac=.*" m { print $2; exit }')
        other=$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([^.]*\)\.ip='$ip'$/\1/p" | grep -vx "${hsect:-none}" | head -n1)
        [ -n "$other" ] && { json_error "$ip is already reserved for $(uget dhcp.$other.name || echo another device). Pick a different address."; return; }
        [ -n "$hsect" ] || hsect="host_$(echo "$mac" | tr -d ':')"
    fi

    local sect; sect="node_$(echo "$mac" | tr -d ':')"
    uci set mwadmin.$sect='node'
    uci set mwadmin.$sect.name="$name"
    uci set mwadmin.$sect.mac="$mac"
    uci set mwadmin.$sect.kind="$kind"
    if [ -n "$admin_url" ]; then uci set mwadmin.$sect.admin_url="$admin_url"; else uci -q delete mwadmin.$sect.admin_url; fi
    uci commit mwadmin

    local msg="Saved as a node."
    if [ -n "$hsect" ]; then
        uci set dhcp.$hsect='host'
        uci set dhcp.$hsect.mac="$mac"
        uci set dhcp.$hsect.ip="$ip"
        # DHCP names allow letters, digits and hyphens only: "Roof WIFI - AX10" -> Roof-WIFI-AX10
        uci set dhcp.$hsect.name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9-' '-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-63)"
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1
        msg="Saved as a node. $ip is now reserved for it."
    fi
    # the name the website's activity and the sign-in list show
    if grep -qi "^$mac	" /etc/mwadmin/guests 2>/dev/null; then
        awk -F'\t' -v OFS='\t' -v m="$mac" -v n="$name" 'tolower($1) == m { $4 = n } { print }' /etc/mwadmin/guests > /etc/mwadmin/guests.tmp &&
            chmod 600 /etc/mwadmin/guests.tmp && mv /etc/mwadmin/guests.tmp /etc/mwadmin/guests
    fi
    log "node saved: $name ($mac${hsect:+, reserved $ip})"
    json_ok "$(jstr message "$msg")"
}

api_nodes_del() {
    local id; id=$(bodyval id)
    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid node id."; return ;; esac
    [ "$(uget mwadmin.$id)" = "node" ] || { json_error "No such node."; return; }
    uci -q delete mwadmin.$id
    uci commit mwadmin
    json_ok "$(jstr message 'Node removed.')"
}

# ---------------------------------------------------------------------------
# Node speed test — latency/loss, not throughput.
# ---------------------------------------------------------------------------
# Real down/up throughput to an arbitrary LAN device would need that device
# to run something like iperf3 — unrealistic for a stock TP-Link/mesh AP with
# unknown firmware. Latency, loss, and jitter are honest, useful signals any
# IP-reachable device can answer, with nothing installed on the node itself.
# Same fire-and-forget background-job shape as api_port_test / portdetect.sh:
# start returns immediately, the browser polls the result endpoint.
api_node_test_start() {
    local id ip mac name
    id=$(bodyval id)
    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid node id."; return ;; esac
    [ "$(uget mwadmin.$id)" = "node" ] || { json_error "No such node."; return; }
    mac=$(uget mwadmin.$id.mac); name=$(uget mwadmin.$id.name)
    ip=$(node_ip_for_mac "$mac")
    valid_ipv4 "$ip" || { json_error "$name has no known IP right now — it may be offline."; return; }

    # This is a best-effort fast rejection only — the real lock is acquired
    # inside the detached process below, so the pid it records is the
    # long-running one, not this short-lived CGI process (which would make
    # lock_acquire's stale-lock reaping immediately reclaim it on the very
    # next request).
    [ -d "$MW_RUN/locks/nodetest_$id.lock" ] && { json_error "A test is already running for this node."; return; }
    mkdir -p "$MW_RUN/nodetest"
    local rf="$MW_RUN/nodetest/$id.json"
    printf '{"status":"running","ip":"%s"}\n' "$(json_escape "$ip")" > "$rf"

    ( setsid sh -c '
        . /usr/lib/mwadmin/common.sh
        lock_acquire "nodetest_'"$id"'" || exit 0
        out=$(ping -c 6 -W 1 -q "$1" 2>&1)
        avg=$(printf "%s" "$out" | awk -F"/" "/^(round-trip|rtt)/ {printf \"%.1f\", \$5}")
        loss=$(printf "%s" "$out" | sed -n "s/.*, \([0-9]*\)% packet loss.*/\1/p")
        [ -z "$avg" ] && avg=null
        [ -z "$loss" ] && loss=null
        printf "{\"status\":\"done\",\"ip\":\"%s\",\"avg_ms\":%s,\"loss_pct\":%s,\"tested_at\":%s}\n" \
            "$1" "$avg" "$loss" "$(date +%s)" > "$2"
        lock_release "nodetest_'"$id"'"
    ' _ "$ip" "$rf" >/dev/null 2>&1 & ) &

    json_ok "$(jstr message 'Test started.')"
}

api_node_test_result() {
    local id; id=$(qsval id)
    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid node id."; return ;; esac
    if [ -f "$MW_RUN/nodetest/$id.json" ]; then
        cat "$MW_RUN/nodetest/$id.json"
    else
        printf '{"status":"never_run"}\n'
    fi
}

# Merges WAN history (package/etc/mwan3.user, event-driven) and node history
# (api_nodes_get, poll-driven) into one feed for the "line and node
# online/offline reporting" panel. Both files are "timestamp|...|event" —
# newest first, capped, so the UI never has to paginate a file that could in
# principle grow across weeks of uptime.
api_history_get() {
    local limit; limit=$(qsval limit); valid_int "$limit" || limit=100
    [ "$limit" -gt 500 ] && limit=500

    printf '{"ok":true,"events":['
    {
        [ -f "$MW_STATE/history/wan.log" ] && while IFS='|' read -r ts iface event; do
            [ -z "$ts" ] && continue
            printf '%s|%s|%s|%s|%s\n' "$ts" wan "$iface" "$(printf '%s' "$iface" | tr 'a-z' 'A-Z')" "$event"
        done < "$MW_STATE/history/wan.log"
        [ -f "$MW_STATE/history/nodes.log" ] && while IFS='|' read -r ts mac name event; do
            [ -z "$ts" ] && continue
            printf '%s|%s|%s|%s|%s\n' "$ts" node "$mac" "$name" "$event"
        done < "$MW_STATE/history/nodes.log"
    } | sort -rn | head -n "$limit" | {
        local first=1 ts kind id label event
        while IFS='|' read -r ts kind id label event; do
            [ $first -eq 0 ] && printf ','
            first=0
            printf '{%s,%s,%s,%s,%s}' \
                "$(jnum ts "$ts")" "$(jstr kind "$kind")" "$(jstr id "$id")" \
                "$(jstr label "$label")" "$(jstr event "$event")"
        done
    }
    printf ']}\n'
}

# ===========================================================================
# BANDWIDTH
# ===========================================================================
api_bandwidth() {
    printf '{"ok":true,"interfaces":['
    local first=1 i dev
    for i in wan1 wan2 wan3 lan; do
        dev=$(uget "network.$i.device")
        [ -z "$dev" ] && continue
        [ $first -eq 0 ] && printf ','
        first=0
        printf '%s' "$(sh /usr/lib/mwadmin/portdetect.sh counters "$dev" | \
                       sed "s/^{/{\"iface\":\"$i\",/")"
    done
    printf ']}\n'
}

# ===========================================================================
# LAN / DHCP
# ===========================================================================
api_lan_get() {
    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(jstr ipaddr "$(uget network.lan.ipaddr)")" \
        "$(jstr netmask "$(uget network.lan.netmask)")" \
        "$(jstr dhcp_start "$(uget dhcp.lan.start)")" \
        "$(jstr dhcp_limit "$(uget dhcp.lan.limit)")" \
        "$(jstr dhcp_lease "$(uget dhcp.lan.leasetime)")" \
        "$(jbool dhcp_enabled "$([ "$(uget dhcp.lan.ignore)" = "1" ] && echo 0 || echo 1)")" \
        "$(jstr hostname_alias "$(uget dhcp.mwadmin_alias.name)")"
}

# Moving the LAN to another /24 carries reservations, the admin alias name and
# port forwards along, keeping each device's host number (192.168.1.167 ->
# 192.168.30.167). Without this they point into the old network and silently
# stop working. The lan-rollback profile covers dhcp and firewall, so a revert
# undoes this as well.
lan_move_hosts() {
    local from="$1" to="$2" cfg key val
    for cfg in dhcp firewall; do
        uci -q show "$cfg" | grep -E "\.(ip|dest_ip)='" | while IFS='=' read -r key val; do
            val=${val#\'}; val=${val%\'}
            case "$val" in "$from"*) uci set "$key=$to${val#"$from"}" ;; esac
        done
    done
}

api_lan_set() {
    local ip mask start limit lease enabled
    ip=$(bodyval ipaddr); mask=$(bodyval netmask)
    start=$(bodyval dhcp_start); limit=$(bodyval dhcp_limit)
    lease=$(bodyval dhcp_lease); enabled=$(bodyval dhcp_enabled)

    valid_ipv4 "$ip"   || { json_error "Invalid LAN IP address."; return; }
    valid_ipv4 "$mask" || { json_error "Invalid netmask."; return; }
    valid_int "$start" || { json_error "DHCP start must be a number."; return; }
    valid_int "$limit" || { json_error "DHCP limit must be a number."; return; }
    case "$lease" in ''|*[!0-9hmd]*) json_error "Invalid lease time (use e.g. 12h)."; return ;; esac

    # Changing the address or netmask itself is the only part of this form
    # that can lock the browser out (wrong DHCP pool size doesn't). That gets
    # the same snapshot/apply/confirm-or-revert safety net the AP/Router mode
    # switch already uses, rather than shipping this form with no way back
    # from a typo.
    local old_ip old_mask address_changed=0
    old_ip=$(uget network.lan.ipaddr); old_mask=$(uget network.lan.netmask)
    [ "$ip" != "$old_ip" ] || [ "$mask" != "$old_mask" ] && address_changed=1

    if [ "$address_changed" = "1" ] && [ "$(sh /usr/lib/mwadmin/modeswitch.sh rollback-pending)" = "1" ]; then
        json_error "A previous network change is still waiting for confirmation. Confirm or wait for it to finish before changing the LAN address again."
        return
    fi

    [ "$address_changed" = "1" ] && sh /usr/lib/mwadmin/modeswitch.sh save-profile lan-rollback

    uci set network.lan.ipaddr="$ip"
    uci set network.lan.netmask="$mask"
    uci set dhcp.lan.start="$start"
    uci set dhcp.lan.limit="$limit"
    uci set dhcp.lan.leasetime="$lease"
    if [ "$enabled" = "0" ]; then uci set dhcp.lan.ignore='1'; else uci -q delete dhcp.lan.ignore; fi
    if [ "$address_changed" = "1" ] && [ "$mask" = "255.255.255.0" ] && [ "${old_mask:-255.255.255.0}" = "255.255.255.0" ] && \
       [ "${old_ip%.*}" != "${ip%.*}" ]; then
        lan_move_hosts "${old_ip%.*}." "${ip%.*}."
        [ -n "$(uci -q get network.lan_block.ipaddr)" ] && uci set network.lan_block.ipaddr="${ip%.*}.253"
        log "LAN moved ${old_ip%.*}.0/24 -> ${ip%.*}.0/24: reservations and forwards renumbered"
    fi
    uci commit network; uci commit dhcp; uci commit firewall

    # listen_http is a uci list; once the port-80 alias exists it holds two
    # "ip:port" entries space-separated on one line, so a blind `cut -d:`
    # across the whole thing no longer isolates one port. Read the configured
    # port directly instead (same source mwadmin's init script uses).
    local port; port=$(uget_d mwadmin.@main[0].port 8080)
    local alias_host; alias_host=$(uget dhcp.mwadmin_alias.name)
    local alias_ip;   alias_ip=$(uget dhcp.mwadmin_alias.ip)
    local reconnect_at redirect_url
    if [ -n "$alias_host" ]; then
        # Compared against the pre-change LAN address: at this point in the
        # request the async network reload hasn't run yet, so alias_ip is
        # still whatever it was before this save (either mirroring the old
        # LAN IP directly, or a separate dedicated port-80 address).
        if [ "$alias_ip" = "$old_ip" ]; then
            # No dedicated port-80 alias configured — the hostname still needs
            # the app's port.
            reconnect_at="http://$alias_host:$port (or http://$ip:$port)"
            redirect_url="http://$alias_host:$port"
        else
            reconnect_at="http://$alias_host (or http://$ip:$port)"
            redirect_url="http://$alias_host"
        fi
    else
        reconnect_at="http://$ip:$port"
        redirect_url="http://$ip:$port"
    fi

    if [ "$address_changed" = "1" ]; then
        # Report the real outcome of arming, not an assumed one. If the timer
        # did not start there is no automatic way back from a typo here, and
        # that is the single most important thing to tell the user before
        # their browser loses the old address.
        local secs=90 msg
        if sh /usr/lib/mwadmin/modeswitch.sh arm lan-rollback; then
            msg="Saved. Reconnecting to $reconnect_at — confirm there within 90 seconds, or the router reverts to the previous LAN settings automatically."
        else
            secs=0
            msg="Saved, but the automatic revert timer FAILED TO START — if you cannot reach $reconnect_at, nothing will undo this for you. Recover with failsafe mode, or over SSH."
        fi
        json_ok "$(printf '%s,%s,%s' \
            "$(jnum rollback_seconds "$secs")" \
            "$(jstr redirect_url "$redirect_url")" \
            "$(jstr message "$msg")")"
    else
        json_ok "$(jstr message "Saved.")"
    fi
    # The admin UI binds specific LAN addresses and deliberately never
    # 0.0.0.0 (see package/init.d/mwadmin), so changing the LAN address MUST
    # be followed by a mwadmin restart. Without it uhttpd keeps its sockets on
    # the OLD address — which Linux leaves in LISTEN even after the address is
    # removed from the interface — while nothing at all binds the new one. The
    # browser then cannot reach the confirm endpoint on either address, so the
    # rollback deadline passes on a change the user had no way to approve.
    #
    # procd's "network" reload trigger in package/init.d/mwadmin does not
    # cover this: it fires on a procd config.change event, which only
    # reload_config emits — never a direct `/etc/init.d/network reload`. So
    # the restart is explicit here rather than left to the trigger.
    #
    # It also has to WAIT for the address to exist first. netifd applies the
    # change asynchronously and uhttpd silently skips any listen address that
    # is not present at bind time, which would reproduce the same failure one
    # step later. Falls through after ~20 s so a stuck netifd cannot wedge
    # this in a loop; mwadmin's own restart is still worth attempting then.
    ( sleep 2
      /etc/init.d/network reload
      /etc/init.d/dnsmasq restart
      /etc/init.d/firewall reload
      i=0
      while [ "$i" -lt 20 ]; do
          ip -4 -o addr show dev br-lan 2>/dev/null | grep -q "inet $ip/" && break
          sleep 1
          i=$((i + 1))
      done
      # Wired devices keep their old address after a LAN move: Windows, for
      # one, keeps asking the OLD router address to renew and never gets an
      # answer. Dropping the cable link for a moment makes every wired device
      # ask for a fresh address at once. (Wi-Fi clients already reconnect,
      # because the Wi-Fi reloads with the network.)
      if [ "$address_changed" = "1" ]; then
          sleep 2
          for p in $(ls /sys/class/net/br-lan/brif 2>/dev/null); do
              case "$p" in lan*|eth*) ip link set "$p" down ;; esac
          done
          sleep 3
          for p in $(ls /sys/class/net/br-lan/brif 2>/dev/null); do
              case "$p" in lan*|eth*) ip link set "$p" up ;; esac
          done
          log "LAN ports cycled so wired devices pick up the new address"
      fi
      /etc/init.d/mwadmin restart
    ) >/dev/null 2>&1 &
}

api_dhcp_leases() {
    local static_ids; static_ids=$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([a-z0-9_]*\)=host$/\1/p")

    # MAC -> reservation name, built once up front.
    reserved_name_for_mac() {
        local target; target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
        local s m
        for s in $static_ids; do
            m=$(uget "dhcp.$s.mac" | tr 'A-Z' 'a-z')
            [ "$m" = "$target" ] && { uget "dhcp.$s.name"; return; }
        done
    }
    is_reserved_mac() { [ -n "$(reserved_name_for_mac "$1")" ]; }

    printf '{"ok":true,"leases":['
    local first=1 seen_ips=" "

    while read -r expiry mac ip name id; do
        [ -z "$mac" ] && continue
        # A device with a static reservation is fully represented in the
        # "static" list below. Showing it here too — even correctly named —
        # is still the same device listed twice on one page; the two lists
        # only stay meaningfully distinct if "leases" means "not yet named."
        is_reserved_mac "$mac" && continue
        [ $first -eq 0 ] && printf ','
        first=0
        seen_ips="$seen_ips$ip "
        # "*" is dnsmasq's own placeholder for "this client sent no hostname",
        # not a real name — treat it the same as genuinely empty.
        [ "$name" = "*" ] && name=""
        printf '{%s,%s,%s,%s,%s}' \
            "$(jnum expires "$expiry")" "$(jstr mac "$mac")" \
            "$(jstr ip "$ip")" "$(jstr hostname "$name")" \
            "$(jbool from_lease 1)"
    done < /tmp/dhcp.leases 2>/dev/null

    # dnsmasq's lease file only covers devices that have DHCP'd since the
    # last time dnsmasq itself restarted — which during initial setup can be
    # "never," even though the device has been online for hours. The kernel's
    # own ARP/neighbour table doesn't have that blind spot: any device that
    # has exchanged so much as one packet on br-lan shows up here regardless
    # of DHCP history, so it fills the gap for devices with a long-lived
    # address the lease file hasn't caught up to yet.
    #
    # 0x2 = STALE/REACHABLE (a real, resolved entry). Skips 0x0/incomplete
    # rows and the bogus all-zero MAC broadcast/multicast noise ARP tables
    # accumulate.
    while read -r ip _hw flags mac _mask dev; do
        [ "$dev" = "Device" ] && continue
        [ "$dev" = "br-lan" ] || continue
        case "$flags" in 0x0|"") continue ;; esac
        case "$mac" in ''|00:00:00:00:00:00) continue ;; esac
        case "$seen_ips" in *" $ip "*) continue ;; esac
        is_reserved_mac "$mac" && continue
        seen_ips="$seen_ips$ip "
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s}' \
            "$(jnum expires 0)" "$(jstr mac "$mac")" \
            "$(jstr ip "$ip")" "$(jstr hostname "")" \
            "$(jbool from_lease 0)"
    done < /proc/net/arp

    printf '],"static":['
    first=1
    for s in $static_ids; do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s}' \
            "$(jstr id "$s")" "$(jstr name "$(uget dhcp.$s.name)")" \
            "$(jstr mac "$(uget dhcp.$s.mac)")" "$(jstr ip "$(uget dhcp.$s.ip)")"
    done
    printf ']}\n'
}

api_dhcp_static_add() {
    local name mac ip
    name=$(bodyval name); mac=$(bodyval mac); ip=$(bodyval ip)
    case "$mac" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
        *) json_error "Invalid MAC address (expected aa:bb:cc:dd:ee:ff)."; return ;;
    esac
    valid_ipv4 "$ip" || { json_error "Invalid IP address."; return; }
    case "$name" in *[!a-zA-Z0-9_-]*) json_error "Host name may contain only letters, digits, hyphen and underscore."; return ;; esac

    local sect; sect="host_$(echo "$mac" | tr -d ':' | tr 'A-Z' 'a-z')"
    uci set dhcp.$sect='host'
    uci set dhcp.$sect.name="$name"
    uci set dhcp.$sect.mac="$mac"
    uci set dhcp.$sect.ip="$ip"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    json_ok "$(jstr message 'Reservation added.')"
}

api_dhcp_static_del() {
    local id; id=$(bodyval id)
    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid reservation id."; return ;; esac
    [ "$(uget dhcp.$id)" = "host" ] || { json_error "No such reservation."; return; }
    uci -q delete dhcp.$id
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    json_ok "$(jstr message 'Reservation removed.')"
}

# ===========================================================================
# WIRELESS
# ===========================================================================
api_wifi_get() {
    printf '{"ok":true,"radios":['
    local first=1 r
    for r in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([a-z0-9]*\)=wifi-device$/\1/p"); do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s,%s}' \
            "$(jstr id "$r")" \
            "$(jstr band "$(uget_d wireless.$r.band "$(uget wireless.$r.hwmode)")")" \
            "$(jstr channel "$(uget wireless.$r.channel)")" \
            "$(jstr htmode "$(uget wireless.$r.htmode)")" \
            "$(jstr country "$(uget wireless.$r.country)")" \
            "$(jbool disabled "$(uget_d wireless.$r.disabled 0)")"
    done
    printf '],"networks":['
    first=1
    for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([a-z0-9_]*\)=wifi-iface$/\1/p"); do
        [ $first -eq 0 ] && printf ','
        first=0
        # The PSK is deliberately never returned to the browser. The UI shows a
        # placeholder and only sends a key when the user actually types a new
        # one, so an XSS or a shoulder-surfed devtools panel cannot harvest it.
        printf '{%s,%s,%s,%s,%s,%s,%s,%s}' \
            "$(jstr id "$s")" \
            "$(jstr device "$(uget wireless.$s.device)")" \
            "$(jstr ssid "$(uget wireless.$s.ssid)")" \
            "$(jstr encryption "$(uget wireless.$s.encryption)")" \
            "$(jstr network "$(uget wireless.$s.network)")" \
            "$(jbool isolate "$(uget_d wireless.$s.isolate 0)")" \
            "$(jbool disabled "$(uget_d wireless.$s.disabled 0)")" \
            "$(jbool hidden "$(uget_d wireless.$s.hidden 0)")"
    done
    printf '],"clients":['
    first=1
    for iface in $(iwinfo 2>/dev/null | sed -n 's/^\([a-z0-9-]*\)[[:space:]]*ESSID.*/\1/p'); do
        iwinfo "$iface" assoclist 2>/dev/null | \
        sed -n "s/^\([0-9A-F:]\{17\}\).*[^0-9-]\(-[0-9]\{1,3\}\) dBm.*/\1 \2 $iface/p"
    done | while read -r mac sig iface; do
        # One loop over ALL interfaces: a per-interface `| while` runs in its
        # own subshell each time, which reset $first and dropped the comma
        # between the last client of one radio and the first of the next —
        # invalid JSON as soon as both bands had a client connected.
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s}' "$(jstr mac "$mac")" "$(jnum signal_dbm "$sig")" "$(jstr iface "$iface")"
    done
    printf ']}\n'
}

api_wifi_set() {
    local id ssid key enc disabled isolate hidden
    id=$(bodyval id); ssid=$(bodyval ssid); key=$(bodyval key)
    enc=$(bodyval encryption); disabled=$(bodyval disabled); isolate=$(bodyval isolate)
    hidden=$(bodyval hidden)

    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid network id."; return ;; esac
    [ "$(uget wireless.$id)" = "wifi-iface" ] || { json_error "No such wireless network."; return; }

    if [ -n "$ssid" ]; then
        [ ${#ssid} -gt 32 ] && { json_error "SSID may be at most 32 characters."; return; }
        uci set wireless.$id.ssid="$ssid"
    fi

    if [ -n "$key" ]; then
        [ ${#key} -lt 8 ] && { json_error "Password must be at least 8 characters."; return; }
        [ ${#key} -gt 63 ] && { json_error "Password may be at most 63 characters."; return; }
        uci set wireless.$id.key="$key"
    fi

    if [ -n "$enc" ]; then
        case "$enc" in
            psk2|psk-mixed|sae|sae-mixed|none) uci set wireless.$id.encryption="$enc" ;;
            *) json_error "Unsupported security type."; return ;;
        esac
        case "$enc" in
            sae|sae-mixed)
                if ! (opkg list-installed 2>/dev/null || apk info 2>/dev/null) | grep -qE 'wpad-(mbedtls|openssl|wolfssl)'; then
                    json_error "WPA3 requires a full wpad build. Install wpad-mbedtls (replacing wpad-basic-mbedtls) first."
                    return
                fi
                ;;
        esac
    fi

    [ -n "$disabled" ] && uci set wireless.$id.disabled="$([ "$disabled" = "1" ] && echo 1 || echo 0)"
    [ -n "$isolate" ]  && uci set wireless.$id.isolate="$([ "$isolate" = "1" ] && echo 1 || echo 0)"
    # Hidden suppresses the SSID from beacon frames. It is obscurity, not
    # security — the name still goes out in plain text whenever a real client
    # connects — but it does what most people mean by "hide my WiFi."
    [ -n "$hidden" ]   && uci set wireless.$id.hidden="$([ "$hidden" = "1" ] && echo 1 || echo 0)"

    uci commit wireless
    ( sleep 1; wifi reload ) >/dev/null 2>&1 &
    json_ok "$(jstr message 'Wireless settings saved. Radios are reloading.')"
}

api_wifi_radio_set() {
    local id channel htmode country disabled
    id=$(bodyval id); channel=$(bodyval channel); htmode=$(bodyval htmode)
    country=$(bodyval country); disabled=$(bodyval disabled)

    case "$id" in ''|*[!a-z0-9]*) json_error "Invalid radio id."; return ;; esac
    [ "$(uget wireless.$id)" = "wifi-device" ] || { json_error "No such radio."; return; }

    if [ -n "$channel" ]; then
        case "$channel" in auto|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]) uci set wireless.$id.channel="$channel" ;;
            *) json_error "Invalid channel."; return ;; esac
    fi
    if [ -n "$htmode" ]; then
        case "$htmode" in HT20|HT40|VHT20|VHT40|VHT80|VHT160) uci set wireless.$id.htmode="$htmode" ;;
            *) json_error "Invalid channel width."; return ;; esac
    fi
    if [ -n "$country" ]; then
        case "$country" in [A-Z][A-Z]) uci set wireless.$id.country="$country" ;;
            *) json_error "Country must be a two-letter code."; return ;; esac
    fi
    [ -n "$disabled" ] && uci set wireless.$id.disabled="$([ "$disabled" = "1" ] && echo 1 || echo 0)"

    uci commit wireless
    ( sleep 1; wifi reload ) >/dev/null 2>&1 &
    json_ok "$(jstr message 'Radio settings saved.')"
}

# ===========================================================================
# FIREWALL
# ===========================================================================
api_fw_get() {
    printf '{"ok":true,"forwards":['
    local first=1 s
    for s in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([a-z0-9_]*\)=redirect$/\1/p"); do
        # admin_ui_wan is managed exclusively by the Remote Access page's own
        # toggle (remote_admin below), not the generic port-forward list —
        # listing it here too would let it be edited/deleted from two places,
        # and the generic delete button doesn't know it needs the Remote
        # Access page's warning-before-enabling treatment.
        [ "$s" = "admin_ui_wan" ] && continue
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s,%s,%s}' \
            "$(jstr id "$s")" "$(jstr name "$(uget firewall.$s.name)")" \
            "$(jstr proto "$(uget firewall.$s.proto)")" \
            "$(jstr src_dport "$(uget firewall.$s.src_dport)")" \
            "$(jstr dest_ip "$(uget firewall.$s.dest_ip)")" \
            "$(jstr dest_port "$(uget firewall.$s.dest_port)")" \
            "$(jbool enabled "$(uget_d firewall.$s.enabled 1)")"
    done
    printf '],'
    printf '%s,' "$(jbool upnp_enabled "$([ -f /etc/init.d/miniupnpd ] && /etc/init.d/miniupnpd enabled && echo 1 || echo 0)")"
    printf '%s,' "$(jstr dmz_host "$(uget firewall.dmz_host.dest_ip)")"
    printf '%s,' "$(jbool sw_offload "$(uget_d firewall.@defaults[0].flow_offloading 0)")"
    printf '%s,' "$(jbool hw_offload "$(uget_d firewall.@defaults[0].flow_offloading_hw 0)")"
    printf '%s,' "$(jbool remote_admin "$([ "$(uget firewall.admin_ui_wan.enabled)" = "1" ] && echo 1 || echo 0)")"
    printf '%s'  "$(jstr admin_wan_port "$(uget firewall.admin_ui_wan.src_dport)")"
    printf '}\n'
}

api_fw_forward_add() {
    local name proto sport dip dport
    name=$(bodyval name); proto=$(bodyval proto)
    sport=$(bodyval src_dport); dip=$(bodyval dest_ip); dport=$(bodyval dest_port)

    # No spaces: an unquoted space inside a case bracket expression is a parse
    # error in ash and bash alike, and a UCI section name cannot contain one anyway.
    case "$name" in ''|*[!a-zA-Z0-9_-]*) json_error "Rule name may contain only letters, digits, hyphen and underscore."; return ;; esac
    case "$proto" in tcp|udp|"tcp udp") ;; *) json_error "Protocol must be tcp, udp, or 'tcp udp'."; return ;; esac
    valid_int "$sport" || { json_error "Invalid external port."; return; }
    valid_int "$dport" || { json_error "Invalid internal port."; return; }
    [ "$sport" -gt 65535 ] && { json_error "External port out of range."; return; }
    [ "$dport" -gt 65535 ] && { json_error "Internal port out of range."; return; }
    valid_ipv4 "$dip" || { json_error "Invalid destination IP."; return; }

    local sect="pf_${sport}_${proto%% *}"
    uci set firewall.$sect='redirect'
    uci set firewall.$sect.target='DNAT'
    uci set firewall.$sect.src='wan'
    uci set firewall.$sect.dest='lan'
    uci set firewall.$sect.name="$name"
    uci set firewall.$sect.proto="$proto"
    uci set firewall.$sect.src_dport="$sport"
    uci set firewall.$sect.dest_ip="$dip"
    uci set firewall.$sect.dest_port="$dport"
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "port forward added: $proto $sport -> $dip:$dport"
    json_ok "$(jstr message 'Port forward added.')"
}

api_fw_forward_del() {
    local id; id=$(bodyval id)
    case "$id" in ''|*[!a-z0-9_]*) json_error "Invalid rule id."; return ;; esac
    [ "$(uget firewall.$id)" = "redirect" ] || { json_error "No such port forward."; return; }
    uci -q delete firewall.$id
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    json_ok "$(jstr message 'Port forward removed.')"
}

api_fw_settings() {
    local dmz upnp remote
    dmz=$(bodyval dmz_host); upnp=$(bodyval upnp_enabled); remote=$(bodyval remote_admin)

    if [ -n "$dmz" ]; then
        if [ "$dmz" = "none" ] || [ "$dmz" = "" ]; then
            uci -q delete firewall.dmz_host
        else
            valid_ipv4 "$dmz" || { json_error "Invalid DMZ host address."; return; }
            uci set firewall.dmz_host='redirect'
            uci set firewall.dmz_host.target='DNAT'
            uci set firewall.dmz_host.src='wan'
            uci set firewall.dmz_host.dest='lan'
            uci set firewall.dmz_host.name='DMZ'
            uci set firewall.dmz_host.dest_ip="$dmz"
            log "DMZ host set to $dmz — this host is now fully exposed to all three WANs"
        fi
    fi

    if [ -n "$upnp" ]; then
        if [ "$upnp" = "1" ]; then
            /etc/init.d/miniupnpd enable >/dev/null 2>&1 && /etc/init.d/miniupnpd start >/dev/null 2>&1
        else
            /etc/init.d/miniupnpd stop >/dev/null 2>&1; /etc/init.d/miniupnpd disable >/dev/null 2>&1
        fi
    fi

    # Remote admin access. The UI is required to have shown its warning before
    # sending this; the log line exists so that enabling it is always traceable
    # afterwards even if the UI is bypassed.
    if [ -n "$remote" ]; then
        if [ "$remote" = "1" ]; then
            uci set firewall.admin_ui_wan.enabled='1'
            log "WARNING: admin UI exposed to WAN by user request"
        else
            uci set firewall.admin_ui_wan.enabled='0'
            log "admin UI WAN exposure disabled"
        fi
    fi

    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    json_ok "$(jstr message 'Firewall settings saved.')"
}

# ===========================================================================
# DNS / DDNS / QOS / WIREGUARD
# ===========================================================================
api_dns_get() {
    printf '{"ok":true,"servers":['
    local first=1 s
    local list; list=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
    # while the 18+ filter runs, show the owner's own servers (kept aside)
    ad_on && [ -n "$(uci -q get mwadmin.adult.prev)" ] && list=$(uci -q get mwadmin.adult.prev)
    for s in $list; do
        case "$s" in /*) continue ;; esac
        [ $first -eq 0 ] && printf ','
        first=0
        printf '"%s"' "$(json_escape "$s")"
    done
    printf '],%s}\n' "$(jbool ignore_isp_dns "$(uget_d dhcp.@dnsmasq[0].noresolv 0)")"
}

api_dns_set() {
    local servers ignore
    servers=$(bodyval servers); ignore=$(bodyval ignore_isp_dns)
    # 18+ filter on: these become the servers used once it is off
    if ad_on; then
        for s in $servers; do valid_ipv4 "$s" || { json_error "Invalid DNS server: $s"; return; }; done
        [ -n "$servers" ] || { json_error "At least one DNS server is required."; return; }
        [ "$(uget mwadmin.adult)" = "adult" ] || uci set mwadmin.adult='adult'
        uci -q delete mwadmin.adult.prev
        for s in $servers; do uci add_list mwadmin.adult.prev="$s"; done
        uci set mwadmin.adult.prev_noresolv="$([ "$ignore" = "0" ] && echo 0 || echo 1)"
        uci commit mwadmin
        json_ok "$(jstr message 'DNS settings saved.')"
        return
    fi
    uci -q delete dhcp.@dnsmasq[0].server
    local n=0
    for s in $servers; do
        valid_ipv4 "$s" || { json_error "Invalid DNS server: $s"; return; }
        uci add_list dhcp.@dnsmasq[0].server="$s"
        n=$((n + 1))
    done
    [ $n -eq 0 ] && { json_error "At least one DNS server is required."; return; }
    uci set dhcp.@dnsmasq[0].noresolv="$([ "$ignore" = "0" ] && echo 0 || echo 1)"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    json_ok "$(jstr message 'DNS settings saved.')"
}

api_adblock_get() {
    local f="/var/run/adblock/adblock.runtime.json" enabled status domains lastrun
    enabled=$(uget_d adblock.global.adb_enabled 0)
    if [ -f "$f" ]; then
        status=$(sed -n 's/.*"adblock_status": *"\([^"]*\)".*/\1/p' "$f")
        domains=$(sed -n 's/.*"blocked_domains": *"\([^"]*\)".*/\1/p' "$f")
        lastrun=$(sed -n 's/.*"last_run": *"\([^"]*\)".*/\1/p' "$f")
    fi
    printf '{"ok":true,%s,%s,%s,%s}\n' \
        "$(jbool enabled "$enabled")" \
        "$(jstr status "${status:-unknown}")" \
        "$(jstr blocked_domains "${domains:-0}")" \
        "$(jstr last_run "${lastrun:--}")"
}

api_adblock_set() {
    [ -x /etc/init.d/adblock ] || { json_error "The ad blocker is not installed on this router (removed to save space). Install the adblock package to use it."; return; }
    local enabled; enabled=$(bodyval enabled)
    uci set adblock.global.adb_enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit adblock
    if [ "$enabled" = "1" ]; then
        /etc/init.d/adblock enable >/dev/null 2>&1
        # start IS the fetch-and-load run — adblock.sh is a procd-managed
        # instance, not a standalone CLI tool, so there is no separate
        # "-f force fetch" call to make on top of this. Confirmed by testing:
        # a bare `adblock.sh -f` silently did nothing, while `start` reliably
        # produces a real run within ~10s.
        /etc/init.d/adblock start >/dev/null 2>&1
    else
        /etc/init.d/adblock stop >/dev/null 2>&1
    fi
    log "adblock $([ "$enabled" = "1" ] && echo enabled || echo disabled)"
    json_ok "$(jstr message "Ad blocking $([ "$enabled" = "1" ] && echo "enabled — the first blocklist fetch is running now, this can take a minute" || echo "disabled").")"
}

# ===========================================================================
# CUSTOM BLOCKLIST — specific sites, on top of adblock's ad/tracker feeds.
# ===========================================================================
# adblock (above) is a big third-party feed; this is a short, user-owned list
# of specific domains ("I want facebook.com blocked on this network"),
# authoritative copy kept in uci (mwadmin.blocklist.domain, a plain list),
# rendered into a delimited block inside /etc/dnsmasq.conf — the one plain
# config file OpenWrt's dnsmasq init script always includes verbatim for the
# default instance, so no uci "confdir" plumbing is needed. The BEGIN/END
# markers mean this can be regenerated from scratch every time without
# touching anything a human (or another feature) put in that file by hand.
blocklist_regenerate() {
    local f="/etc/dnsmasq.conf" tmp="/tmp/dnsmasq.conf.new" enabled games_enabled d
    enabled=$(uget_d mwadmin.blocklist.enabled 1)
    games_enabled=$(uget_d mwadmin.blocklist.games_enabled 0)
    awk '
        /^### mwadmin-blocklist BEGIN/ { skip=1 }
        /^### mwadmin-blocklist END/   { skip=0; next }
        !skip
    ' "$f" 2>/dev/null > "$tmp"
    if [ "$enabled" = "1" ] || [ "$games_enabled" = "1" ]; then
        {
            echo '### mwadmin-blocklist BEGIN — managed by the admin UI, do not edit by hand ###'
            if [ "$enabled" = "1" ]; then
                for d in $(uci -q get mwadmin.blocklist.domain 2>/dev/null); do
                    echo "address=/$d/0.0.0.0"
                done
            fi
            if [ "$games_enabled" = "1" ]; then
                for d in $(uci -q get mwadmin.blocklist.games_domain 2>/dev/null); do
                    echo "address=/$d/0.0.0.0"
                done
            fi
            echo '### mwadmin-blocklist END ###'
        } >> "$tmp"
    fi
    mv "$tmp" "$f"
}

# A starter set of well-known gaming platforms/services — not sourced from any
# third-party feed (no reputable, embedded-sized public "block video games"
# list exists the way ad/porn/gambling ones do; the closest adblock.feeds
# entry, games_tracking, blocks in-game telemetry, not the platforms
# themselves). Ships as an editable starting point via the same add/remove
# endpoints as the custom list, not a claim of completeness.
GAMES_DEFAULT_DOMAINS="store.steampowered.com steamcommunity.com steamcontent.com
epicgames.com store.epicgames.com
roblox.com rbxcdn.com
xboxlive.com xbox.com
playstation.net playstation.com
nintendo.net nintendo.com
battle.net blizzard.com
riotgames.com leagueoflegends.com valorant.com
ea.com origin.com
ubisoft.com ubi.com
itch.io
twitch.tv
miniclip.com
poki.com
coolmathgames.com
kongregate.com
crazygames.com
y8.com"

api_blocklist_get() {
    printf '{"ok":true,%s,"domains":[' "$(jbool enabled "$(uget_d mwadmin.blocklist.enabled 1)")"
    local first=1 d
    for d in $(uci -q get mwadmin.blocklist.domain 2>/dev/null); do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '"%s"' "$(json_escape "$d")"
    done
    printf ']}\n'
}

api_blocklist_add() {
    local domain; domain=$(bodyval domain)
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    valid_host "$domain" || { json_error "Invalid domain — letters, digits, dots, and hyphens only."; return; }
    case "$domain" in *.*) ;; *) json_error "Enter a real domain, e.g. example.com."; return ;; esac

    local existing
    for existing in $(uci -q get mwadmin.blocklist.domain 2>/dev/null); do
        [ "$existing" = "$domain" ] && { json_error "$domain is already blocked."; return; }
    done

    uci set mwadmin.blocklist='blocklist'
    uci add_list mwadmin.blocklist.domain="$domain"
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    log "blocklist: added $domain"
    json_ok "$(jstr message "$domain blocked.")"
}

api_blocklist_del() {
    local domain; domain=$(bodyval domain)
    [ -z "$domain" ] && { json_error "No domain given."; return; }
    uci del_list mwadmin.blocklist.domain="$domain" 2>/dev/null
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    log "blocklist: removed $domain"
    json_ok "$(jstr message "$domain unblocked.")"
}

api_blocklist_set() {
    local enabled; enabled=$(bodyval enabled)
    uci set mwadmin.blocklist='blocklist'
    uci set mwadmin.blocklist.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    json_ok "$(jstr message "Custom blocklist $([ "$enabled" = "1" ] && echo enabled || echo disabled).")"
}

# ===========================================================================
# CATEGORY BLOCKING — one-click "18+ content" and "games" toggles.
# ===========================================================================
# 18+ content: see adult.sh (applies to every device, never-blocked ones too).

# Games uses the same mechanism as the general custom blocklist (a short,
# small list rendered straight into dnsmasq.conf), not adblock — there is no
# appropriately-sized public feed for "gaming platforms" (see the note by
# GAMES_DEFAULT_DOMAINS above). First enable seeds the starter list so the
# toggle does something useful immediately; it is then just an editable list
# like the custom blocklist.
api_blocklist_games_get() {
    printf '{"ok":true,%s,"domains":[' "$(jbool enabled "$(uget_d mwadmin.blocklist.games_enabled 0)")"
    local first=1 d
    for d in $(uci -q get mwadmin.blocklist.games_domain 2>/dev/null); do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '"%s"' "$(json_escape "$d")"
    done
    printf ']}\n'
}

api_blocklist_games_set() {
    local enabled; enabled=$(bodyval enabled)
    uci set mwadmin.blocklist='blocklist'
    if [ "$enabled" = "1" ] && [ -z "$(uci -q get mwadmin.blocklist.games_domain 2>/dev/null)" ]; then
        local d
        for d in $GAMES_DEFAULT_DOMAINS; do
            uci add_list mwadmin.blocklist.games_domain="$d"
        done
    fi
    uci set mwadmin.blocklist.games_enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    json_ok "$(jstr message "Games blocking $([ "$enabled" = "1" ] && echo enabled || echo disabled).")"
}

api_blocklist_games_add() {
    local domain; domain=$(bodyval domain)
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    valid_host "$domain" || { json_error "Invalid domain — letters, digits, dots, and hyphens only."; return; }
    case "$domain" in *.*) ;; *) json_error "Enter a real domain, e.g. example.com."; return ;; esac
    local existing
    for existing in $(uci -q get mwadmin.blocklist.games_domain 2>/dev/null); do
        [ "$existing" = "$domain" ] && { json_error "$domain is already blocked."; return; }
    done
    uci set mwadmin.blocklist='blocklist'
    uci add_list mwadmin.blocklist.games_domain="$domain"
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    json_ok "$(jstr message "$domain blocked.")"
}

api_blocklist_games_del() {
    local domain; domain=$(bodyval domain)
    [ -z "$domain" ] && { json_error "No domain given."; return; }
    uci del_list mwadmin.blocklist.games_domain="$domain" 2>/dev/null
    uci commit mwadmin
    blocklist_regenerate
    ( sleep 1; /etc/init.d/dnsmasq restart ) >/dev/null 2>&1 &
    json_ok "$(jstr message "$domain unblocked.")"
}

api_ddns_get() {
    printf '{"ok":true,"services":['
    local first=1 s
    for s in $(uci show ddns 2>/dev/null | sed -n "s/^ddns\.\([a-z0-9_]*\)=service$/\1/p"); do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s}' \
            "$(jstr id "$s")" "$(jstr provider "$(uget ddns.$s.service_name)")" \
            "$(jstr domain "$(uget ddns.$s.domain)")" \
            "$(jstr username "$(uget ddns.$s.username)")" \
            "$(jbool enabled "$(uget_d ddns.$s.enabled 0)")"
    done
    printf ']}\n'
}

api_ddns_set() {
    local provider domain username password enabled iface
    provider=$(bodyval provider); domain=$(bodyval domain)
    username=$(bodyval username); password=$(bodyval password)
    enabled=$(bodyval enabled); iface=$(bodyval interface)

    [ -f /etc/config/ddns ] || { json_error "ddns-scripts is not installed."; return; }
    case "$provider" in ''|*[!a-zA-Z0-9._-]*) json_error "Invalid provider name."; return ;; esac
    valid_host "$domain" || { json_error "Invalid domain name."; return; }
    valid_iface "${iface:-wan1}" || { json_error "Invalid interface."; return; }

    uci set ddns.mwddns='service'
    uci set ddns.mwddns.service_name="$provider"
    uci set ddns.mwddns.domain="$domain"
    uci set ddns.mwddns.username="$username"
    [ -n "$password" ] && uci set ddns.mwddns.password="$password"
    uci set ddns.mwddns.interface="${iface:-wan1}"
    uci set ddns.mwddns.ip_source='web'
    uci set ddns.mwddns.ip_url='http://checkip.amazonaws.com'
    uci set ddns.mwddns.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit ddns
    /etc/init.d/ddns restart >/dev/null 2>&1
    json_ok "$(jstr message 'DDNS configuration saved.')"
}

# ===========================================================================
# ALERTS — email on WAN outage, via msmtp + /etc/mwan3.user.
# ===========================================================================
api_alerts_get() {
    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(jbool installed "$(command -v msmtp >/dev/null 2>&1 && echo 1 || echo 0)")" \
        "$(jbool enabled "$(uget_d mwadmin.alerts.enabled 0)")" \
        "$(jstr smtp_host "$(uget mwadmin.alerts.smtp_host)")" \
        "$(jstr smtp_port "$(uget_d mwadmin.alerts.smtp_port 587)")" \
        "$(jstr smtp_user "$(uget mwadmin.alerts.smtp_user)")" \
        "$(jbool smtp_has_password "$([ -n "$(uget mwadmin.alerts.smtp_pass)" ] && echo 1 || echo 0)")" \
        "$(jstr smtp_from "$(uget mwadmin.alerts.smtp_from)")" \
        "$(jstr alert_to "$(uget mwadmin.alerts.alert_to)")" \
        "$(jbool alert_wan1_down "$(uget_d mwadmin.alerts.alert_wan1_down 1)")" \
        "$(jbool alert_all_down "$(uget_d mwadmin.alerts.alert_all_down 1)")"
}

api_alerts_set() {
    local enabled host port user pass from to a1 aall
    enabled=$(bodyval enabled); host=$(bodyval smtp_host); port=$(bodyval smtp_port)
    user=$(bodyval smtp_user); pass=$(bodyval smtp_pass); from=$(bodyval smtp_from)
    to=$(bodyval alert_to); a1=$(bodyval alert_wan1_down); aall=$(bodyval alert_all_down)

    if [ "$enabled" = "1" ]; then
        command -v msmtp >/dev/null 2>&1 || { json_error "msmtp is not installed. Enable FEAT_ALERTS in mwan.env and re-run 00-packages.sh."; return; }
        [ -n "$host" ] || { json_error "SMTP server is required."; return; }
        [ -n "$user" ] || { json_error "SMTP username is required."; return; }
        [ -n "$from" ] || { json_error "\"From\" address is required."; return; }
        valid_host "$to" || { json_error "A valid alert-to address is required."; return; }
        valid_int "$port" || { json_error "Port must be a number."; return; }
    fi

    uci set mwadmin.alerts='alerts'
    uci set mwadmin.alerts.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    [ -n "$host" ] && uci set mwadmin.alerts.smtp_host="$host"
    [ -n "$port" ] && uci set mwadmin.alerts.smtp_port="$port"
    [ -n "$user" ] && uci set mwadmin.alerts.smtp_user="$user"
    [ -n "$pass" ] && uci set mwadmin.alerts.smtp_pass="$pass"
    [ -n "$from" ] && uci set mwadmin.alerts.smtp_from="$from"
    [ -n "$to" ]   && uci set mwadmin.alerts.alert_to="$to"
    uci set mwadmin.alerts.alert_wan1_down="$([ "$a1" = "0" ] && echo 0 || echo 1)"
    uci set mwadmin.alerts.alert_all_down="$([ "$aall" = "0" ] && echo 0 || echo 1)"
    uci commit mwadmin

    chmod 755 /etc/mwan3.user 2>/dev/null
    log "alerts configuration saved (enabled=$enabled)"
    json_ok "$(jstr message 'Alert settings saved.')"
}

api_alerts_test() {
    command -v msmtp >/dev/null 2>&1 || { json_error "msmtp is not installed."; return; }
    [ "$(uget_d mwadmin.alerts.enabled 0)" = "1" ] || { json_error "Save and enable alerts before sending a test."; return; }
    if /usr/lib/mwadmin/send_alert.sh "Test alert" \
        "This is a test message from the MultiWAN admin panel. If you received this, outage alerts are configured correctly." \
        >/tmp/alert-test.log 2>&1
    then
        json_ok "$(jstr message 'Test email sent. Check the inbox — and spam folder — for the alert-to address.')"
    else
        json_error "Send failed: $(tail -1 /tmp/msmtp-lastrun.log 2>/dev/null || echo 'see logread for details')"
    fi
}

api_qos_get() {
    printf '{"ok":true,"queues":['
    local first=1 s
    for s in $(uci show sqm 2>/dev/null | sed -n "s/^sqm\.\([a-z0-9_]*\)=queue$/\1/p"); do
        [ $first -eq 0 ] && printf ','
        first=0
        printf '{%s,%s,%s,%s,%s}' \
            "$(jstr id "$s")" "$(jstr interface "$(uget sqm.$s.interface)")" \
            "$(jnum download "$(uget sqm.$s.download)")" \
            "$(jnum upload "$(uget sqm.$s.upload)")" \
            "$(jbool enabled "$(uget_d sqm.$s.enabled 0)")"
    done
    printf '],%s}\n' "$(jstr note 'SQM on this CPU saturates near 100-200 Mbps. Recommended on WAN2/WAN3 only; enabling it on WAN1 will cost you throughput.')"
}

api_qos_set() {
    local iface down up enabled
    iface=$(bodyval interface); down=$(bodyval download); up=$(bodyval upload); enabled=$(bodyval enabled)

    [ -f /etc/config/sqm ] || { json_error "sqm-scripts is not installed."; return; }
    valid_iface "$iface" || { json_error "Invalid interface."; return; }
    valid_int "$down" || { json_error "Download limit must be a number (kbit/s)."; return; }
    valid_int "$up"   || { json_error "Upload limit must be a number (kbit/s)."; return; }

    local dev; dev=$(uget "network.$iface.device")
    [ -z "$dev" ] && { json_error "Interface has no device."; return; }

    local sect="sqm_$iface"
    uci set sqm.$sect='queue'
    uci set sqm.$sect.interface="$dev"
    uci set sqm.$sect.download="$down"
    uci set sqm.$sect.upload="$up"
    uci set sqm.$sect.qdisc='cake'
    uci set sqm.$sect.script='piece_of_cake.qos'
    uci set sqm.$sect.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    uci commit sqm
    /etc/init.d/sqm restart >/dev/null 2>&1

    local warn=""
    [ "$iface" = "wan1" ] && [ "$enabled" = "1" ] && \
        warn=" Warning: SQM is now active on WAN1. Expect routed throughput to drop to roughly 100-200 Mbps."
    json_ok "$(jstr message "QoS saved.$warn")"
}

# ===========================================================================
# FAILOVER TEST — proves the fallback actually works, not just that it's
# configured. Cuts WAN1's tracking pings (not the interface itself, so this
# exercises the exact same detection path a real outage would), times how
# long mwan3 takes to move traffic off it, then restores it and times the
# failback.
#
# SAFETY: this blocks internet on WAN1 for the ~15-20s the test takes. The
# unblock is UNCONDITIONAL — it runs right after the failover-detection loop
# regardless of whether failover was even detected, so a WAN2 that turns out
# not to be reachable degrades the test to "no failover recorded," never to
# "WAN1 stays blocked." The whole thing also runs under `trap ... EXIT` as a
# second, independent guarantee, and a hard 45s ceiling. A previous manual
# version of this test (run ad hoc over SSH during development, not through
# this endpoint) got killed by an external timeout mid-test and left its
# block rule in place — this endpoint exists specifically so that can't
# happen to a real user.
# ===========================================================================
api_failover_test_start() {
    if ! lock_acquire "failovertest"; then
        json_error "A failover test is already running."
        return
    fi

    local out="$MW_RUN/failover_test.json"
    write_ft() { printf '%s\n' "$1" > "$out"; }

    if [ "$(uget_d mwan3.wan1.enabled 1)" != "1" ]; then
        lock_release "failovertest"
        json_error "WAN1 is turned off, so there is nothing to fail over from."
        return
    fi
    if [ "$(cat /sys/class/net/wan/carrier 2>/dev/null)" != "1" ]; then
        lock_release "failovertest"
        json_error "WAN1 has no cable plugged in."
        return
    fi

    write_ft '{"status":"running","phase":"starting"}'

    (
        trap 'nft delete table inet mwfailtest >/dev/null 2>&1; lock_release failovertest' EXIT INT TERM

        active_wan() {
            mwan3 status 2>/dev/null | awk '
                /Current ipv4 policies/ { inpol = 1; next }
                inpol && /^[a-zA-Z_]+:/  { next }
                inpol && /\(/            { gsub(/^[ \t]+/, ""); print $1; exit }
            '
        }

        write_ft '{"status":"running","phase":"blocking_wan1"}'
        nft add table inet mwfailtest 2>/dev/null
        nft add chain inet mwfailtest out '{ type filter hook output priority -1 ; policy accept ; }' 2>/dev/null
        nft add rule inet mwfailtest out oifname "wan" ip protocol icmp drop 2>/dev/null

        t0=$(date +%s)
        failover_s="" new_active=""
        i=0
        while [ $i -lt 20 ]; do
            a=$(active_wan)
            if [ -n "$a" ] && [ "$a" != "wan1" ]; then
                failover_s=$(( $(date +%s) - t0 ))
                new_active="$a"
                break
            fi
            write_ft "{\"status\":\"running\",\"phase\":\"waiting_for_failover\",\"elapsed_s\":$(( $(date +%s) - t0 ))}"
            sleep 1
            i=$((i + 1))
        done

        if [ -n "$failover_s" ]; then
            write_ft "{\"status\":\"running\",\"phase\":\"failed_over\",\"failover_seconds\":$failover_s,\"new_active\":\"$new_active\"}"
        else
            write_ft '{"status":"running","phase":"failover_timed_out"}'
        fi

        # Unconditional: runs whether or not failover was detected above.
        nft delete table inet mwfailtest >/dev/null 2>&1

        t1=$(date +%s)
        failback_s=""
        i=0
        while [ $i -lt 20 ]; do
            a=$(active_wan)
            if [ "$a" = "wan1" ]; then
                failback_s=$(( $(date +%s) - t1 ))
                break
            fi
            sleep 1
            i=$((i + 1))
        done

        printf '{"status":"complete",%s,%s,%s,%s}\n' \
            "$(jnum failover_seconds "${failover_s:-}")" \
            "$(jstr new_active_during_test "${new_active:-}")" \
            "$(jnum failback_seconds "${failback_s:-}")" \
            "$(jnum tested_at "$(date +%s)")" > "$out"

        log "failover test complete: failover=${failover_s:-timeout}s failback=${failback_s:-timeout}s"
    ) >/tmp/mwadmin/failover_test.log 2>&1 &

    json_ok "$(jstr message 'Failover test started. WAN1 will be briefly cut and restored — this takes about 15-20 seconds.')"
}

api_failover_test_result() {
    if [ -f "$MW_RUN/failover_test.json" ]; then
        cat "$MW_RUN/failover_test.json"
    else
        printf '{"status":"never_run"}\n'
    fi
}

api_wg_get() {
    local present=0
    command -v wg >/dev/null 2>&1 && present=1
    printf '{"ok":true,%s,"peers":[' "$(jbool installed "$present")"
    if [ "$present" = "1" ]; then
        local first=1 s
        for s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([a-z0-9_]*\)=wireguard_.*$/\1/p"); do
            [ $first -eq 0 ] && printf ','
            first=0
            printf '{%s,%s,%s}' \
                "$(jstr id "$s")" \
                "$(jstr description "$(uget network.$s.description)")" \
                "$(jstr endpoint "$(uget network.$s.endpoint_host)")"
        done
    fi
    printf '],%s,%s}\n' \
        "$(jstr iface "$(uci show network 2>/dev/null | sed -n "s/^network\.\([a-z0-9_]*\)\.proto='wireguard'$/\1/p" | head -n1)")" \
        "$(jstr note 'WireGuard on this router is CPU-bound at roughly 82-99 Mbps. Routing all traffic through a tunnel will cap your throughput at about that.')"
}

api_wg_keygen() {
    command -v wg >/dev/null 2>&1 || { json_error "wireguard-tools is not installed."; return; }
    local priv pub
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    json_ok "$(printf '%s,%s' "$(jstr private_key "$priv")" "$(jstr public_key "$pub")")"
}

# ===========================================================================
# REMOTE ACCESS — outbound SSH relay tunnel for internet admin access.
# ===========================================================================
# This router never accepts an inbound connection from the internet. Instead
# it opens an outbound SSH connection to a relay host you control (a VPS, a
# shared hosting account with SSH — anything that accepts SSH and permits
# AllowTcpForwarding) and asks it to forward one of its own loopback ports
# back to this router's admin UI. Public HTTPS termination and the reverse
# proxy from a real domain to that loopback port happen on the relay host,
# outside this app's control — see the admin UI's Remote Access page for the
# exact steps. package/init.d/mwremote is what actually runs the tunnel;
# this section only manages configuration, key material, and status.
#
# The private key is generated on-router and never leaves it — api_remote_
# keygen writes it straight to flash and returns only the public half.
# Pasting that public key into the relay host's authorized_keys is the one
# manual step this app cannot do for you.
# The private key is in Dropbear's format (dbclient); the public half keeps
# its old name so the Remote Access page shows it as before.
REMOTE_KEYFILE="$MW_STATE/remote_id_dropbear"
REMOTE_PUBFILE="$MW_STATE/remote_id_ed25519.pub"

# Ties the history-offload cron job (package/lib/history_offload.sh) to
# whether a relay host is actually enabled — no relay, no point running it,
# and it already no-ops safely on its own if run with nothing configured, but
# not scheduling it at all is one less wakeup on a device this constrained.
sync_offload_cron() {
    local want="$1" f="/etc/crontabs/root" changed=0
    touch "$f" 2>/dev/null
    if [ "$want" = "1" ]; then
        grep -qF 'history_offload.sh' "$f" 2>/dev/null || {
            echo '*/30 * * * * /usr/lib/mwadmin/history_offload.sh' >> "$f"
            changed=1
        }
        # Shorter interval than history: nlbwmon's own counters live only in
        # RAM and reset on reboot, so a crash between offloads loses whatever
        # hasn't shipped yet. Bounding that window matters more here — this
        # device has demonstrated it can crash under load.
        grep -qF 'bandwidth_offload.sh' "$f" 2>/dev/null || {
            echo '*/5 * * * * /usr/lib/mwadmin/bandwidth_offload.sh' >> "$f"
            changed=1
        }
    else
        if grep -qE 'history_offload\.sh|bandwidth_offload\.sh' "$f" 2>/dev/null; then
            grep -vE 'history_offload\.sh|bandwidth_offload\.sh' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            changed=1
        fi
    fi
    [ "$changed" = "1" ] && /etc/init.d/cron restart >/dev/null 2>&1
}

# Whether the relay host is usable for offloading data to at all — distinct
# from mwadmin.remote.enabled, which is specifically about the admin-panel
# relay tunnel (Method 1 on the Remote Access page). A relay host can be
# configured and used for data offload without ever exposing the admin
# panel through it, and vice versa.
offload_ready() {
    [ -n "$(uget mwadmin.remote.host)" ] && [ -n "$(uget mwadmin.remote.user)" ] && [ -f "$REMOTE_KEYFILE" ]
}

api_remote_get() {
    local installed=0
    command -v dbclient >/dev/null 2>&1 && installed=1
    local pubkey=""
    [ -f "$REMOTE_PUBFILE" ] && pubkey=$(cat "$REMOTE_PUBFILE" 2>/dev/null)

    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(jbool installed "$installed")" \
        "$(jbool has_key "$([ -n "$pubkey" ] && echo 1 || echo 0)")" \
        "$(jbool enabled "$(uget_d mwadmin.remote.enabled 0)")" \
        "$(jstr host "$(uget mwadmin.remote.host)")" \
        "$(jstr user "$(uget mwadmin.remote.user)")" \
        "$(jstr ssh_port "$(uget_d mwadmin.remote.ssh_port 22)")" \
        "$(jstr remote_port "$(uget mwadmin.remote.remote_port)")" \
        "$(jstr public_key "$pubkey")"
}

api_remote_set() {
    local enabled host user ssh_port remote_port
    enabled=$(bodyval enabled); host=$(bodyval host); user=$(bodyval user)
    ssh_port=$(bodyval ssh_port); remote_port=$(bodyval remote_port)
    [ -z "$ssh_port" ] && ssh_port=22

    if [ "$enabled" = "1" ]; then
        command -v dbclient >/dev/null 2>&1 || { json_error "ssh client not available on this device."; return; }
        [ -f "$REMOTE_KEYFILE" ] || { json_error "Generate a key before enabling remote access."; return; }
        valid_host "$host" || { json_error "Invalid relay host."; return; }
        case "$user" in ''|*[!a-zA-Z0-9_-]*) json_error "Invalid relay username."; return ;; esac
        valid_int "$ssh_port" || { json_error "SSH port must be a number."; return; }
        valid_int "$remote_port" || { json_error "Remote (loopback) port must be a number."; return; }
        [ "$remote_port" -ge 1024 ] 2>/dev/null || { json_error "Remote port must be 1024 or higher — most relay hosts don't allow a regular user to bind privileged ports."; return; }
    fi

    uci set mwadmin.remote='remote'
    uci set mwadmin.remote.enabled="$([ "$enabled" = "1" ] && echo 1 || echo 0)"
    [ -n "$host" ] && uci set mwadmin.remote.host="$host"
    [ -n "$user" ] && uci set mwadmin.remote.user="$user"
    uci set mwadmin.remote.ssh_port="$ssh_port"
    [ -n "$remote_port" ] && uci set mwadmin.remote.remote_port="$remote_port"
    uci commit mwadmin
    log "remote access settings saved (enabled=$enabled)"

    if [ "$enabled" = "1" ]; then
        ( sleep 1; /etc/init.d/mwremote enable; /etc/init.d/mwremote restart ) >/dev/null 2>&1 &
    else
        ( sleep 1; /etc/init.d/mwremote stop; /etc/init.d/mwremote disable ) >/dev/null 2>&1 &
    fi
    sync_offload_cron "$(offload_ready && echo 1 || echo 0)"
    json_ok "$(jstr message 'Remote access settings saved.')"
}

api_remote_keygen() {
    command -v dropbearkey >/dev/null 2>&1 || { json_error "ssh client not available on this device."; return; }
    mkdir -p "$MW_STATE"
    rm -f "$REMOTE_KEYFILE" "$REMOTE_PUBFILE" "$MW_STATE/remote_id_ed25519"
    dropbearkey -t ed25519 -f "$REMOTE_KEYFILE" >/dev/null 2>&1
    dropbearkey -y -f "$REMOTE_KEYFILE" 2>/dev/null | grep '^ssh-ed25519 ' | awk -v c="mwadmin-$(uget system.@system[0].hostname)" '{ print $1, $2, c }' > "$REMOTE_PUBFILE"
    if [ ! -s "$REMOTE_PUBFILE" ]; then
        json_error "Key generation failed."
        return
    fi
    chmod 600 "$REMOTE_KEYFILE"
    log "remote access key (re)generated"
    json_ok "$(jstr public_key "$(cat "$REMOTE_PUBFILE")")"
}

# Reports whether the tunnel process procd is supervising is actually alive,
# and roughly how long it's been up — the pidfile's own mtime is close enough
# for "since" without parsing /proc/<pid>/stat for an exact start time.
api_remote_status() {
    local running=0 since="null" pidfile="/var/run/mwremote.pid"
    if [ -f "$pidfile" ]; then
        local pid; pid=$(cat "$pidfile" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            running=1
            since=$(stat -c %Y "$pidfile" 2>/dev/null)
            [ -z "$since" ] && since="null"
        fi
    fi
    printf '{"ok":true,%s,%s,%s}\n' \
        "$(jbool enabled "$(uget_d mwadmin.remote.enabled 0)")" \
        "$(jbool running "$running")" \
        "$(jnum since "$since")"
}

# ===========================================================================
# UPDATES — check the project's public GitHub repo for a newer version and
# apply it in place, from the Easy and Advanced UIs alike.
# ===========================================================================
# Sourced from GitHub, not the relay host: this router's ca-certificates
# bundle verifies github.com/raw.githubusercontent.com fine (confirmed
# live), but fails to validate mikaelbhai.com's certificate chain — using
# GitHub sidesteps that entirely and needs no separate hosting upkeep.
UPDATE_RAW_BASE="https://raw.githubusercontent.com/mikaelbhai/MultiWAN/main"
UPDATE_VERSION_FILE="$MW_STATE/version"
UPDATE_STATUS_FILE="$MW_RUN/update_status.json"

# repo-path:router-path pairs, one per shipped file — kept in exact sync
# with deploy.sh/deploy.ps1's own copy list, since an update is "what
# deploy.sh would copy," fetched over HTTPS one file at a time instead of
# over SSH. A colon can't appear in either half (paths, not URLs).
UPDATE_FILES='package/www/index.html:/www/mwadmin/index.html
package/www/advanced.html:/www/mwadmin/advanced.html
package/www/app.js:/www/mwadmin/app.js
package/www/app.css:/www/mwadmin/app.css
package/www/simple.js:/www/mwadmin/simple.js
package/www/simple.css:/www/mwadmin/simple.css
package/cgi-bin/mwadmin:/www/mwadmin/cgi-bin/mwadmin
package/lib/api.sh:/usr/lib/mwadmin/api.sh
package/lib/common.sh:/usr/lib/mwadmin/common.sh
package/lib/modeswitch.sh:/usr/lib/mwadmin/modeswitch.sh
package/lib/portdetect.sh:/usr/lib/mwadmin/portdetect.sh
package/lib/site.sh:/usr/lib/mwadmin/site.sh
package/lib/insight.sh:/usr/lib/mwadmin/insight.sh
package/lib/guest.sh:/usr/lib/mwadmin/guest.sh
package/lib/block.sh:/usr/lib/mwadmin/block.sh
package/init.d/mwblock:/etc/init.d/mwblock
package/www-guest/cgi-bin/guest:/www/mwguest/cgi-bin/guest
package/lib/send_alert.sh:/usr/lib/mwadmin/send_alert.sh
package/lib/history_offload.sh:/usr/lib/mwadmin/history_offload.sh
package/hotplug/95-mwadmin-portdetect:/etc/hotplug.d/iface/95-mwadmin-portdetect
package/init.d/mwadmin:/etc/init.d/mwadmin
package/init.d/mwremote:/etc/init.d/mwremote
package/etc/mwan3.user:/etc/mwan3.user'

api_update_check() {
    local current latest
    current=$(cat "$UPDATE_VERSION_FILE" 2>/dev/null)
    [ -z "$current" ] && current="unknown"
    latest=$(curl -fsS -m 10 "$UPDATE_RAW_BASE/VERSION" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$latest" ]; then
        json_error "Could not reach GitHub to check for updates."
        return
    fi
    printf '{"ok":true,%s,%s,%s}\n' \
        "$(jstr current "$current")" "$(jstr latest "$latest")" \
        "$(jbool update_available "$([ "$current" != "$latest" ] && echo 1 || echo 0)")"
}

# Downloads every shipped file to a scratch dir on tmpfs, verifies each one
# (non-empty, and shell scripts must pass `sh -n`) and only THEN copies them
# over the real, running files — so a network hiccup or a bad file mid-way
# leaves the installed app completely untouched rather than half-updated.
# Runs detached (same reasoning as api_node_test_start: the lock must be
# held by the long-running process, not this short-lived CGI request).
api_update_apply() {
    [ -d "$MW_RUN/locks/update.lock" ] && { json_error "An update is already in progress."; return; }
    mkdir -p "$MW_RUN"
    printf '{"status":"running","step":"starting"}\n' > "$UPDATE_STATUS_FILE"

    ( setsid sh -c '
        . /usr/lib/mwadmin/common.sh
        lock_acquire "update" || exit 0
        raw_base="$1"; version_file="$2"; status_file="$3"; files="$4"
        stage="'"$MW_RUN"'/update_stage"
        rm -rf "$stage"; mkdir -p "$stage"
        status() { printf "{\"status\":\"%s\",\"step\":\"%s\"}\n" "$1" "$2" > "$status_file"; }

        status running downloading
        if ! printf "%s\n" "$files" | while IFS=: read -r repo_path router_path; do
            [ -z "$repo_path" ] && continue
            dest="$stage/$(basename "$router_path")"
            curl -fsS -m 20 "$raw_base/$repo_path" -o "$dest" || exit 1
            [ -s "$dest" ] || exit 1
        done; then
            status error "download failed - nothing was changed"
            lock_release "update"; exit 0
        fi

        status running verifying
        bad=0
        for f in "$stage"/*.sh "$stage"/mwadmin "$stage"/mwremote "$stage"/mwan3.user "$stage"/95-mwadmin-portdetect; do
            [ -f "$f" ] || continue
            sh -n "$f" 2>/dev/null || bad=1
        done
        if [ "$bad" = 1 ]; then
            status error "a downloaded file failed a syntax check - nothing was changed"
            lock_release "update"; exit 0
        fi

        status running installing
        printf "%s\n" "$files" | while IFS=: read -r repo_path router_path; do
            [ -z "$repo_path" ] && continue
            src="$stage/$(basename "$router_path")"
            [ -f "$src" ] && cp -f "$src" "$router_path"
        done
        chmod 755 /www/mwadmin/cgi-bin/mwadmin /etc/init.d/mwadmin /etc/init.d/mwremote \
            /etc/hotplug.d/iface/95-mwadmin-portdetect /etc/mwan3.user 2>/dev/null
        chmod 644 /usr/lib/mwadmin/*.sh /www/mwadmin/*.html /www/mwadmin/*.css /www/mwadmin/*.js 2>/dev/null

        latest=$(curl -fsS -m 10 "$raw_base/VERSION" 2>/dev/null | tr -d "[:space:]")
        [ -n "$latest" ] && printf "%s\n" "$latest" > "$version_file"

        rm -rf "$stage"
        status running restarting
        /etc/init.d/mwadmin restart >/dev/null 2>&1
        status done "applied ${latest:-update}"
        lock_release "update"
    ' _ "$UPDATE_RAW_BASE" "$UPDATE_VERSION_FILE" "$UPDATE_STATUS_FILE" "$UPDATE_FILES" >/dev/null 2>&1 & ) &

    json_ok "$(jstr message 'Update started.')"
}

api_update_status() {
    [ -f "$UPDATE_STATUS_FILE" ] && cat "$UPDATE_STATUS_FILE" || printf '{"status":"idle"}\n'
}

# ===========================================================================
# DIAGNOSTICS
# ===========================================================================
api_diag_ping() {
    local host iface dev
    host=$(bodyval host); iface=$(bodyval iface)
    valid_host "$host" || { json_error "Invalid host. Use a hostname or IP address."; return; }

    local bindarg=""
    if [ -n "$iface" ] && [ "$iface" != "auto" ]; then
        valid_iface "$iface" || { json_error "Invalid interface."; return; }
        dev=$(uget "network.$iface.device")
        [ -n "$dev" ] && bindarg="-I $dev"
    fi

    # host is allowlist-validated above, so this interpolation cannot inject.
    local out
    # shellcheck disable=SC2086
    out=$(ping $bindarg -c 5 -W 2 "$host" 2>&1 | head -c 4096)
    json_ok "$(jstr output "$out")"
}

api_diag_traceroute() {
    local host; host=$(bodyval host)
    valid_host "$host" || { json_error "Invalid host."; return; }
    command -v traceroute >/dev/null 2>&1 || { json_error "traceroute is not installed (opkg install traceroute)."; return; }
    local out; out=$(traceroute -m 15 -w 2 "$host" 2>&1 | head -c 8192)
    json_ok "$(jstr output "$out")"
}

api_syslog() {
    local n; n=$(qsval lines); valid_int "$n" || n=200
    [ "$n" -gt 1000 ] && n=1000
    local out; out=$(logread -l "$n" 2>/dev/null | tail -n "$n")
    json_ok "$(jstr log "$out")"
}

# ===========================================================================
# SYSTEM
# ===========================================================================
api_system_get() {
    # LuCI always lives on the primary LAN address, port 80 — which is not
    # necessarily the address this admin UI was itself reached on (it may be
    # the dedicated :80 alias, or the ROUTER_HOSTNAME, or the :8080 port).
    # The frontend needs the real one to link to it correctly.
    printf '{"ok":true,%s,%s,%s,%s,%s,%s,%s,%s,%s,"timezones":[%s]}\n' \
        "$(jstr hostname "$(uget system.@system[0].hostname)")" \
        "$(jstr timezone "$(uget system.@system[0].zonename)")" \
        "$(jstr local_time "$(date '+%Y-%m-%d %H:%M')")" \
        "$(jstr model "$(cat /tmp/sysinfo/model 2>/dev/null)")" \
        "$(jstr board "$(cat /tmp/sysinfo/board_name 2>/dev/null)")" \
        "$(jstr firmware "$(. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION")")" \
        "$(jstr flash_free "$(df -h /overlay 2>/dev/null | awk 'NR==2{print $4}')")" \
        "$(jnum uptime_s "$(awk '{printf "%d", $1}' /proc/uptime)")" \
        "$(jstr lan_ip "$(uget network.lan.ipaddr)")" \
        "$(printf '%s\n' "$TZ_TABLE" | awk -F'|' '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $1 }')"
}

# Zone name -> POSIX TZ rule (the list the admin panel offers).
TZ_TABLE='UTC|UTC0
Asia/Karachi|PKT-5
Asia/Kolkata|IST-5:30
Asia/Dubai|<+04>-4
Asia/Riyadh|<+03>-3
Asia/Dhaka|<+06>-6
Asia/Kabul|<+0430>-4:30
Asia/Tehran|<+0330>-3:30
Asia/Shanghai|CST-8
Asia/Singapore|<+08>-8
Asia/Tokyo|JST-9
Europe/London|GMT0BST,M3.5.0/1,M10.5.0
Europe/Paris|CET-1CEST,M3.5.0,M10.5.0/3
Europe/Istanbul|<+03>-3
America/New_York|EST5EDT,M3.2.0,M11.1.0
America/Chicago|CST6CDT,M3.2.0,M11.1.0
America/Los_Angeles|PST8PDT,M3.2.0,M11.1.0
Australia/Sydney|AEST-10AEDT,M10.1.0,M4.1.0/3'
tz_rule() { printf '%s\n' "$TZ_TABLE" | awk -F'|' -v z="$1" '$1 == z { print $2; f = 1 } END { exit !f }'; }

api_system_set() {
    local hostname timezone
    hostname=$(bodyval hostname); timezone=$(bodyval timezone)
    if [ -n "$hostname" ]; then
        valid_host "$hostname" || { json_error "Invalid hostname."; return; }
        uci set system.@system[0].hostname="$hostname"
    fi
    if [ -n "$timezone" ]; then
        # The clock follows system.timezone (a POSIX rule), not the name, and
        # this router has no zoneinfo database - so the name is looked up here.
        local tz
        tz=$(tz_rule "$timezone") || { json_error "Unknown timezone. Pick one from the list."; return; }
        uci set system.@system[0].zonename="$timezone"
        uci set system.@system[0].timezone="$tz"
    fi
    uci commit system
    /etc/init.d/system reload >/dev/null 2>&1
    json_ok "$(jstr message 'System settings saved.')"
}

api_password_set() {
    local old new
    old=$(bodyval old_password); new=$(bodyval new_password)
    [ ${#new} -lt 8 ] && { json_error "New password must be at least 8 characters."; return; }

    # Re-verify the current password rather than trusting the session alone.
    # A live session left open on an unattended machine should not be enough to
    # change the credential that protects everything else.
    local check
    check=$(ubus -S call session login "{\"username\":\"root\",\"password\":\"$(json_escape "$old")\",\"timeout\":5}" 2>/dev/null)
    printf '%s' "$check" | grep -q 'ubus_rpc_session' || {
        sleep 1; json_error "Current password is incorrect."; return; }

    printf '%s\n%s\n' "$new" "$new" | passwd root >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "root password changed via admin UI"
        json_ok "$(jstr message 'Password changed. Existing sessions remain valid until they expire.')"
    else
        json_error "Failed to change the password."
    fi
}

api_reboot() {
    log "reboot requested via admin UI"
    json_ok "$(jstr message 'Rebooting now. The router will be back in about 60 seconds.')"
    ( sleep 2; reboot ) >/dev/null 2>&1 &
}

# Config backup. Streams a real tarball, so this endpoint deliberately writes
# its own headers instead of JSON.
api_backup() {
    local f="/tmp/mwadmin-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    sysupgrade -b "$f" >/dev/null 2>&1
    if [ ! -f "$f" ]; then
        printf 'Status: 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n'
        json_error "Backup failed."
        return
    fi
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: application/octet-stream\r\n'
    printf 'Content-Disposition: attachment; filename="%s"\r\n' "$(basename "$f")"
    printf 'Content-Length: %s\r\n\r\n' "$(wc -c < "$f")"
    cat "$f"
    rm -f "$f"
}

# ===========================================================================
# DISPATCH
# ===========================================================================
api_dispatch() {
    local route="$1" method="$2"

    case "$route:$method" in
        /status:GET)              api_status ;;
        /ports:GET)               api_ports ;;
        /ports/assign:POST)       api_ports_assign ;;
        /ports/power:POST)        api_ports_power ;;
        /ports/test:POST)         api_port_test ;;
        /bandwidth:GET)           api_bandwidth ;;
        /devices:GET)             api_devices ;;
        /devices/limit:GET)       api_devlimit_get ;;
        /devices/limit:POST)      api_devlimit_set ;;
        /nodes:GET)               api_nodes_get ;;
        /nodes/add:POST)          api_nodes_add ;;
        /nodes/del:POST)          api_nodes_del ;;
        /nodes/test:POST)         api_node_test_start ;;
        /nodes/test:GET)          api_node_test_result ;;
        /history:GET)             api_history_get ;;

        /site:GET)                api_site_get ;;
        /site:POST)               api_site_set ;;
        /site/name:POST)          api_site_name ;;
        /site/force:POST)         api_site_force ;;
        /capabilities:GET)        api_capabilities ;;
        /connect:GET)             api_connect_get ;;
        /policy:GET)              printf '{"ok":true,"policy":%s,"archive":%s}\n' "$(sh /usr/lib/mwadmin/policy.sh status)" "$(sh /usr/lib/mwadmin/archive.sh status)" ;;
        /archive/run:POST)        sh /usr/lib/mwadmin/archive.sh tick >/dev/null 2>&1
                                  printf '{"ok":true,"archive":%s}\n' "$(sh /usr/lib/mwadmin/archive.sh status)" ;;
        /policy/sync:POST)        rm -f /tmp/mwadmin/policy.last /tmp/mwadmin/locks/plsync.lock 2>/dev/null; sh /usr/lib/mwadmin/policy.sh tick >/dev/null 2>&1
                                  printf '{"ok":true,"policy":%s}\n' "$(sh /usr/lib/mwadmin/policy.sh status)" ;;
        /connect:POST)            api_connect_post ;;
        /quality:GET)             api_quality_get ;;
        /quality/test:POST)       api_quality_test ;;
        /apps:GET)                api_apps_get ;;
        /apps/detail:GET)         api_apps_detail ;;
        /apps:POST)               api_apps_set ;;
        /guests:GET)              api_guests_get ;;
        /guests:POST)             api_guests_set ;;
        /guests/remove:POST)      api_guests_remove ;;
        /guests/allow:POST)       api_guests_allow ;;
        /sites:GET)               api_sites_get ;;
        /sites/block:POST)        api_sites_block ;;
        /sites/unblock:POST)      api_sites_unblock ;;
        /sites/decide:POST)       api_sites_decide ;;
        /pause:GET)               api_pause_get ;;
        /pause/settings:POST)     api_pause_settings ;;
        /pause/group:POST)        api_pause_group_save ;;
        /pause/group/delete:POST) api_pause_group_delete ;;
        /pause/toggle:POST)       api_pause_toggle ;;
        /pause/reset:POST)        api_pause_reset ;;
        /software:GET)            api_software_get ;;
        /lines:GET)               api_lines_get ;;
        /drives:GET)              api_drives_get ;;
        /drives/access:POST)      api_drives_access ;;
        /drives/eject:POST)       api_drives_eject ;;
        /drives/password:POST)    api_drives_password ;;
        /drives/forget:POST)      api_drives_forget ;;
        /exempt:GET)              api_exempt_get ;;
        /exempt/add:POST)         api_exempt_add ;;
        /exempt/del:POST)         api_exempt_del ;;
        /wifi/keys:GET)           api_wifi_keys ;;
        /lines/exceptions:GET)    api_lines_exceptions_get ;;
        /lines/exceptions:POST)   api_lines_exceptions_set ;;
        /lines/swaps:GET)         api_lines_swaps_get ;;
        /lines/swaps:POST)        api_lines_swaps_set ;;
        /lines/calls:POST)        api_lines_calls ;;
        /lines/device:POST)       api_lines_device ;;
        /software/check:GET)      api_software_check ;;
        /software/upgrade:POST)   api_software_upgrade ;;

        /mwan:GET)                api_mwan_get ;;
        /mwan/mode:POST)          api_mwan_mode_set ;;
        /mwan/wan/toggle:POST)    api_mwan_wan_toggle ;;
        /mwan/protocol:GET)       api_mwan_protocol_get ;;
        /mwan/protocol:POST)      api_mwan_protocol_set ;;

        /wan:GET)                 api_wan_get ;;
        /wan:POST)                api_wan_set ;;

        /lan:GET)                 api_lan_get ;;
        /lan:POST)                api_lan_set ;;
        /dhcp/leases:GET)         api_dhcp_leases ;;
        /dhcp/static/add:POST)    api_dhcp_static_add ;;
        /dhcp/static/del:POST)    api_dhcp_static_del ;;

        /wifi:GET)                api_wifi_get ;;
        /wifi:POST)               api_wifi_set ;;
        /wifi/radio:POST)         api_wifi_radio_set ;;

        /firewall:GET)            api_fw_get ;;
        /firewall/forward/add:POST) api_fw_forward_add ;;
        /firewall/forward/del:POST) api_fw_forward_del ;;
        /firewall/settings:POST)  api_fw_settings ;;

        /dns:GET)                 api_dns_get ;;
        /dns:POST)                api_dns_set ;;
        /adblock:GET)             api_adblock_get ;;
        /adblock:POST)            api_adblock_set ;;
        /blocklist:GET)           api_blocklist_get ;;
        /blocklist:POST)          api_blocklist_set ;;
        /blocklist/add:POST)      api_blocklist_add ;;
        /blocklist/del:POST)      api_blocklist_del ;;
        /blocklist/adult:GET)     api_adult_get ;;
        /blocklist/adult:POST)    api_adult_set ;;
        /blocklist/games:GET)     api_blocklist_games_get ;;
        /blocklist/games:POST)    api_blocklist_games_set ;;
        /blocklist/games/add:POST) api_blocklist_games_add ;;
        /blocklist/games/del:POST) api_blocklist_games_del ;;
        /ddns:GET)                api_ddns_get ;;
        /ddns:POST)               api_ddns_set ;;
        /alerts:GET)              api_alerts_get ;;
        /alerts:POST)             api_alerts_set ;;
        /alerts/test:POST)        api_alerts_test ;;
        /qos:GET)                 api_qos_get ;;
        /qos:POST)                api_qos_set ;;
        /wireguard:GET)           api_wg_get ;;
        /wireguard/keygen:POST)   api_wg_keygen ;;
        /remote:GET)              api_remote_get ;;
        /remote:POST)             api_remote_set ;;
        /remote/keygen:POST)      api_remote_keygen ;;
        /remote/status:GET)       api_remote_status ;;

        /update/check:GET)   json_error "This updater was retired (it installed an old version from GitHub). Use Settings > Software update." ;;
        /update/apply:POST)   json_error "This updater was retired (it installed an old version from GitHub). Use Settings > Software update." ;;
        /update/status:GET)  json_error "This updater was retired (it installed an old version from GitHub). Use Settings > Software update." ;;

        /diag/ping:POST)          api_diag_ping ;;
        /diag/traceroute:POST)    api_diag_traceroute ;;
        /syslog:GET)              api_syslog ;;

        /system:GET)              api_system_get ;;
        /system:POST)             api_system_set ;;
        /system/password:POST)    api_password_set ;;
        /system/reboot:POST)      api_reboot ;;
        /system/backup:GET)       api_backup ;;
        /job:GET)                 api_job_get ;;
        /ssh:GET)                 api_ssh_get ;;
        /ssh:POST)                api_ssh_set ;;
        /ssh/keys/add:POST)       api_ssh_key_add ;;
        /ssh/keys/del:POST)       api_ssh_key_del ;;
        /ssh/keys/reset:POST)     api_ssh_key_reset ;;
        /services:GET)            api_services_get ;;
        /services:POST)           api_services_action ;;
        /cron:GET)                api_cron_get ;;
        /cron:POST)               api_cron_set ;;
        /packages:GET)            api_packages_get ;;
        /packages:POST)           api_packages_action ;;
        /processes:GET)           api_processes_get ;;
        /processes/kill:POST)     api_processes_kill ;;
        /netstatus:GET)           api_netstatus_get ;;
        /dmesg:GET)               api_dmesg ;;
        /system/restore:POST)     api_restore ;;
        /system/reset:POST)       api_factory_reset ;;
        /system/flash/fetch:POST) api_flash_fetch ;;
        /system/flash/apply:POST) api_flash_apply ;;
        /config:GET)              api_config_get ;;
        /config:POST)             api_config_set ;;
        /events:GET)              api_events_get ;;
        /sync:POST)               api_sync_set ;;

        /mode:GET)                printf '{"ok":true,"mode":%s}\n' "$(sh /usr/lib/mwadmin/modeswitch.sh mode)" ;;
        /mode/ap:POST)            sh /usr/lib/mwadmin/modeswitch.sh to-ap "$(bodyval bridge_all)" "$(bodyval proto)" "$(bodyval ipaddr)" "$(bodyval netmask)" "$(bodyval gateway)" ;;
        /mode/router2:POST)       sh /usr/lib/mwadmin/modeswitch.sh to-router2 "$(bodyval dhcp)" "$(bodyval lan_ip)" "$(bodyval lan_mask)" "$(bodyval bridge_all)" "$(bodyval proto)" "$(bodyval ipaddr)" "$(bodyval netmask)" "$(bodyval gateway)" ;;
        /mode/router:POST)        sh /usr/lib/mwadmin/modeswitch.sh to-router ;;
        /mode/confirm:POST)       sh /usr/lib/mwadmin/modeswitch.sh confirm ;;

        *) echo "{\"ok\":false,\"unsupported\":true,$(jstr error "No such endpoint: $method $route. This router's software does not have it. Update the router (Settings > Software update).")}" ;;
    esac
}
