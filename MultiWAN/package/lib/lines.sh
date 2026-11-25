#!/bin/sh
# lines.sh - choose which internet line carries what.
#
#   Calls and meetings (WhatsApp / Messenger calls, Zoom, Google Meet, Teams
#   and other video calls) can be put on one preferred line, and single
#   devices can be given their own preferred line. "Preferred" means: that
#   line while it works, the others if it fails, so nothing loses internet.
#
# Recognised without reading anyone's traffic: by the ports and addresses
# those services are known to use. Ordinary web browsing (port 443) is left
# alone, so Instagram or Facebook pages do not move just because they belong
# to the same company as WhatsApp.
#
# Order of rules: calls first, then devices, then the normal failover.
# Sourced by api.sh (/lines endpoints); lines_rules is called from
# mwan_rules_regenerate.

# Meta (WhatsApp, Messenger, Instagram calls) IPv4 ranges, AS32934
META_NETS="31.13.24.0/21,31.13.64.0/18,45.64.40.0/22,57.144.0.0/14,66.220.144.0/20,69.63.176.0/20,69.171.224.0/19,74.119.76.0/22,102.132.96.0/20,103.4.96.0/22,129.134.0.0/16,147.75.208.0/20,157.240.0.0/16,163.70.128.0/17,173.252.64.0/18,179.60.192.0/22,185.60.216.0/22,185.89.216.0/22,204.15.20.0/22"

lines_rule() {   # name proto dest_port dest_ip src_ip policy
    uci set mwan3.$1='rule'
    uci set mwan3.$1.proto="$2"
    [ -n "$3" ] && uci set mwan3.$1.dest_port="$3"
    uci set mwan3.$1.dest_ip="${4:-0.0.0.0/0}"
    [ -n "$5" ] && uci set mwan3.$1.src_ip="$5"
    uci set mwan3.$1.use_policy="$6"
}

lines_wan_ok() { case "$1" in wan1|wan2|wan3) [ -n "$(uci -q get mwan3.$1)" ] ;; *) return 1 ;; esac; }

# A device's fixed address: its DHCP reservation.
lines_dev_ip() {
    local mac; mac=$(echo "$1" | tr 'A-F' 'a-f')
    uci -q show dhcp | sed -n "s/^dhcp\.\([^.]*\)\.mac='\(.*\)'$/\1 \2/p" | while read -r sec m; do
        [ "$(echo "$m" | tr 'A-F' 'a-f')" = "$mac" ] && { uci -q get "dhcp.$sec.ip"; break; }
    done
}

# LINE EXCEPTIONS: a destination address that must always use one line, because
# another line cannot reach it. Found 2026-11-25: Transworld resets every
# connection to 104.17.148.22 (www.speedtest.net's Cloudflare address) while its
# neighbouring addresses and the same address through Connect work.
#
# /etc/mwadmin/line_exceptions, one per line:  <ip or cidr> <wan1|wan2|wan3> <note>
# Each becomes an mwan3 rule on the line's own policy (that line first, the
# others only if it is down). They come before the call rules and before the
# HTTPS rule, so they win over "use only this line" for that address only.
# The rules are rebuilt from this file with all the others, so they survive
# every settings change.
LINE_EXC=/etc/mwadmin/line_exceptions

lines_exceptions() {
    local n=0 dest w note
    [ -s "$LINE_EXC" ] || return 0
    while read -r dest w note; do
        case "$dest" in ''|\#*) continue ;; esac
        printf '%s' "$dest" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || continue
        lines_wan_ok "$w" || continue
        n=$((n + 1))
        lines_rule "rule_x$n" all "" "$dest" "" "line_$w"
    done < "$LINE_EXC"
}

api_lines_exceptions_get() {
    local first=1 dest w note
    printf '{"ok":true,"exceptions":['
    if [ -s "$LINE_EXC" ]; then
        while read -r dest w note; do
            case "$dest" in ''|\#*) continue ;; esac
            [ $first -eq 0 ] && printf ','
            first=0
            printf '{%s,%s,%s}' "$(jstr dest "$dest")" "$(jstr wan "$w")" "$(jstr note "$note")"
        done < "$LINE_EXC"
    fi
    printf ']}\n'
}

