#!/bin/sh
# hwdetect.sh - what this OpenWrt router has, on any brand: ports, radios, USB, storage, memory (docs/14).
#   hwdetect.sh json     for the panel (/hardware)
#   hwdetect.sh env N    mwan.env lines for N internet lines (1-3) with this router's own port names
# Ports come from /etc/board.json, which OpenWrt writes for every device. A router with a DSA switch (separate
# lan1..lanN ports) can use LAN ports as extra lines; an older swconfig router (one eth0.x LAN device) gets one line.

. /usr/lib/mwadmin/common.sh

hw_board() { cat /tmp/sysinfo/board_name 2>/dev/null || jsonfilter -i /etc/board.json -e '@.model.id' 2>/dev/null; }
hw_model() { cat /tmp/sysinfo/model 2>/dev/null || jsonfilter -i /etc/board.json -e '@.model.name' 2>/dev/null; }
hw_wan()   { local w; w=$(jsonfilter -i /etc/board.json -e '@.network.wan.device' 2>/dev/null); [ -n "$w" ] && echo "$w" || { [ -e /sys/class/net/wan ] && echo wan; }; }
hw_lan_ports() {           # the LAN ports, one per line (DSA), or the single LAN device (swconfig)
    local p; p=$(jsonfilter -i /etc/board.json -e '@.network.lan.ports[*]' 2>/dev/null)
    [ -n "$p" ] && { echo "$p"; return; }
    jsonfilter -i /etc/board.json -e '@.network.lan.device' 2>/dev/null
}
hw_dsa() { [ -n "$(jsonfilter -i /etc/board.json -e '@.network.lan.ports[*]' 2>/dev/null)" ]; }
hw_radios() {              # band list: 2g 5g ...
    local s b
    for s in $(uci -q show wireless | sed -n "s/^wireless\.\([a-z0-9_]*\)=wifi-device$/\1/p"); do
        b=$(uci -q get wireless.$s.band); [ -z "$b" ] && case "$(uci -q get wireless.$s.hwmode)" in *a) b=5g ;; *) b=2g ;; esac
        echo "$b"
    done
}
hw_usb() { ls /sys/bus/usb/devices 2>/dev/null | grep -q '^usb' && echo 1 || echo 0; }
hw_flash_free_kb() { df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }'; }
hw_pm() { command -v apk >/dev/null 2>&1 && echo apk || echo opkg; }

hw_json() {
    local lan; lan=$(hw_lan_ports | tr '\n' ' ')
    json_ok "$(jstr board "$(hw_board)"),$(jstr model "$(hw_model)"),$(jstr wan "$(hw_wan)"),$(jstr lan "$lan"),$(jbool dsa "$(hw_dsa && echo 1 || echo 0)"),$(jstr radios "$(hw_radios | tr '\n' ' ')"),$(jbool usb "$(hw_usb)"),$(jnum flash_free_kb "$(hw_flash_free_kb)"),$(jnum mem_kb "$MW_MEM_KB"),$(jbool low_memory "$MW_LOWMEM"),$(jstr package_manager "$(hw_pm)"),$(jnum max_lines "$(hw_max_lines)")"
}

hw_max_lines() {           # the WAN port, plus LAN ports while at least one stays a LAN port
    local n; n=$(hw_lan_ports | grep -c .)
    if ! hw_dsa; then echo 1; return; fi
    [ "$n" -ge 3 ] && echo 3 || { [ "$n" -ge 2 ] && echo 2 || echo 1; }
}

hw_env() {                 # <lines 1..3>: PORT_* and feature defaults for mwan.env
    local want="${1:-2}" max wan lan w2="" w3="" rest
    max=$(hw_max_lines); [ "$want" -gt "$max" ] && want=$max
    wan=$(hw_wan); lan=$(hw_lan_ports | tr '\n' ' ')
    set -- $lan
    [ "$want" -ge 2 ] && { w2="$1"; shift; }
    [ "$want" -ge 3 ] && { w3="$1"; shift; }
    rest="$*"
    echo "PORT_WAN1='$wan'"; echo "PORT_WAN2='$w2'"; echo "PORT_WAN3='$w3'"; echo "PORTS_LAN='$rest'"
    echo "WAN2_ENABLED='$([ -n "$w2" ] && echo 1 || echo 0)'"; echo "WAN3_ENABLED='$([ -n "$w3" ] && echo 1 || echo 0)'"
    echo "FEAT_DRIVES='$(hw_usb)'"
    echo "FEAT_SPEEDTEST='1'"
    # under 8 MB free: nothing optional beyond what the panel needs
    if [ "$(hw_flash_free_kb)" -lt 8192 ]; then echo "FEAT_WIREGUARD='0'"; echo "FEAT_DDNS='0'"; echo "FEAT_SQM='0'"; echo "FEAT_ADBLOCK='0'"; fi
    [ -z "$(hw_radios)" ] && echo "WIFI_GUEST_ENABLE='0'"
}

case "${0##*/}" in
    hwdetect.sh)
        case "$1" in
            json) hw_json ;;
            env)  hw_env "$2" ;;
            *)    echo "board: $(hw_board) ($(hw_model))"; echo "wan: $(hw_wan)"; echo "lan: $(hw_lan_ports | tr '\n' ' ') (dsa: $(hw_dsa && echo yes || echo no))"
                  echo "radios: $(hw_radios | tr '\n' ' ')  usb: $(hw_usb)  flash free: $(hw_flash_free_kb) KB  memory: $MW_MEM_KB KB (low: $MW_LOWMEM)"
                  echo "most internet lines: $(hw_max_lines)  package manager: $(hw_pm)" ;;
        esac ;;
esac
