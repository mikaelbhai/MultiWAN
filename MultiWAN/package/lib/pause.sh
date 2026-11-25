#!/bin/sh
# pause.sh - free time from the site blocker.
#
# Break time: one window a day (e.g. 13:00-14:00, router's local time) when
#   the blocked sites are open for everybody. The 18+ filter (adult.sh) is
#   separate and stays on.
# Allowance: every device - or every group of devices, which then share it -
#   gets N minutes a day (default 60) to unpause the blocked sites. They can
#   pause and unpause as they like; the clock only runs while unpaused and
#   NOT during break time (the sites are open then anyway). Used up = blocked
#   until midnight, when it starts again.
#
# Files:
#   /etc/mwadmin/groups      id <TAB> name <TAB> mac,mac,...
#   /etc/mwadmin/pause_use   owner <TAB> day <TAB> used_s <TAB> running(0/1) <TAB> last_counted
#     owner = group id (g1, g2, ...) or the device's MAC
# Settings: uci mwadmin.pause.allow_min / break_from / break_to ("HH:MM", empty = no break)
#
# Unpaused devices go into the nft set "free" of block.sh's table: their DNS
# and traffic skip the block rules. During break time there is no block table
# at all. Sourced by api.sh, block.sh and the block-page CGI.

. /usr/lib/mwadmin/common.sh

P_GROUPS=/etc/mwadmin/groups
P_USE=/etc/mwadmin/pause_use

pause_ensure() {
    mkdir -p /etc/mwadmin
    [ -f "$P_GROUPS" ] || : > "$P_GROUPS"
    [ -f "$P_USE" ] || : > "$P_USE"
    if [ "$(uget mwadmin.pause)" != "pause" ]; then
        uci set mwadmin.pause='pause'
        uci set mwadmin.pause.allow_min='60'
        uci set mwadmin.pause.break_from='13:00'
        uci set mwadmin.pause.break_to='14:00'
        uci commit mwadmin
    fi
}

pause_allow_s() { echo $(( $(uget_d mwadmin.pause.allow_min 60) * 60 )); }

# "13:05" -> 785 (minutes after midnight); nothing for a bad value
pause_hm() {
    case "$1" in [0-2][0-9]:[0-5][0-9]) ;; *) return 1 ;; esac
    local h=${1%%:*} m=${1##*:}
    h=${h#0}; m=${m#0}
    [ "${h:-0}" -le 23 ] || return 1
    echo $(( ${h:-0} * 60 + ${m:-0} ))
}

# Break windows of today as "start end" epoch pairs (two when it runs past midnight).
pause_windows() {
    local bf bt now sod mid
    bf=$(pause_hm "$(uget mwadmin.pause.break_from)") || return 0
    bt=$(pause_hm "$(uget mwadmin.pause.break_to)") || return 0
    [ "$bf" = "$bt" ] && return 0
    now=$(date +%s)
    sod=$(date +'%H %M %S' | awk '{ print $1 * 3600 + $2 * 60 + $3 }')
    mid=$((now - sod))
    if [ "$bf" -lt "$bt" ]; then
        echo "$((mid + bf * 60)) $((mid + bt * 60))"
    else
        echo "$mid $((mid + bt * 60))"
        echo "$((mid + bf * 60)) $((mid + 86400))"
    fi
}

pause_in_break() {
    local now s e
    now=$(date +%s)
    pause_windows | { while read -r s e; do [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ] && exit 0; done; exit 1; }
}

# Group of a device ("" = none)
pause_group_of() { awk -F'\t' -v m="$1" '{ n = split($3, a, ","); for (i = 1; i <= n; i++) if (a[i] == m) { print $1; exit } }' "$P_GROUPS" 2>/dev/null; }
pause_owner() { local g; g=$(pause_group_of "$1"); printf '%s' "${g:-$1}"; }
pause_owner_macs() {
    case "$1" in
        g[0-9]*) awk -F'\t' -v g="$1" '$1 == g { gsub(/,/, " ", $3); print $3 }' "$P_GROUPS" ;;
        *) echo "$1" ;;
    esac
}

