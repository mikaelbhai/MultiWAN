#!/bin/sh
# node.sh - mode 3 (node) and the Wi-Fi pieces it needs (docs/14).
#
#   Mode 3 replaces "Router 2 with DHCP off". A node adds Wi-Fi to Router 2's network; it hands out no addresses, does no
#   routing, and broadcasts the SAME Wi-Fi name and password as Router 2 with fast roaming (802.11r/v), so phones move
#   between Router 2 and the nodes without dropping. Its uplink, chosen per node:
#     cable     any port to Router 2 (or to a switch behind it)
#     mesh      an encrypted 802.11s link on 5 GHz to Router 2 (Router 2 turns on "Mesh for nodes", node_mesh_root)
#     repeater  joins ANY nearby Wi-Fi as a client (picked from a scan, or typed) and passes it through (relayd), so
#               devices get their addresses from that network; own Wi-Fi name, or the same as the source
#
# Sourced by modeswitch.sh (the switch itself, with its 90 s rollback) and api.sh (scan, mesh-root settings).
# MW_DRY / MW_UCI_DIR (see modeswitch.sh) make every change land on a copy of the settings only.

. /usr/lib/mwadmin/common.sh
type uci >/dev/null 2>&1 || true

# ---- helpers -------------------------------------------------------------------------------------------------------------
node_md() { printf '%s' "$1" | md5sum | cut -c1-4; }           # 802.11r mobility domain: the same for the same Wi-Fi name

node_radio_of_band() {     # 2g | 5g -> radio section name (wifi-device)
    local want="$1" s b
    for s in $(uci -q show wireless | sed -n "s/^wireless\.\([a-z0-9_]*\)=wifi-device$/\1/p"); do
        b=$(uci -q get wireless.$s.band)
        [ -z "$b" ] && case "$(uci -q get wireless.$s.hwmode)" in *a) b=5g ;; *) b=2g ;; esac
        [ "$b" = "$want" ] && { echo "$s"; return 0; }
    done
    return 1
}

node_ap_ifaces() { uci -q show wireless | sed -n "s/^wireless\.\([a-z0-9_]*\)\.mode='ap'$/\1/p" | grep -v guest; }

# Every access point: this Wi-Fi name and password, fast roaming on (same mobility domain on every router with this name)
node_wifi_align() {        # <ssid> <key>
    local ssid="$1" key="$2" s md
    md=$(node_md "$ssid")
    for s in $(node_ap_ifaces); do
        [ -n "$ssid" ] && uci set wireless.$s.ssid="$ssid"
        if [ -n "$key" ]; then
            uci set wireless.$s.key="$key"
            case "$(uci -q get wireless.$s.encryption)" in ''|none|open) uci set wireless.$s.encryption='psk2' ;; esac
        fi
        uci set wireless.$s.network='lan'
        uci set wireless.$s.ieee80211r='1'
        uci set wireless.$s.mobility_domain="$md"
        uci set wireless.$s.ft_over_ds='0'
        uci set wireless.$s.ft_psk_generate_local='1'
        uci set wireless.$s.bss_transition='1'
        uci set wireless.$s.disabled='0'
    done
}

# The Wi-Fi package with mesh support (it replaces the basic one: same daemon, more features)
node_has_mesh() { strings /usr/sbin/wpad 2>/dev/null | grep -q 'mesh_fwding\|MESH_GROUP_ADD'; }
node_pkg() {               # <what: mesh|relay>  -> 0 when present or installed
    case "$1" in
        mesh)  node_has_mesh && return 0
               [ -n "$MW_DRY" ] && return 0
               if command -v apk >/dev/null 2>&1; then
                   apk update >/dev/null 2>&1; apk del wpad-basic-mbedtls >/dev/null 2>&1; apk add wpad-mesh-mbedtls >/dev/null 2>&1 || apk add wpad-basic-mbedtls >/dev/null 2>&1
               else
                   opkg update >/dev/null 2>&1; opkg remove wpad-basic-mbedtls >/dev/null 2>&1; opkg install wpad-mesh-mbedtls >/dev/null 2>&1 || opkg install wpad-basic-mbedtls >/dev/null 2>&1
               fi
               node_has_mesh ;;
        relay) [ -x /usr/sbin/relayd ] && return 0
               [ -n "$MW_DRY" ] && return 0
               if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add relayd >/dev/null 2>&1
               else opkg update >/dev/null 2>&1; opkg install relayd >/dev/null 2>&1; fi
               [ -x /usr/sbin/relayd ] ;;
    esac
}

