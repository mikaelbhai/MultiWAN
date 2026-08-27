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
[ "$FEAT_ADBLOCK"   = "1" ] && OPTIONAL="$OPTIONAL adblock"
[ "$FEAT_ALERTS"    = "1" ] && OPTIONAL="$OPTIONAL msmtp"
# Remote Access (the outbound relay tunnel) needs no package here at all:
# confirmed live that dropbear's own client — already present on every
# OpenWrt install as /usr/bin/ssh — supports -R remote forwarding directly.

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

# --- Adblock: safe defaults, verified on this exact device --------------------
# The stock config defaults to three feed sources, one of them explicitly
# marked "L" (large) in adblock's own feed catalogue. Enabling that default
# on this 128 MB device triggered real memory pressure (kernel pre-OOM
# accounting logged, "dns backend restart with adblock blocklist failed") —
# confirmed by testing, not theoretical. Off by default even when installed;
# the admin UI's toggle is what actually turns it on.
#
# When you DO turn it on, this config uses custom feeds pointing directly at
# the source files, not the stock category feeds — both "stevenblack" and
# "hagezi" category indirection 404 on this build's fetch logic (confirmed:
# the bare base URL each constructs returns 404, while the correct full URL
# with the file path appended returns 200). The custom feeds sidestep that
# bug entirely by using the working URLs directly.
#
# Two feeds combined: StevenBlack's base hosts file (general ads/malware) plus
# Hagezi's "light" list (trackers, analytics SDKs, and OEM telemetry —
# Xiaomi/Huawei/Samsung etc — that StevenBlack's list doesn't cover; gap
# confirmed against a real-world sample of unblocked tracker domains).
# Result on this hardware: ~86,000 domains after dedup, well inside the
# available headroom (measured: ~2 MB of available RAM consumed).
if [ "$FEAT_ADBLOCK" = "1" ]; then
    uci set adblock.global.adb_enabled='0'
    uci -q delete adblock.global.adb_feed
    uci add_list adblock.global.adb_feed='stevenblack_direct'
    uci add_list adblock.global.adb_feed='hagezi_light'
    uci commit adblock

    cat > /etc/adblock/adblock.custom.feeds <<'EOF'
{
	"stevenblack_direct": {
		"url": "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
		"rule": "feed 0.0.0.0 2",
		"size": "M",
		"descr": "stevenblack base list, direct URL (category indirection 404s on this build)"
	},
	"hagezi_light": {
		"url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt",
		"rule": "feed 1",
		"size": "M",
		"descr": "hagezi light: ads, trackers, analytics, OEM telemetry (Xiaomi/Huawei/Samsung/etc), direct URL"
	}
}
EOF
    /etc/init.d/adblock enable >/dev/null 2>&1
    say "adblock installed, configured, left OFF — enable it from the admin UI (DNS page or Easy Setup)"
fi

say "Package stage complete. Free overlay now: $(df -h /overlay 2>/dev/null | awk 'NR==2{print $4}')"