# Bring the usage file up to now: count unpaused time outside break windows,
# stop owners whose time ran out, forget earlier days. Prints owners that were
# stopped (so their sites can be cut off again).
pause_account() {
    pause_ensure
    [ -s "$P_USE" ] || return 0
    local now day
    now=$(date +%s); day=$(date +%Y%m%d)
    awk -F'\t' -v OFS='\t' -v now="$now" -v day="$day" -v allow="$(pause_allow_s)" \
        -v win="$(pause_windows | tr '\n' ' ')" -v out="$P_USE.new" -v stopf="$P_USE.stop" '
        BEGIN { nw = split(win, w, " ") }
        {
            if ($2 != day) { if ($4 == 1) print $1 > stopf; next }
            if ($4 == 1) {
                a = $5; b = now; el = b - a
                for (i = 1; i + 1 <= nw; i += 2) {
                    s = (a > w[i]) ? a : w[i]; e = (b < w[i + 1]) ? b : w[i + 1]
                    if (e > s) el -= e - s
                }
                if (el > 0) $3 += el
                $5 = now
                if ($3 >= allow) { $3 = allow; $4 = 0; print $1 > stopf }
            }
            print > out
        }' "$P_USE"
    [ -f "$P_USE.new" ] && mv "$P_USE.new" "$P_USE" || : > "$P_USE"
    [ -f "$P_USE.stop" ] && { cat "$P_USE.stop"; rm -f "$P_USE.stop"; }
    return 0
}

# "used running" for an owner today
pause_state() { awk -F'\t' -v o="$1" -v d="$(date +%Y%m%d)" '$1 == o && $2 == d { print $3, $4; f = 1 } END { if (!f) print "0 0" }' "$P_USE" 2>/dev/null; }

pause_set_run() {     # owner 0|1
    local o="$1" r="$2" now day
    now=$(date +%s); day=$(date +%Y%m%d)
    awk -F'\t' -v OFS='\t' -v o="$o" -v r="$r" -v now="$now" -v day="$day" '
        $1 == o && $2 == day { $4 = r; $5 = now; f = 1 }
        { print }
        END { if (!f) print o, day, 0, r, now }' "$P_USE" > "$P_USE.new" && mv "$P_USE.new" "$P_USE"
}

# MACs that are unpaused right now
pause_free_macs() {
    local o
    awk -F'\t' -v d="$(date +%Y%m%d)" '$2 == d && $4 == 1 { print $1 }' "$P_USE" 2>/dev/null | while read -r o; do
        pause_owner_macs "$o"
    done | tr ' ' '\n' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u
}

# Put the unpaused devices into the block table's "free" set.
pause_sync() {
    nft list set inet mwblock free >/dev/null 2>&1 || return 0
    local m; m=$(pause_free_macs | tr '\n' ',' | sed 's/,$//')
    nft flush set inet mwblock free 2>/dev/null
    [ -n "$m" ] && nft add element inet mwblock free "{ $m }" 2>/dev/null
    # their DNS connections still point at the old resolver: start fresh
    conntrack -D -p udp --dport 53 >/dev/null 2>&1
    conntrack -D -p tcp --dport 53 >/dev/null 2>&1
    return 0
}

# Cut what a re-blocked device still has open (background: it does lookups).
pause_recut() {
    ( . /usr/lib/mwadmin/block.sh
      while read -r u; do [ -n "$u" ] && block_kick "$u" hot; done < "$B_SITES" ) >/dev/null 2>&1 &
}

pause_label() {     # owner -> name for people
    local o="$1" n
    case "$o" in
        g[0-9]*) n=$(awk -F'\t' -v g="$o" '$1 == g { print $2 }' "$P_GROUPS") ;;
        *) n=$(awk -v m="$o" 'tolower($2) == m { print $4; exit }' /tmp/dhcp.leases 2>/dev/null); [ "$n" = "*" ] && n="" ;;
    esac
    printf '%s' "${n:-$o}"
}

# Turn an owner's free time on/off. Prints a short message; returns 1 if refused.
pause_toggle() {     # owner on(1)/off(0)
    local o="$1" on="$2" used run
    pause_account >/dev/null
    set -- $(pause_state "$o"); used=$1; run=$2
    if [ "$on" = "1" ]; then
        [ "$used" -ge "$(pause_allow_s)" ] && { echo "No free time left today. It starts again at midnight."; return 1; }
        [ "$run" = "1" ] && { echo "Already unpaused."; return 0; }
        pause_set_run "$o" 1
        pause_sync
        log "free time on: $(pause_label "$o")"
        sh /usr/lib/mwadmin/events.sh add info info "Blocked sites unpaused for $(pause_label "$o")" >/dev/null 2>&1
        echo "Blocked sites are open. Your time is running."
    else
        [ "$run" = "1" ] || { echo "Already paused."; return 0; }
        pause_set_run "$o" 0
        pause_sync
        pause_recut
        log "free time off: $(pause_label "$o")"
        echo "Paused. Your remaining time is saved."
    fi
}