# Body: {"action":"add"|"del", "dest":"1.2.3.4" or "1.2.3.0/24", "wan":"wan1", "note":"why"}
api_lines_exceptions_set() {
    local action dest w note tmp
    action=$(bodyval action); dest=$(bodyval dest); w=$(bodyval wan); note=$(bodyval note)
    printf '%s' "$dest" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || { json_error "Give an address like 104.17.148.22 or a range like 104.17.148.0/24."; return; }
    note=$(printf '%s' "$note" | tr -cd 'A-Za-z0-9 .,_:;()/-' | cut -c1-80)
    mkdir -p /etc/mwadmin; touch "$LINE_EXC"
    tmp="$LINE_EXC.new"
    grep -v -E "^$(printf '%s' "$dest" | sed 's/\./\\./g')[[:space:]]" "$LINE_EXC" > "$tmp" 2>/dev/null
    case "$action" in
        add)
            lines_wan_ok "$w" || { rm -f "$tmp"; json_error "Choose a line that exists."; return; }
            printf '%s %s %s\n' "$dest" "$w" "$note" >> "$tmp" ;;
        del) ;;
        *) rm -f "$tmp"; json_error "Unknown action."; return ;;
    esac
    mv "$tmp" "$LINE_EXC"
    lines_apply
    log "line exception $action: $dest $w"
    json_ok "$(jstr message "$([ "$action" = add ] && echo "$dest now always uses $w (the others only if it is down)." || echo "Exception for $dest removed.")")"
}

# Called from mwan_rules_regenerate after the local-network rules.
lines_rules() {
    local s w ip apps n=0
    # mwan3 ignores policy and rule names over 15 characters, and then builds
    # no rules at all: keep every name here short (line_wan1, rule_call_zoom)
    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\(policy_line_wan[0-9]\)=policy$/\1/p"); do uci -q delete mwan3.$s; done
    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\(line_wan[0-9]\)=policy$/\1/p"); do uci -q delete mwan3.$s; done
    for s in $(uci show mwan3 2>/dev/null | sed -n "s/^mwan3\.\([a-z0-9_]*_ln[0-9]\)=member$/\1/p"); do uci -q delete mwan3.$s; done
    for w in wan1 wan2 wan3; do
        lines_wan_ok "$w" && mwan_build_pref_policy "line_$w" "$w" "ln${w#wan}"
    done

    # destinations that must always use one line (see lines_exceptions), before the call rules
    lines_exceptions

    w=$(uget_d mwadmin.lines.calls_wan auto)
    if lines_wan_ok "$w"; then
        apps=" $(uget_d mwadmin.lines.calls_apps 'whatsapp zoom meet teams') "
        case "$apps" in *" whatsapp "*) lines_rule rule_call_meta udp 1024:65535 "$META_NETS" "" "line_$w" ;; esac
        case "$apps" in *" zoom "*)
            lines_rule rule_call_zoom udp 8801:8810 "" "" "line_$w"
            lines_rule rule_zoom_tcp tcp 8801:8802 "" "" "line_$w" ;; esac
        case "$apps" in *" meet "*) lines_rule rule_call_meet udp 19302:19309 "" "" "line_$w" ;; esac
        case "$apps" in *" teams "*) lines_rule rule_call_rtc udp 3478:3481 "" "" "line_$w" ;; esac
    fi

    for s in $(uci show mwadmin 2>/dev/null | sed -n "s/^mwadmin\.\([^.=]*\)=devline$/\1/p"); do
        w=$(uci -q get mwadmin.$s.wan)
        lines_wan_ok "$w" || continue
        ip=$(lines_dev_ip "$(uci -q get mwadmin.$s.mac)")
        [ -n "$ip" ] || continue
        n=$((n + 1))
        lines_rule "rule_dev_$n" all "" "" "$ip/32" "line_$w"
    done
}

