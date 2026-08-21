#!/bin/sh
# 40-wireless.sh — 2.4 GHz + 5 GHz AP, optional isolated guest SSID.
#
# Archer C6 v3 radios: MT7603EN (2.4 GHz) and MT7613BEN (5 GHz), both 2x2:2.
# This is an AC1200 device. There is NO 6 GHz radio and no WiFi 6 support —
# no configuration can add hardware that is not present.

. "$(dirname "$0")/mwan.env"

set -e
say()  { echo "[wifi] $*"; }
warn() { echo "[wifi] WARNING: $*" >&2; }

[ -f /etc/config/wireless ] || wifi config

# --- Locate the radios by band, not by index ---------------------------------
# radio0/radio1 ordering is not guaranteed stable across releases, so match on
# the band/hwmode property instead of assuming.
RADIO_24=""
RADIO_5=""
for r in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([a-z0-9]*\)=wifi-device$/\1/p"); do
    band=$(uci -q get wireless.$r.band) || true
    hw=$(uci -q get wireless.$r.hwmode) || true
    case "$band$hw" in
        *2g*|*11g*) RADIO_24="$r" ;;
        *5g*|*11a*) RADIO_5="$r"  ;;
    esac
done

[ -z "$RADIO_24" ] && warn "No 2.4 GHz radio found."
[ -z "$RADIO_5" ]  && warn "No 5 GHz radio found."

# --- WPA3 availability check --------------------------------------------------
ENC="$WIFI_ENCRYPTION"
case "$ENC" in
    sae|sae-mixed)
        # wpad-basic-* (the base image default) cannot do SAE. Silently falling
        # back would leave you believing WPA3 is on when it is not, so this
        # warns loudly and downgrades explicitly.
        if [ ! -f /usr/sbin/wpad ] || ! /usr/sbin/wpad -v 2>&1 | grep -qi 'sae\|wpa3' ; then
            if ! (opkg list-installed 2>/dev/null || apk info 2>/dev/null) | grep -qE 'wpad-(mbedtls|openssl|wolfssl)'; then
                warn "WPA3 ($ENC) requested but the installed wpad build is wpad-basic-*,
        which does not support SAE. FALLING BACK TO WPA2 (psk2).
        To get WPA3, run (over Ethernet, WiFi drops between the two):
            opkg remove wpad-basic-mbedtls && opkg install wpad-mbedtls
        then re-run this script."
                ENC="psk2"
            fi
        fi
        ;;
esac

# --- Radio setup --------------------------------------------------------------
setup_radio() {
    local r="$1" chan="$2" width="$3"
    [ -z "$r" ] && return 0
    uci set wireless.$r.disabled='0'
    uci set wireless.$r.country="$WIFI_COUNTRY"
    uci set wireless.$r.channel="$chan"
    uci set wireless.$r.htmode="$width"
}

# channel=auto lets hostapd pick the cleanest channel at startup.
# 2.4 GHz stays at HT20: HT40 occupies most of the band and, in any typical
# neighbourhood, causes more contention than the extra width recovers.
setup_radio "$RADIO_24" auto HT20
# 5 GHz at VHT80 — the full width this 2x2 radio supports.
setup_radio "$RADIO_5" auto VHT80

# --- Main SSIDs ---------------------------------------------------------------
mk_iface() {
    local sect="$1" radio="$2" ssid="$3" key="$4" net="$5" isolate="$6" hide="$7"
    [ -z "$radio" ] && return 0
    uci set wireless.$sect='wifi-iface'
    uci set wireless.$sect.device="$radio"
    uci set wireless.$sect.mode='ap'
    uci set wireless.$sect.network="$net"
    uci set wireless.$sect.ssid="$ssid"
    uci set wireless.$sect.encryption="$ENC"
    uci set wireless.$sect.key="$key"
    uci set wireless.$sect.disabled='0'
    [ "$isolate" = "1" ] && uci set wireless.$sect.isolate='1'
    # hidden=1 suppresses the SSID in beacon frames. See the warning in
    # mwan.env — this is an obscurity measure, not a security one.
    if [ "$hide" = "1" ]; then
        uci set wireless.$sect.hidden='1'
    else
        uci -q delete wireless.$sect.hidden || true
    fi
}

# Remove stock default wifi-ifaces so we do not end up with an extra open or
# stale SSID alongside ours.
#
# The character class here MUST include underscore. OpenWrt's stock section
# names are default_radio0 / default_radio1 — without _ in the class this
# regex silently matches nothing for either of them, on every run, forever.
# That is not hypothetical: it is exactly how this device ended up
# broadcasting two full sets of "Asani WMS Secured" networks side by side —
# the real wifi_24/wifi_5 pair this script creates, plus the untouched stock
# pair sitting right next to them, both carrying the SSID/password this
# script wrote into every wifi-iface section it could see, stock ones
# included, because mk_iface below never got a chance to differentiate them
# from sections meant to be deleted.
for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([a-z0-9_]*\)=wifi-iface$/\1/p"); do
    uci -q delete wireless.$s || true
done

HIDE="${WIFI_HIDDEN:-0}"
mk_iface wifi_24 "$RADIO_24" "$WIFI_SSID_24" "$WIFI_KEY" lan 0 "$HIDE"
mk_iface wifi_5  "$RADIO_5"  "$WIFI_SSID_5"  "$WIFI_KEY" lan 0 "$HIDE"

# --- Guest SSIDs --------------------------------------------------------------
# isolate=1 blocks client-to-client traffic at layer 2 within the SSID. The
# firewall guest zone handles layer 3 isolation from the LAN; both are needed,
# because L3 rules alone do not stop two guests talking directly.
# Guest SSIDs are never hidden — a guest network you have to type the name of
# defeats its own purpose.
if [ "$WIFI_GUEST_ENABLE" = "1" ]; then
    mk_iface wifi_guest_24 "$RADIO_24" "$WIFI_GUEST_SSID"    "$WIFI_GUEST_KEY" guest 1 0
    mk_iface wifi_guest_5  "$RADIO_5"  "$WIFI_GUEST_SSID-5G" "$WIFI_GUEST_KEY" guest 1 0
fi

# --- Weak credential guard ----------------------------------------------------
case "$WIFI_KEY" in
    CHANGEME*) warn "WIFI_KEY is still the default placeholder. Change it in mwan.env." ;;
esac
[ ${#WIFI_KEY} -lt 8 ] && warn "WIFI_KEY is shorter than 8 characters; WPA2 will reject it."

uci commit wireless
say "wireless config written. Applying..."
wifi reload

say "done. 2.4GHz='$WIFI_SSID_24'  5GHz='$WIFI_SSID_5'  encryption=$ENC  country=$WIFI_COUNTRY"
[ "$WIFI_GUEST_ENABLE" = "1" ] && say "guest='$WIFI_GUEST_SSID' (isolated, internet only)"