# "sites.router" opens the block page (where a device pauses / unpauses its
# free time) on any device, blocked or not, break or not. The name points at
# the block address; port 80 there goes to the page. Rewritten only when the
# address changes (a LAN renumber).
pause_portal() {
    local sink f=/etc/nftables.d/23-mwpause.nft want
    sink=$(uci -q get network.lan_block.ipaddr); sink="${sink%%/*}"
    [ -n "$sink" ] || return 0
    if ! uci -q get dhcp.@dnsmasq[0].address | tr ' ' '\n' | grep -qx "/sites.router/$sink"; then
        for a in $(uci -q get dhcp.@dnsmasq[0].address); do
            case "$a" in /sites.router/*) uci -q del_list dhcp.@dnsmasq[0].address="$a" ;; esac
        done
        uci add_list dhcp.@dnsmasq[0].address="/sites.router/$sink"
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1
    fi
    want="chain mw_pause_nat {
    type nat hook prerouting priority dstnat - 30; policy accept;
    iifname \"br-lan\" ip daddr $sink tcp dport 80 redirect to :8188
}"
    if [ "$(cat "$f" 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > "$f"
        fw4 -q reload >/dev/null 2>&1
    fi
}

# Once a minute (block_tick): count time, close out used-up owners, and switch
# the block table off for break time and back on after it.
pause_tick() {
    local stopped o mark="$MW_RUN/block/in_break"
    pause_portal
    stopped=$(pause_account)
    if [ -n "$stopped" ]; then
        pause_sync
        for o in $stopped; do
            log "free time used up: $(pause_label "$o")"
            sh /usr/lib/mwadmin/events.sh add info info "Free time used up for $(pause_label "$o")" >/dev/null 2>&1
        done
        pause_recut
    fi
    if pause_in_break; then
        if [ ! -f "$mark" ]; then
            mkdir -p "$MW_RUN/block"; : > "$mark"
            /etc/init.d/mwblock stop >/dev/null 2>&1
            pkill -f "$MW_RUN/block/g[0-9]*.conf" 2>/dev/null
            log "break time: blocked sites open for everyone"
            sh /usr/lib/mwadmin/events.sh add info info "Break time started: blocked sites open" >/dev/null 2>&1
        fi
        return 0
    fi
    if [ -f "$mark" ]; then
        rm -f "$mark"
        ( . /usr/lib/mwadmin/block.sh; block_apply ) >/dev/null 2>&1
        pause_sync
        pause_recut
        log "break time over: sites blocked again"
        sh /usr/lib/mwadmin/events.sh add info info "Break time over: sites blocked again" >/dev/null 2>&1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# API (admin)
# ---------------------------------------------------------------------------
pause_owner_json() {     # owner
    local o="$1" used run allow
    allow=$(pause_allow_s)
    set -- $(pause_state "$o"); used=$1; run=$2
    printf '{%s,%s,%s,%s,%s}' "$(jstr owner "$o")" "$(jstr name "$(pause_label "$o")")" \
        "$(jnum used_s "$used")" "$(jnum left_s "$((allow > used ? allow - used : 0))")" "$(jbool running "$run")"
}

api_pause_get() {
    pause_account >/dev/null
    local first=1 id name macs m out="" owners="" o seen=" "
    while IFS="$(printf '\t')" read -r id name macs; do
        [ -n "$id" ] || continue
        local ml="" f2=1
        for m in $(echo "$macs" | tr ',' ' '); do
            [ $f2 -eq 0 ] && ml="$ml,"; f2=0
            ml="$ml{$(jstr mac "$m"),$(jstr name "$(pause_label "$m")")}"
        done
        [ $first -eq 0 ] && out="$out,"; first=0
        out="$out{$(jstr id "$id"),$(jstr name "$name"),\"devices\":[$ml],\"usage\":$(pause_owner_json "$id")}"
    done < "$P_GROUPS"
    # devices on their own that used free time today
    first=1
    for o in $(awk -F'\t' -v d="$(date +%Y%m%d)" '$2 == d { print $1 }' "$P_USE" 2>/dev/null); do
        case "$o" in g[0-9]*) continue ;; esac
        [ $first -eq 0 ] && owners="$owners,"; first=0
        owners="$owners$(pause_owner_json "$o")"
    done
    printf '{"ok":true,%s,%s,%s,%s,%s,"groups":[%s],"devices":[%s]}\n' \
        "$(jnum allow_min "$(uget_d mwadmin.pause.allow_min 60)")" \
        "$(jstr break_from "$(uget mwadmin.pause.break_from)")" \
        "$(jstr break_to "$(uget mwadmin.pause.break_to)")" \
        "$(jbool in_break "$(pause_in_break && echo 1 || echo 0)")" \
        "$(jstr now "$(date '+%H:%M')")" \
        "$out" "$owners"
}

api_pause_settings() {
    pause_ensure
    local a bf bt
    a=$(bodyval allow_min); bf=$(bodyval break_from); bt=$(bodyval break_to)
    case "$a" in ''|*[!0-9]*) json_error "Allowance must be a number of minutes."; return ;; esac
    [ "$a" -le 1440 ] || { json_error "Allowance can be at most 1440 minutes (a whole day)."; return; }
    if [ -n "$bf$bt" ]; then
        pause_hm "$bf" >/dev/null && pause_hm "$bt" >/dev/null || { json_error "Break times must look like 13:00."; return; }
    fi
    pause_account >/dev/null
    uci set mwadmin.pause.allow_min="$a"
    uci set mwadmin.pause.break_from="$bf"
    uci set mwadmin.pause.break_to="$bt"
    uci commit mwadmin
    pause_tick >/dev/null 2>&1
    log "free time settings: ${a} min a day, break ${bf:-none}-${bt:-none}"
    json_ok "$(jstr message 'Saved.')"
}

api_pause_group_save() {
    pause_ensure
    local id name macs m clean=""
    id=$(bodyval id); name=$(printf '%s' "$(bodyval name)" | tr -d '\000-\037"\\' | tr '\t' ' ' | cut -c1-32)
    macs=$(bodyval macs)
    [ -n "$name" ] || { json_error "Give the group a name."; return; }
    for m in $(echo "$macs" | tr ',' ' ' | tr 'A-F' 'a-f'); do
        echo "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || continue
        clean="$clean${clean:+,}$m"
    done
    [ -n "$id" ] || id="g$(( $(sed -n 's/^g\([0-9]*\)\t.*/\1/p' "$P_GROUPS" | sort -n | tail -n1) + 1 ))"
    case "$id" in g[0-9]*) ;; *) json_error "Bad group."; return ;; esac
    # a device belongs to one group only
    awk -F'\t' -v OFS='\t' -v id="$id" -v name="$name" -v macs="$clean" '
        BEGIN { n = split(macs, a, ","); for (i = 1; i <= n; i++) mine[a[i]] = 1 }
        $1 == id { next }
        { n = split($3, b, ","); r = ""; for (i = 1; i <= n; i++) if (!(b[i] in mine)) r = r (r == "" ? "" : ",") b[i]; $3 = r; print }
        END { print id, name, macs }' "$P_GROUPS" > "$P_GROUPS.new" && mv "$P_GROUPS.new" "$P_GROUPS"
    pause_sync
    log "group saved: $name ($clean)"
    json_ok "$(jstr message 'Group saved.'),$(jstr id "$id")"
}

