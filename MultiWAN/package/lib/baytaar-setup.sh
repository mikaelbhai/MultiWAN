#!/bin/sh
# baytaar-setup - first-time setup of the Baytaar MultiWAN package on ANY OpenWrt router (docs/14). Run it over SSH:
#   baytaar-setup
# It finds this router's ports and radios (hwdetect.sh), asks the essentials, writes the settings and applies the
# stage scripts (/usr/share/baytaar/config) in the background: the network step changes the router's address, so
# the SSH session drops; progress is in /tmp/baytaar-setup.log. Optionally joins a website account with an API key.

. /usr/lib/mwadmin/common.sh
CFG=/usr/share/baytaar/config
[ -d "$CFG" ] || { echo "The stage scripts are missing ($CFG). Reinstall the baytaar-multiwan package."; exit 1; }
HW="sh /usr/lib/mwadmin/hwdetect.sh"

ask() {   # <question> <default> -> answer in $A
    printf '%s [%s]: ' "$1" "$2"; read -r A; [ -n "$A" ] || A="$2"
}
askpw() { # <question> -> $A (not echoed)
    stty -echo 2>/dev/null; printf '%s: ' "$1"; read -r A; stty echo 2>/dev/null; echo
}
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

echo "== Baytaar MultiWAN setup"
$HW
max=$(sh -c '. /usr/lib/mwadmin/hwdetect.sh; hw_max_lines')
echo
ask "How many internet lines (1-$max)" "$( [ "$max" -ge 2 ] && echo 2 || echo 1)"; lines=$A
ask "Main line: dhcp, static or pppoe" "dhcp"; proto=$A
ip=""; mask="255.255.255.0"; gw=""; puser=""; ppass=""
if [ "$proto" = "static" ]; then ask "  Address" ""; ip=$A; ask "  Netmask" "$mask"; mask=$A; ask "  Gateway" ""; gw=$A; fi
if [ "$proto" = "pppoe" ]; then ask "  PPPoE username" ""; puser=$A; askpw "  PPPoE password"; ppass=$A; fi
ask "Router address" "192.168.20.1"; lanip=$A
ssid=""; wkey=""
if [ -n "$(sh -c '. /usr/lib/mwadmin/hwdetect.sh; hw_radios')" ]; then
    ask "Wi-Fi name" "Baytaar"; ssid=$A
    while :; do askpw "Wi-Fi password (8+ characters)"; wkey=$A; [ ${#wkey} -ge 8 ] && break; echo "  too short"; done
    ask "Country (2 letters)" "PK"; country=$A
fi
ask "Website to join (empty to skip)" "mikaelbhai.com"; site=$A
key=""; [ -n "$site" ] && { ask "API key from the website (Add a router)" ""; key=$A; }

mkdir -p /etc/baytaar
{
    cat "$CFG/mwan.env.example"
    echo; echo "# --- written by baytaar-setup $(date) ---"
    $HW env "$lines"
    echo "WAN1_PROTO=$(q "$proto")"; echo "WAN1_IPADDR=$(q "$ip")"; echo "WAN1_NETMASK=$(q "$mask")"; echo "WAN1_GATEWAY=$(q "$gw")"
    echo "WAN1_PPPOE_USER=$(q "$puser")"; echo "WAN1_PPPOE_PASS=$(q "$ppass")"
    echo "LAN_IPADDR=$(q "$lanip")"; echo "LAN_NETMASK='255.255.255.0'"
    [ -n "$ssid" ] && { echo "WIFI_SSID_24=$(q "$ssid")"; echo "WIFI_SSID_5=$(q "$ssid")"; echo "WIFI_KEY=$(q "$wkey")"; echo "WIFI_COUNTRY=$(q "${country:-PK}")"; echo "WIFI_GUEST_ENABLE='0'"; }
} > /etc/baytaar/mwan.env
chmod 600 /etc/baytaar/mwan.env
rm -rf /tmp/baytaar-setup; mkdir -p /tmp/baytaar-setup; cp "$CFG"/*.sh /tmp/baytaar-setup/; cp /etc/baytaar/mwan.env /tmp/baytaar-setup/mwan.env

cat > /tmp/baytaar-setup/run.sh <<EOF
#!/bin/sh
cd /tmp/baytaar-setup
L=/tmp/baytaar-setup.log
for s in 00-packages 10-network 20-firewall 50-system-dhcp 40-wireless 30-mwan3; do
    echo "=== \$s" >> \$L
    sh ./\$s.sh >> \$L 2>&1 || { echo "FAILED at \$s" >> \$L; exit 1; }
    [ "\$s" = 10-network ] && { sleep 5; /etc/init.d/mwadmin restart >/dev/null 2>&1; }
done
$( [ -n "$key" ] && echo "sh /usr/lib/mwadmin/connect.sh join $(q "$site") $(q "$key") >> \$L 2>&1" )
echo "=== done" >> \$L
EOF
echo
echo "Applying in the background. This SSH session drops when the address changes to $lanip."
echo "Then: ssh root@$lanip  and  tail /tmp/baytaar-setup.log ;  the panel is http://$lanip:8080"
(nohup sh /tmp/baytaar-setup/run.sh </dev/null >/dev/null 2>&1 &)