# ---- the 802.11s link ------------------------------------------------------------------------------------------------------
node_mesh_iface() {        # <mesh id> <mesh password> <5 GHz channel>
    local r; r=$(node_radio_of_band 5g) || return 1
    uci set wireless.$r.channel="${3:-36}"           # every member of a mesh must be on the same channel
    uci set wireless.$r.disabled='0'
    uci set wireless.mwmesh='wifi-iface'
    uci set wireless.mwmesh.device="$r"
    uci set wireless.mwmesh.mode='mesh'
    uci set wireless.mwmesh.mesh_id="$1"
    uci set wireless.mwmesh.encryption='sae'
    uci set wireless.mwmesh.key="$2"
    uci set wireless.mwmesh.network='lan'
    uci set wireless.mwmesh.mesh_fwding='1'
    uci set wireless.mwmesh.mesh_rssi_threshold='0'
    uci set wireless.mwmesh.disabled='0'
}

# Router 2 (or a main router) as the mesh root: the same link for wireless nodes, and fast roaming on its own Wi-Fi.
# Live, no mode change: only the Wi-Fi restarts. on=0 takes the mesh link away again (roaming stays on, it is harmless).
node_mesh_root() {         # <on 1|0> <mesh id> <mesh password> <channel>
    if [ "$1" = "1" ]; then
        [ ${#3} -ge 8 ] || { json_error "The mesh password needs at least 8 characters."; return 1; }
        node_pkg mesh || { json_error "Could not install the Wi-Fi mesh software (wpad-mesh-mbedtls). Is the router online?"; return 1; }
        local s ssid key; s=$(node_ap_ifaces | head -n1); ssid=$(uci -q get wireless.$s.ssid); key=$(uci -q get wireless.$s.key)
        node_wifi_align "$ssid" ""
        node_mesh_iface "$2" "$3" "$4" || { json_error "This router has no 5 GHz radio for the mesh."; return 1; }
        uci set mwadmin.mesh='mesh'; uci set mwadmin.mesh.enabled='1'; uci set mwadmin.mesh.id="$2"; uci set mwadmin.mesh.channel="${4:-36}"
    else
        uci -q delete wireless.mwmesh
        uci set mwadmin.mesh='mesh'; uci set mwadmin.mesh.enabled='0'
    fi
    uci commit wireless; uci commit mwadmin
    [ -n "$MW_DRY" ] || ( sleep 1; wifi reload ) >/dev/null 2>&1 &
    json_ok "$(jstr message "$([ "$1" = 1 ] && echo 'Mesh for nodes is on. Wireless nodes join with the mesh name and password shown here.' || echo 'Mesh for nodes is off.')")"
}

node_mesh_get() {
    local s r; s=$(node_ap_ifaces | head -n1); r=$(node_radio_of_band 5g)
    json_ok "$(jbool enabled "$([ "$(uci -q get mwadmin.mesh.enabled)" = 1 ] && [ -n "$(uci -q get wireless.mwmesh)" ] && echo 1 || echo 0)"),$(jstr id "$(uci -q get wireless.mwmesh.mesh_id)"),$(jstr key "$(uci -q get wireless.mwmesh.key)"),$(jstr channel "$(uci -q get wireless.${r:-x}.channel)"),$(jstr ssid "$(uci -q get wireless.$s.ssid)"),$(jbool roaming "$([ "$(uci -q get wireless.$s.ieee80211r)" = 1 ] && echo 1 || echo 0)"),$(jbool has_5g "$([ -n "$r" ] && echo 1 || echo 0)"),$(jbool mesh_software "$(node_has_mesh && echo 1 || echo 0)")"
}

# ---- repeater ------------------------------------------------------------------------------------------------------------
# Joins any Wi-Fi as a client and passes it through: relayd bridges the Wi-Fi client (wwan) and the LAN, so devices on
# this router get their addresses from that network. The router keeps a small management address of its own on the LAN.
node_repeater() {          # <band 2g|5g> <ssid> <key> <encryption psk2|sae|none> <own ssid or empty = same> <own key or empty = same>
    local r; r=$(node_radio_of_band "$1") || r=$(node_radio_of_band 2g) || return 1
    uci set wireless.$r.channel='auto'; uci set wireless.$r.disabled='0'
    uci set wireless.mwsta='wifi-iface'
    uci set wireless.mwsta.device="$r"
    uci set wireless.mwsta.mode='sta'
    uci set wireless.mwsta.ssid="$2"
    uci set wireless.mwsta.encryption="${4:-psk2}"
    if [ "${4:-psk2}" = "none" ]; then uci -q delete wireless.mwsta.key; else uci set wireless.mwsta.key="$3"; fi
    uci set wireless.mwsta.network='wwan'
    uci set wireless.mwsta.disabled='0'
    uci set network.wwan='interface'; uci set network.wwan.proto='dhcp'
    uci set network.mwrelay='interface'; uci set network.mwrelay.proto='relay'
    uci -q delete network.mwrelay.network; uci add_list network.mwrelay.network='lan'; uci add_list network.mwrelay.network='wwan'
    # the LAN keeps a fixed management address (the repeater is reached at it by cable, and through the website)
    uci set network.lan.proto='static'; uci set network.lan.ipaddr='192.168.199.1'; uci set network.lan.netmask='255.255.255.0'
    uci -q delete network.lan.gateway; uci -q delete network.lan.dns
    uci set network.mwrelay.ipaddr='192.168.199.1'
    node_wifi_align "${5:-$2}" "${6:-$3}"
}

# ---- what is around: scan every radio ---------------------------------------------------------------------------------------
node_scan() {
    local dev out="" f=1 band
    for dev in $(iw dev 2>/dev/null | awk '/Interface/ { print $2 }'); do
        case "$dev" in phy*-ap*|phy*-sta*|wlan*) ;; *) continue ;; esac
        band=$(iwinfo "$dev" info 2>/dev/null | sed -n 's/.*Channel: \([0-9]*\).*/\1/p' | head -n1)
        iwinfo "$dev" scan 2>/dev/null | awk -v dev="$dev" '
            function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s); return "\"" s "\"" }
            /^Cell/       { if (ssid != "") emit(); ssid = ""; ch = ""; sig = ""; enc = "" }
            /ESSID:/      { s = $0; sub(/.*ESSID: "/, "", s); sub(/"$/, "", s); ssid = s }
            /Channel:/    { s = $0; sub(/.*Channel: /, "", s); split(s, a, " "); ch = a[1] }
            /Signal:/     { s = $0; sub(/.*Signal: /, "", s); split(s, a, " "); sig = a[1] }
            /Encryption:/ { s = $0; sub(/.*Encryption: /, "", s); enc = s }
            END { if (ssid != "") emit() }
            function emit(  e) {
                e = (enc ~ /SAE|WPA3/ && enc !~ /PSK/) ? "sae" : (enc ~ /none/ ? "none" : "psk2")
                printf "%s\t%s\t%s\t%s\t%s\n", ssid, ch, sig, e, enc
            }'
        # some drivers (mt76 while serving devices) give iwinfo nothing: ask iw directly, with ap-force
        iw dev "$dev" scan ap-force 2>/dev/null | awk '
            /^BSS /                    { if (ssid != "") emit(); ssid = ""; ch = ""; sig = ""; enc = "none"; auth = "" }
            /^[[:space:]]*SSID: /      { s = $0; sub(/^[[:space:]]*SSID: /, "", s); ssid = s }
            /^[[:space:]]*signal: /    { split($2, a, "."); sig = a[1] }
            /DS Parameter set: channel/ { ch = $NF }
            /primary channel: /        { ch = $NF }
            /^[[:space:]]*RSN:|^[[:space:]]*WPA:/ { enc = "psk2" }
            /Authentication suites:/   { auth = auth " " $0 }
            END { if (ssid != "") emit() }
            function emit() {
                if (auth ~ /SAE/ && auth !~ /PSK/) enc = "sae"
                printf "%s\t%s\t%s\t%s\t%s\n", ssid, ch, sig, enc, (enc == "none" ? "open" : (enc == "sae" ? "WPA3" : "WPA2"))
            }'
    done | sort -t"$(printf '\t')" -k1,1 -k3,3nr | awk -F'\t' '!seen[$1]++' | sort -t"$(printf '\t')" -k3,3nr | head -n 40 > "$MW_RUN/scan.tsv"
    printf '{"ok":true,"networks":['
    awk -F'\t' 'function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s); return "\"" s "\"" }
        { printf "%s{\"ssid\":%s,\"channel\":%d,\"band\":\"%s\",\"signal\":%d,\"security\":%s,\"label\":%s}", (NR > 1 ? "," : ""), q($1), $2, ($2 + 0 > 14 ? "5g" : "2g"), $3, q($4), q($5) }' "$MW_RUN/scan.tsv"
    printf ']}\n'
}
