#!/bin/sh
# setup-repeater.sh — turn a freshly flashed OpenWrt EA8100 into a wireless
# repeater for the main Baytaar router.
#
#   sh setup-repeater.sh <number> <wifi-name> <wifi-password> "<ssh public key>"
#
# After this the box needs power only. It joins the main router's 5 GHz Wi-Fi
# as a WDS client (a transparent bridge, so every phone behind it is still
# seen by the main router as itself: sign-in, blocking and usage keep
# working), and re-broadcasts the same Wi-Fi name on 2.4 and 5 GHz. It hands
# out no addresses and does no routing: the main router does all of that.
# Its four LAN sockets work as extra sockets of the main network. The
# "Internet" socket is left unused on purpose, so a cable to the main router
# can never form a loop with the wireless link.
N="$1"; SSID="$2"; KEY="$3"; PUB="$4"
[ -n "$N" ] && [ -n "$SSID" ] && [ "${#KEY}" -ge 8 ] || { echo "usage: setup-repeater.sh <number> <ssid> <key> [pubkey]"; exit 1; }

# --- access
if [ -n "$PUB" ]; then
    mkdir -p /etc/dropbear
    echo "$PUB" > /etc/dropbear/authorized_keys
    chmod 600 /etc/dropbear/authorized_keys
fi
uci set system.@system[0].hostname="Baytaar-Repeater-$N"
uci set system.@system[0].zonename='Asia/Karachi'
uci set system.@system[0].timezone='PKT-5'
uci commit system

# --- network: one bridge, address from the main router, plus a fixed
#     service address that always answers on the LAN sockets
uci -q delete network.wan
uci -q delete network.wan6
BR=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n1)
[ -n "$BR" ] && uci set "network.$BR.stp=1"
uci set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci -q delete network.lan.ip6assign
uci set network.lan.hostname="Baytaar-Repeater-$N"
uci set network.service='interface'
uci set network.service.device='br-lan'
uci set network.service.proto='static'
uci set network.service.ipaddr="192.168.77.1$N"
uci set network.service.netmask='255.255.255.0'
uci commit network

# --- it must not act as a router
/etc/init.d/dnsmasq disable
/etc/init.d/odhcpd disable
/etc/init.d/firewall disable

# --- Wi-Fi
case "$N" in 1|3) CH24=1 ;; *) CH24=11 ;; esac
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do uci delete "wireless.$s"; done
for r in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
    uci set "wireless.$r.country=PK"
    uci set "wireless.$r.disabled=0"
    if [ "$(uci -q get "wireless.$r.band")" = "5g" ]; then
        uci set "wireless.$r.channel=157"
        uci set "wireless.$r.htmode=VHT80"
        uci set wireless.uplink='wifi-iface'
        uci set wireless.uplink.device="$r"
        uci set wireless.uplink.mode='sta'
        uci set wireless.uplink.wds='1'
        uci set wireless.uplink.network='lan'
        uci set wireless.uplink.ssid="$SSID"
        uci set wireless.uplink.encryption='psk2'
        uci set wireless.uplink.key="$KEY"
        ap=ap_5
    else
        uci set "wireless.$r.channel=$CH24"
        uci set "wireless.$r.htmode=HT20"
        ap=ap_24
    fi
    uci set "wireless.$ap=wifi-iface"
    uci set "wireless.$ap.device=$r"
    uci set "wireless.$ap.mode=ap"
    uci set "wireless.$ap.network=lan"
    uci set "wireless.$ap.ssid=$SSID"
    uci set "wireless.$ap.encryption=psk2"
    uci set "wireless.$ap.key=$KEY"
done
uci commit wireless
echo "configured repeater $N; rebooting"
( sleep 2; reboot ) >/dev/null 2>&1 &
