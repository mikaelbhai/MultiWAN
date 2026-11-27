#!/bin/sh
# setup.sh - everything the Baytaar software needs on the router after its files are in place: services, the sign-in
# page server, the website token, firewall/sysctl details. Run by apply.sh (website upgrade) and by the OpenWrt package
# (postinst). Safe to run again. Usage: setup.sh <version>
VER="${1:-unknown}"

# pages and scripts from older versions; the panel is now index.html alone
rm -f /www/mwadmin/app.js /www/mwadmin/app.css /www/mwadmin/simple.js /www/mwadmin/simple.css /www/mwadmin/easy.html /www/mwadmin/setup.html

# 3. the sign-in / block page listens on its own port
if [ "$(uci -q get uhttpd.mwguest)" != "uhttpd" ] || [ "$(uci -q get uhttpd.mwguest.index_page)" != "cgi-bin/guest" ]; then
    uci set uhttpd.mwguest=uhttpd
    uci set uhttpd.mwguest.home=/www/mwguest
    uci set uhttpd.mwguest.cgi_prefix=/cgi-bin
    uci set uhttpd.mwguest.error_page=/cgi-bin/guest
    uci set uhttpd.mwguest.no_dirlists=1
    uci set uhttpd.mwguest.max_requests=8
    uci set uhttpd.mwguest.script_timeout=20
    uci -q delete uhttpd.mwguest.index_page
    uci add_list uhttpd.mwguest.index_page=cgi-bin/guest
    uci -q delete uhttpd.mwguest.listen_http
    uci add_list uhttpd.mwguest.listen_http=0.0.0.0:8188
    uci add_list uhttpd.mwguest.listen_http='[::]:8188'
    uci commit uhttpd
    /etc/init.d/uhttpd restart >/dev/null 2>&1
fi

# 4. the token the management website presents instead of the router password
[ -s /etc/mwadmin/portal_token ] || { head -c 32 /dev/urandom | hexdump -ve '1/1 "%02x"' > /etc/mwadmin/portal_token; chmod 600 /etc/mwadmin/portal_token; }

# 5. helpers the features need (only fetched when missing)
command -v conntrack >/dev/null 2>&1 || { apk add conntrack >/dev/null 2>&1 || true; }

# the website tunnel uses Dropbear's client; convert an OpenSSH-format key
# once (same key, so the website's access list does not change)
if [ -f /etc/mwadmin/remote_id_ed25519 ] && [ ! -s /etc/mwadmin/remote_id_dropbear ]; then
    had=0; command -v dropbearconvert >/dev/null 2>&1 && had=1
    [ $had -eq 1 ] || apk add dropbearconvert >/dev/null 2>&1
    dropbearconvert openssh dropbear /etc/mwadmin/remote_id_ed25519 /etc/mwadmin/remote_id_dropbear >/dev/null 2>&1 && chmod 600 /etc/mwadmin/remote_id_dropbear
    [ $had -eq 1 ] || apk del dropbearconvert >/dev/null 2>&1
    [ "$(uci -q get mwadmin.remote.enabled)" = "1" ] && /etc/init.d/mwremote restart >/dev/null 2>&1
fi

# 6. background services
/etc/init.d/mwsite enable >/dev/null 2>&1
/etc/init.d/mwblock enable >/dev/null 2>&1
/etc/init.d/mwsite restart >/dev/null 2>&1
/etc/init.d/mwblock restart >/dev/null 2>&1
/etc/init.d/mwevents enable >/dev/null 2>&1
/etc/init.d/mwevents restart >/dev/null 2>&1
# the "this site is blocked" page gets its own LAN address (.253), separate
# from the admin panel's .254 alias, so http://multiwan.router keeps working
if [ -z "$(uci -q get network.lan_block)" ]; then
    lanip=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
    if [ -n "$lanip" ]; then
        uci set network.lan_block=interface
        uci set network.lan_block.device=br-lan
        uci set network.lan_block.proto=static
        uci set network.lan_block.ipaddr="${lanip%.*}.253"
        uci set network.lan_block.netmask=255.255.255.255
        uci commit network
        /etc/init.d/network reload >/dev/null 2>&1
        sleep 3
        sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/block.sh; block_apply' >/dev/null 2>&1
    fi
fi

# routes on an unplugged port (a static WAN with no cable) must not be used,
# or the router's own traffic leaves with that port's address and is dropped
printf 'net.ipv4.conf.all.ignore_routes_with_linkdown=1
net.ipv4.conf.default.ignore_routes_with_linkdown=1
' > /etc/sysctl.d/90-mwadmin-linkdown.conf
sysctl -p /etc/sysctl.d/90-mwadmin-linkdown.conf >/dev/null 2>&1
/etc/init.d/mwrelay enable >/dev/null 2>&1
[ "$(uci -q get mwadmin.remote.enabled)" = "1" ] && /etc/init.d/mwremote restart >/dev/null 2>&1
echo 'net.core.rmem_max=524288' > /etc/sysctl.d/91-mwadmin-nlbwmon.conf
sysctl -p /etc/sysctl.d/91-mwadmin-nlbwmon.conf >/dev/null 2>&1
/etc/init.d/mwexempt enable >/dev/null 2>&1
/etc/init.d/mwexempt restart >/dev/null 2>&1
# shared USB drives (only does anything once drive support is installed)
/etc/init.d/mwdrive enable >/dev/null 2>&1
[ -x /usr/sbin/ksmbd.mountd ] && sh /usr/lib/mwadmin/drive.sh boot >/dev/null 2>&1
# the short-lived site whitelist is gone; never-blocked devices replace it
rm -f /etc/mwadmin/allowed_sites
[ -f /etc/adblock/adblock.allowlist ] && sed -i '/^# mwadmin-allowed$/,$d' /etc/adblock/adblock.allowlist
/etc/init.d/mwrelay restart >/dev/null 2>&1
sh /usr/lib/mwadmin/guest.sh tick >/dev/null 2>&1
# 18+ filter for every device (on unless turned off); the old adblock-feed
# version of it never applied to never-blocked devices
uci -q del_list adblock.global.adb_feed='oisd_nsfw_small' && uci commit adblock
sh /usr/lib/mwadmin/adult.sh apply >/dev/null 2>&1
# free time / break time (pause.sh): defaults 60 min a day, break 13:00-14:00;
# reload the blocker so its table has the "free" set
sh -c '. /usr/lib/mwadmin/block.sh; pause_ensure; pause_portal; block_apply; pause_tick' >/dev/null 2>&1

# the website certificate bundle is rebuilt from le-intermediates.pem on next use
rm -f /tmp/mwadmin-cabundle.pem

echo "$VER" > /etc/mwadmin/fw_version
echo "set up $VER"