api_lines_get() {
    local devs="" s first=1 mac
    for s in $(uci show mwadmin 2>/dev/null | sed -n "s/^mwadmin\.\([^.=]*\)=devline$/\1/p"); do
        mac=$(uci -q get mwadmin.$s.mac)
        [ $first -eq 0 ] && devs="$devs,"
        first=0
        devs="$devs{$(jstr mac "$mac"),$(jstr name "$(uci -q get mwadmin.$s.name)"),$(jstr wan "$(uci -q get mwadmin.$s.wan)"),$(jstr ip "$(lines_dev_ip "$mac")")}"
    done
    local wans="" w first2=1
    for w in wan1 wan2 wan3; do
        lines_wan_ok "$w" || continue
        [ $first2 -eq 0 ] && wans="$wans,"
        first2=0
        wans="$wans{$(jstr iface "$w"),$(jstr label "$(uci -q get mwadmin.site_$w.label 2>/dev/null)"),$(jbool online "$(mwan3_status_cached | grep -q "interface $w is online" && echo 1)")}"
    done
    printf '{"ok":true,%s,%s,"devices":[%s],"wans":[%s]}\n' \
        "$(jstr calls_wan "$(uget_d mwadmin.lines.calls_wan auto)")" \
        "$(jstr calls_apps "$(uget_d mwadmin.lines.calls_apps 'whatsapp zoom meet teams')")" "$devs" "$wans"
}

lines_apply() {
    mwan_rules_regenerate
    ( sleep 1; mwan3 restart ) >/dev/null 2>&1 &
}

api_lines_calls() {
    local w apps a clean=""
    w=$(bodyval wan); apps=$(bodyval apps)
    [ "$w" = "auto" ] || lines_wan_ok "$w" || { json_error "Choose a line that exists, or Automatic."; return; }
    for a in $(echo "$apps" | tr ',' ' '); do
        case "$a" in whatsapp|zoom|meet|teams) clean="$clean $a" ;; esac
    done
    uci set mwadmin.lines=lines
    uci set mwadmin.lines.calls_wan="$w"
    uci set mwadmin.lines.calls_apps="${clean# }"
    uci commit mwadmin
    lines_apply
    log "calls and meetings line: $w (${clean# })"
    json_ok "$(jstr message "$([ "$w" = auto ] && echo 'Calls follow the normal line order again.' || echo "Calls and meetings now prefer $w. New calls use it; a call already running keeps its line.")")"
}

api_lines_device() {
    local mac name w sec ip host
    mac=$(bodyval mac | tr 'A-F' 'a-f'); name=$(bodyval name); w=$(bodyval wan)
    printf '%s' "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { json_error "Invalid device."; return; }
    sec="dl_$(echo "$mac" | tr -d ':')"
    if [ "$w" = "auto" ] || [ -z "$w" ]; then
        uci -q delete mwadmin.$sec
        uci commit mwadmin
        lines_apply
        json_ok "$(jstr message 'This device follows the normal line order again.')"
        return
    fi
    lines_wan_ok "$w" || { json_error "Choose a line that exists."; return; }
    name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-40)
    # a device needs a fixed address for a rule to follow it: reserve its current one
    ip=$(lines_dev_ip "$mac")
    if [ -z "$ip" ]; then
        ip=$(awk -v m="$mac" 'tolower($2) == m { print $3; exit }' /tmp/dhcp.leases 2>/dev/null)
        [ -n "$ip" ] || { json_error "This device has no address yet. Connect it once, then try again."; return; }
        host="host_$(echo "$mac" | tr -d ':')"
        uci set dhcp.$host=host
        uci set dhcp.$host.mac="$mac"
        uci set dhcp.$host.ip="$ip"
        [ -n "$name" ] && uci set dhcp.$host.name="$(printf '%s' "$name" | tr ' ._' '---')"
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1
    fi
    uci set mwadmin.$sec=devline
    uci set mwadmin.$sec.mac="$mac"
    uci set mwadmin.$sec.name="$name"
    uci set mwadmin.$sec.wan="$w"
    uci commit mwadmin
    lines_apply
    log "device $mac ($name) prefers $w"
    json_ok "$(jstr message "${name:-This device} now prefers $w (fixed address $ip).")"
}
