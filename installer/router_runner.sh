#!/bin/sh
# Baytaar installer, on the router: every step in order, detached from the PC's connection (the network step changes the
# router's address, which drops the PC's connection; this keeps going). Written to the router by the Windows installer
# together with config/ (the stage scripts and mwan.env), install.env (website, key, router password, name) and fw.tar.gz.
#
# Progress: /tmp/baytaar-install/status (and, once the panel is installed, /www/mwadmin/install-status.txt so the PC can
# read it at the router's new address). The log is /tmp/baytaar-install/log.

D=/tmp/baytaar-install
S="$D/status"; L="$D/log"
cd "$D" || exit 1
. ./install.env

pub() { [ -d /www/mwadmin ] && { cat "$S"; [ -s "$D/result" ] && cat "$D/result"; } > /www/mwadmin/install-status.txt 2>/dev/null; }
st()  { echo "$1" > "$S"; echo "=== $(date '+%H:%M:%S') $1" >> "$L"; pub; }
note() { echo "$1" >> "$D/result"; pub; }
fail() { echo "failed: $1" > "$S"; echo "=== FAILED: $1" >> "$L"; pub; rm -f "$D/install.env"
         /etc/init.d/mwadmin restart >/dev/null 2>&1; exit 1; }     # so the PC can read the failure at the current address

. ./config/mwan.env

# 1. internet on the main line, as it will be set (a fresh OpenWrt has DHCP on the WAN port)
st "internet"
case "$WAN1_PROTO" in
    static)
        uci set network.wan.proto='static'; uci set network.wan.ipaddr="$WAN1_IPADDR"; uci set network.wan.netmask="$WAN1_NETMASK"
        uci set network.wan.gateway="$WAN1_GATEWAY"; uci -q delete network.wan.dns
        for d in $WAN1_DNS; do uci add_list network.wan.dns="$d"; done
        uci commit network; ifup wan ;;
    pppoe)
        uci set network.wan.proto='pppoe'; uci set network.wan.username="$WAN1_PPPOE_USER"; uci set network.wan.password="$WAN1_PPPOE_PASS"
        uci commit network; ifup wan ;;
esac
ok=0; i=0
while [ $i -lt 45 ]; do
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && nslookup downloads.openwrt.org >/dev/null 2>&1; then ok=1; break; fi
    i=$((i + 1)); sleep 2
done
[ $ok -eq 1 ] || fail "no internet on the WAN port (is the modem's cable in the router's internet port?)"

# 2. the packages MultiWAN needs
st "packages"
sh ./config/00-packages.sh >> "$L" 2>&1 || fail "installing packages (see the log)"

# 3. the Baytaar software (checked on the PC against the website's checksum)
st "software"
mkdir -p fw && tar xzf fw.tar.gz -C fw >> "$L" 2>&1 || fail "unpacking the Baytaar software"
( cd fw && sh ./apply.sh "$FW_VERSION" ) >> "$L" 2>&1 || fail "installing the Baytaar software"
[ -n "$ROUTER_NAME" ] && { uci set system.@system[0].hostname="$ROUTER_NAME"; uci commit system; }

# 4. join the website account with the API key (failure here is not fatal: it can be done later from the panel)
if [ -n "$WEB_SITE" ] && [ -n "$WEB_KEY" ]; then
    st "website"
    if sh /usr/lib/mwadmin/connect.sh join "$WEB_SITE" "$WEB_KEY" >> "$L" 2>&1; then note "website=joined"
    else note "website=failed"; fi
fi

# 5. the router's own settings, stage by stage (the network stage changes the address: the PC's connection drops here)
st "network";  sh ./config/10-network.sh     >> "$L" 2>&1 || fail "network settings"
sleep 5; /etc/init.d/mwadmin restart >/dev/null 2>&1          # the panel (and the progress file) now answer at the new address
pub
st "firewall"; sh ./config/20-firewall.sh    >> "$L" 2>&1 || fail "firewall settings"
st "dhcp";     sh ./config/50-system-dhcp.sh >> "$L" 2>&1 || fail "address and name settings"
st "wifi";     sh ./config/40-wireless.sh    >> "$L" 2>&1 || fail "Wi-Fi settings"
st "lines";    sh ./config/30-mwan3.sh       >> "$L" 2>&1 || fail "internet line settings"

# 6. the router password (last, so nothing above needed it)
st "password"
printf '%s\n%s\n' "$ROUTER_PASSWORD" "$ROUTER_PASSWORD" | passwd root >> "$L" 2>&1 || fail "setting the router password"

# 7. done: keep a copy of the log on flash, forget the secrets, restart cleanly on the new address
cp "$L" /root/baytaar-install.log 2>/dev/null
rm -f "$D/install.env"
st "done"
sleep 3
reboot