api_pause_group_delete() {
    local id; id=$(bodyval id)
    case "$id" in g[0-9]*) ;; *) json_error "Bad group."; return ;; esac
    awk -F'\t' -v id="$id" '$1 != id' "$P_GROUPS" > "$P_GROUPS.new" && mv "$P_GROUPS.new" "$P_GROUPS"
    awk -F'\t' -v id="$id" '$1 != id' "$P_USE" > "$P_USE.new" && mv "$P_USE.new" "$P_USE"
    pause_sync
    json_ok "$(jstr message 'Group removed.')"
}

api_pause_toggle() {     # admin: pause / unpause for someone
    local o on msg
    o=$(bodyval owner); on=$(bodyval on)
    case "$o" in g[0-9]*) ;; *) echo "$o" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { json_error "Bad device."; return; } ;; esac
    msg=$(pause_toggle "$o" "$([ "$on" = "1" ] && echo 1 || echo 0)") || { json_error "$msg"; return; }
    json_ok "$(jstr message "$msg")"
}

api_pause_reset() {     # admin: give someone their full time back today
    local o; o=$(bodyval owner)
    pause_account >/dev/null
    awk -F'\t' -v OFS='\t' -v o="$o" -v d="$(date +%Y%m%d)" '$1 == o && $2 == d { $3 = 0 } { print }' "$P_USE" > "$P_USE.new" && mv "$P_USE.new" "$P_USE"
    json_ok "$(jstr message 'Free time reset for today.')"
}
