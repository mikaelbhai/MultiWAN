#!/bin/sh
# 00-packages.sh — install required packages, with a flash budget check first.
#
# Handles both opkg (OpenWrt <= 24.10) and apk (OpenWrt >= 25.12).

. "$(dirname "$0")/mwan.env"

set -e

say()  { echo "[pkg] $*"; }
warn() { echo "[pkg] WARNING: $*" >&2; }
die()  { echo "[pkg] FATAL: $*" >&2; exit 1; }

# --- Pick the package manager -----------------------------------------------
if command -v apk >/dev/null 2>&1; then
    PM="apk"
    pm_update() { apk update; }
    pm_install() { apk add --no-interactive "$@"; }
    pm_installed() { apk info -e "$1" >/dev/null 2>&1; }
elif command -v opkg >/dev/null 2>&1; then
    PM="opkg"
    pm_update() { opkg update; }
    pm_install() { opkg install "$@"; }
    pm_installed() { opkg list-installed 2>/dev/null | grep -q "^$1 "; }
else
    die "Neither apk nor opkg found. Is this really OpenWrt?"
fi
say "Using package manager: $PM"

# --- Flash budget check ------------------------------------------------------
# 16 MB NOR flash. Refuse to start an install that will fill the overlay,
# because a full overlay on OpenWrt produces confusing failures rather than
# clean "out of space" errors.
avail_kb=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
[ -z "$avail_kb" ] && avail_kb=$(df -k / | awk 'NR==2 {print $4}')
say "Free overlay space: $((avail_kb / 1024)) MB"

if [ "$avail_kb" -lt 1536 ]; then
    die "Less than 1.5 MB free on /overlay. Refusing to install.
     This device has 16 MB of flash and is already near capacity.
     Free space, or disable optional features in mwan.env (FEAT_*),
     or reflash with a slimmer image."
elif [ "$avail_kb" -lt 3072 ]; then
    warn "Under 3 MB free. Consider disabling optional FEAT_* items in mwan.env."
fi

pm_update

# --- Required ----------------------------------------------------------------
# mwan3 pulls in ip-full and the netfilter pieces it needs.
#
# nlbwmon is the admin UI's Devices tab: per-device upload/download, sourced
# from conntrack rather than a hand-rolled nftables accounting table, since
# OpenWrt already ships and maintains exactly this. ~70 KB combined with its
# kernel module dependency — cheap enough to just always install rather than
# gate behind a FEAT_* flag like the truly optional packages below.
REQUIRED="mwan3 nlbwmon"

# PPPoE on WAN1 needs the ppp plugin. Stock OpenWrt images normally ship
# ppp + ppp-mod-pppoe already; this only adds them if they are genuinely
# missing (e.g. a slimmed custom image), so it usually costs nothing.
if [ "${WAN1_PROTO:-static}" = "pppoe" ]; then
    pm_installed ppp-mod-pppoe || REQUIRED="$REQUIRED ppp ppp-mod-pppoe"
fi

# --- Optional, gated by mwan.env --------------------------------------------
OPTIONAL=""
[ "$FEAT_SPEEDTEST" = "1" ] && OPTIONAL="$OPTIONAL curl"
[ "$FEAT_WIREGUARD" = "1" ] && OPTIONAL="$OPTIONAL wireguard-tools kmod-wireguard"
[ "$FEAT_DDNS"      = "1" ] && OPTIONAL="$OPTIONAL ddns-scripts"
[ "$FEAT_SQM"       = "1" ] && OPTIONAL="$OPTIONAL sqm-scripts"
[ "$FEAT_UPNP"      = "1" ] && OPTIONAL="$OPTIONAL miniupnpd-nftables"

say "Installing required: $REQUIRED"
# shellcheck disable=SC2086
pm_install $REQUIRED || die "Failed to install required packages."

for p in $OPTIONAL; do
    if pm_installed "$p"; then
        say "$p already present, skipping"
        continue
    fi
    say "Installing optional: $p"
    # Optional packages must not abort the whole install. miniupnpd in
    # particular has different names across releases (nftables vs iptables
    # variant), and ddns-scripts pulls varying TLS backends.
    pm_install "$p" || warn "Could not install '$p' — continuing without it.
        If you need it, install it manually and re-run the relevant config script."
done

# --- WPA3 note ---------------------------------------------------------------
# The base image ships wpad-basic-mbedtls, which does NOT support WPA3/SAE.
# Swapping it is a two-step remove+install that briefly drops WiFi, so it is
# not done automatically. 40-wireless.sh detects the situation and tells you.
if [ "$WIFI_ENCRYPTION" = "sae" ] || [ "$WIFI_ENCRYPTION" = "sae-mixed" ]; then
    if ! pm_installed wpad-mbedtls && ! pm_installed wpad-openssl && \
       ! pm_installed wpad-wolfssl; then
        warn "WIFI_ENCRYPTION is '$WIFI_ENCRYPTION' (WPA3) but only wpad-basic-* is
        installed, which cannot do SAE. To enable WPA3, run BOTH of these
        together (WiFi drops between them, so do it over Ethernet):

            $PM remove wpad-basic-mbedtls && $PM install wpad-mbedtls

        Then re-run 40-wireless.sh."
    fi
fi

# nlbwmon ships disabled by default. Its stock config needs no site-specific
# values (local_network already correctly defaults to the private ranges),
# so there is nothing to template here the way mwan3's own config needs —
# just turn it on.
/etc/init.d/nlbwmon enable >/dev/null 2>&1
/etc/init.d/nlbwmon start >/dev/null 2>&1

say "Package stage complete. Free overlay now: $(df -h /overlay 2>/dev/null | awk 'NR==2{print $4}')"
