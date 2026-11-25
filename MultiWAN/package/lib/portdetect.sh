#!/bin/sh
# portdetect.sh — link state, negotiated speed, on-demand speed test, ISP lookup.
#
# Two distinct kinds of data live here, and the difference matters:
#
#   LIVE   — carrier, negotiated speed, duplex. Read straight from sysfs on
#            every request. Costs nothing, always current, never cached.
#
#   TESTED — throughput, latency, detected ISP. Expensive, consumes real
#            bandwidth, only runs on plug-in or explicit re-test. Cached with a
#            timestamp so the UI can show how stale it is.
#
# Conflating those two would produce a UI that either lies about link state or
# hammers your uplinks. They are kept strictly separate.

. /usr/lib/mwadmin/common.sh

# Endpoint for throughput measurement. Cloudflare's speed service is used
# because it is anycast (so it measures your link, not the distance to one
# datacentre), has no API key, and supports a caller-chosen transfer size.
SPEEDTEST_DOWN_URL="https://speed.cloudflare.com/__down?bytes=25000000"
SPEEDTEST_UP_URL="https://speed.cloudflare.com/__up"
SPEEDTEST_BYTES=25000000
ISP_LOOKUP_URL="http://ip-api.com/json/?fields=status,query,isp,org,as,countryCode,country,regionName,city"

# ---------------------------------------------------------------------------
# LIVE state
# ---------------------------------------------------------------------------

# Negotiated link speed straight from the DSA driver. This is the actual
# autonegotiation result, not a spec-sheet assumption.
port_link_json() {
    local port="$1"
    local sys="/sys/class/net/$port"
    local carrier=0 speed="null" duplex="unknown" mac="" operstate="down"

    if [ -d "$sys" ]; then
        carrier=$(cat "$sys/carrier" 2>/dev/null || echo 0)
        operstate=$(cat "$sys/operstate" 2>/dev/null || echo down)
        mac=$(cat "$sys/address" 2>/dev/null)
        # speed/duplex only read meaningfully while the link is up; the driver
        # returns -1 or errors otherwise.
        if [ "$carrier" = "1" ]; then
            local s d
            s=$(cat "$sys/speed" 2>/dev/null)
            d=$(cat "$sys/duplex" 2>/dev/null)
            case "$s" in
                10|100|1000|2500|5000|10000) speed="$s" ;;
            esac
            [ -n "$d" ] && duplex="$d"
        fi
    fi

    printf '{%s,%s,%s,%s,%s,%s}' \
        "$(jstr port "$port")" \
        "$(jbool carrier "$carrier")" \
        "$(jnum speed_mbps "$speed")" \
        "$(jstr duplex "$duplex")" \
        "$(jstr operstate "$operstate")" \
        "$(jstr mac "$mac")"
}

# Which logical interface (wan1/wan2/wan3/lan) owns a physical port.
port_role() {
    local port="$1" i dev
    for i in wan1 wan2 wan3; do
        dev=$(uget "network.$i.device")
        [ "$dev" = "$port" ] && { printf '%s' "$i"; return; }
    done
    for dev in $(uci -q get network.br_lan.ports 2>/dev/null); do
        [ "$dev" = "$port" ] && { printf 'lan'; return; }
    done
    printf 'unassigned'
}

# ---------------------------------------------------------------------------
# Byte counters, for the bandwidth graph
# ---------------------------------------------------------------------------
# Read from /proc/net/dev. No collector daemon, no RRD database, no flash
# writes — the UI samples this endpoint and computes deltas client-side.
iface_counters_json() {
    local dev="$1"
    local line rx tx
    line=$(grep -E "^[[:space:]]*$dev:" /proc/net/dev 2>/dev/null)
    if [ -z "$line" ]; then
        printf '{%s,%s,%s}' "$(jstr device "$dev")" "$(jnum rx_bytes 0)" "$(jnum tx_bytes 0)"
        return
    fi
    rx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $1}')
    tx=$(echo "$line" | awk -F: '{print $2}' | awk '{print $9}')
    printf '{%s,%s,%s,%s}' \
        "$(jstr device "$dev")" \
        "$(jnum rx_bytes "${rx:-0}")" \
        "$(jnum tx_bytes "${tx:-0}")" \
        "$(jnum ts "$(date +%s)")"
}

# ---------------------------------------------------------------------------
# TESTED state
# ---------------------------------------------------------------------------

# Source IP of a logical interface, needed to bind curl to a specific uplink.
iface_addr() {
    local iface="$1" dev
    dev=$(uget "network.$iface.device")
    [ -z "$dev" ] && return 1
    ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

iface_gateway() {
    local iface="$1" dev gw
    dev=$(uget "network.$iface.device")
    [ -z "$dev" ] && return 1
    gw=$(ip -4 route show dev "$dev" 2>/dev/null | awk '/default/ {print $3; exit}')
    # mwan3 moves default routes into its own tables, so a healthy interface can
    # legitimately have no default route in the main table. Fall back to the
    # configured value rather than reporting no gateway.
    [ -z "$gw" ] && gw=$(uget "network.$iface.gateway")
    printf '%s' "$gw"
}

# Run a command forced out through one line. Binding curl to the line's
# address is not enough while mwan3 marks the router's own traffic: in
# balance or failover it could still leave by another line, and the test
# then measured and named the wrong provider. "mwan3 use" pins it.
PD_IFACE=""
pd_on() {
    if [ -n "$PD_IFACE" ] && command -v mwan3 >/dev/null 2>&1 && [ -n "$(uci -q get mwan3.$PD_IFACE)" ]; then
        mwan3 use "$PD_IFACE" "$@" 2>/dev/null | sed "/^Running '.*' with DEVICE=/d"
    else
        "$@"
    fi
}

measure_latency() {
    local dev="$1" target="$2"
    # -I binds to the device so the probe genuinely traverses that uplink
    # rather than following the current default route.
    ping -I "$dev" -c 4 -W 2 -q "$target" 2>/dev/null | \
        awk -F'/' '/^(round-trip|rtt)/ {printf "%.1f", $5}'
}

# Returns Mbps as a decimal string, or empty on failure.
measure_download() {
    local addr="$1"
    local bps
    # --interface binds the socket to this uplink's source address.
    # %{speed_download} is bytes/sec measured by curl over the whole transfer.
    bps=$(pd_on curl --interface "$addr" \
               --max-time 30 \
               --silent --show-error --output /dev/null \
               --write-out '%{speed_download}' \
               "$SPEEDTEST_DOWN_URL" 2>/dev/null)
    [ -z "$bps" ] && return 1
    awk -v b="$bps" 'BEGIN { if (b <= 0) exit 1; printf "%.1f", (b * 8) / 1000000 }'
}

measure_upload() {
    local addr="$1"
    local bps
    # 8 MB upload rather than 25 MB: these are asymmetric consumer lines and a
    # 25 MB upload on a 100 Mb link with a slow uplink would take far too long.
    bps=$(dd if=/dev/zero bs=64k count=128 2>/dev/null | \
          pd_on curl --interface "$addr" \
               --max-time 30 \
               --silent --show-error --output /dev/null \
               --write-out '%{speed_upload}' \
               --data-binary @- \
               -H 'Content-Type: application/octet-stream' \
               "$SPEEDTEST_UP_URL" 2>/dev/null)
    [ -z "$bps" ] && return 1
    awk -v b="$bps" 'BEGIN { if (b <= 0) exit 1; printf "%.1f", (b * 8) / 1000000 }'
}

# Best-effort ISP identification. Three independent signals, because any one of
# them can be missing or wrong:
#   1. ASN/org from a public IP geolocation API  (most informative, needs internet)
#   2. Reverse DNS of the gateway                (works even without internet)
#   3. DHCP lease vendor/server info             (works on DHCP uplinks only)
detect_isp() {
    local iface="$1" addr="$2" dev="$3"
    local isp="" asn="" pubip="" rdns="" gw

    if [ -n "$addr" ]; then
        local resp
        resp=$(pd_on curl --interface "$addr" --max-time 8 --silent "$ISP_LOOKUP_URL" 2>/dev/null)
        if [ -n "$resp" ]; then
            isp=$(echo "$resp"   | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
            asn=$(echo "$resp"   | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')
            pubip=$(echo "$resp" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
            # Kept whole so run_port_test can read where this public IP
            # geolocates to (city/region/country) without a second lookup.
            printf '%s' "$resp" > "$MW_RUN/ports/$iface.ipinfo"
        fi
    fi

    gw=$(iface_gateway "$iface")
    if [ -n "$gw" ]; then
        rdns=$(nslookup "$gw" 2>/dev/null | awk '/name = /{print $NF; exit}' | sed 's/\.$//')
    fi

    # DHCP uplinks record the server that issued the lease.
    local dhcpsrv=""
    if [ -f "/tmp/dhcp.leases.$dev" ]; then
        dhcpsrv=$(sed -n 's/.*serverid.*=\(.*\)/\1/p' "/tmp/dhcp.leases.$dev" 2>/dev/null | head -n1)
    fi

    printf '%s,%s,%s,%s,%s' "$isp" "$asn" "$pubip" "$rdns" "$dhcpsrv"
}

# Full test for one logical WAN. Writes a JSON result file.
run_port_test() {
    local iface="$1"
    PD_IFACE="$iface"
    valid_iface "$iface" || { log "run_port_test: invalid iface '$iface'"; return 1; }

    local dev
    dev=$(uget "network.$iface.device")
    [ -z "$dev" ] && { log "run_port_test: $iface has no device"; return 1; }

    if ! lock_acquire "test-$iface"; then
        log "run_port_test: a test is already running on $iface"
        return 1
    fi
    # shellcheck disable=SC2064
    trap "lock_release 'test-$iface'" EXIT INT TERM

    local out="$MW_RUN/ports/$iface.json"
    local ts; ts=$(date +%s)

    write_status() {
        printf '{%s,%s,%s,%s,%s}\n' \
            "$(jstr iface "$iface")" "$(jstr device "$dev")" \
            "$(jstr status "$1")" "$(jstr message "$2")" \
            "$(jnum started "$ts")" > "$out"
    }

    write_status running "Checking link..."

    # --- Gate 1: is there a cable? ------------------------------------------
    if [ "$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)" != "1" ]; then
        write_status nolink "No cable detected on $dev"
        lock_release "test-$iface"; trap - EXIT; return 0
    fi

    # --- Gate 2: is there an address? ---------------------------------------
    # This is the DHCP limitation stated up front in the brief: nothing below
    # this line can run until the interface has actually been assigned an IP.
    # Link-up alone is not enough.
    write_status running "Waiting for an IP address..."
    local addr="" i=0
    while [ $i -lt 30 ]; do
        addr=$(iface_addr "$iface")
        [ -n "$addr" ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ -z "$addr" ]; then
        write_status noaddr "Link is up but no IP address after 30 s (DHCP failure, or the line is dead)"
        lock_release "test-$iface"; trap - EXIT; return 0
    fi

    # --- Latency -------------------------------------------------------------
    write_status running "Measuring latency..."
    local lat; lat=$(measure_latency "$dev" 1.1.1.1)
    [ -z "$lat" ] && lat=$(measure_latency "$dev" 8.8.8.8)

    # --- ISP -----------------------------------------------------------------
    write_status running "Identifying provider..."
    local ispdata isp asn pubip rdns dhcpsrv
    ispdata=$(detect_isp "$iface" "$addr" "$dev")
    IFS=',' read -r isp asn pubip rdns dhcpsrv <<EOF
$ispdata
EOF

    # --- Throughput ----------------------------------------------------------
    local down="" up="" note=""
    if command -v curl >/dev/null 2>&1; then
        write_status running "Running download test..."
        down=$(measure_download "$addr")
        write_status running "Running upload test..."
        up=$(measure_upload "$addr")

        # The measurement ceiling is the router's own CPU, not the line.
        # Reporting ~300 Mbps on a gigabit link as though it were the line
        # speed would be actively misleading, so the result is annotated.
        if [ -n "$down" ]; then
            local hi; hi=$(awk -v d="$down" 'BEGIN{print (d > 250) ? 1 : 0}')
            [ "$hi" = "1" ] && note="Measured value is at or near this router's CPU ceiling for TLS transfers. The line is at least this fast; it may be considerably faster."
        fi
    else
        note="curl is not installed, so throughput was not measured. Install it with: opkg install curl"
    fi

    local linkspeed; linkspeed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
    case "$linkspeed" in ''|*[!0-9]*) linkspeed="null" ;; esac

    {
        printf '{'
        printf '%s,' "$(jstr iface "$iface")"
        printf '%s,' "$(jstr device "$dev")"
        printf '%s,' "$(jstr status ok)"
        printf '%s,' "$(jnum tested_at "$(date +%s)")"
        printf '%s,' "$(jnum link_speed_mbps "$linkspeed")"
        printf '%s,' "$(jstr address "$addr")"
        printf '%s,' "$(jnum latency_ms "${lat:-}")"
        printf '%s,' "$(jnum down_mbps "${down:-}")"
        printf '%s,' "$(jnum up_mbps "${up:-}")"
        printf '%s,' "$(jstr isp "${isp:-}")"
        printf '%s,' "$(jstr asn "${asn:-}")"
        printf '%s,' "$(jstr public_ip "${pubip:-}")"
        printf '%s,' "$(jstr geo_city "$(sed -n 's/.*"city":"\([^"]*\)".*/\1/p' "$MW_RUN/ports/$iface.ipinfo" 2>/dev/null)")"
        printf '%s,' "$(jstr geo_region "$(sed -n 's/.*"regionName":"\([^"]*\)".*/\1/p' "$MW_RUN/ports/$iface.ipinfo" 2>/dev/null)")"
        printf '%s,' "$(jstr geo_country "$(sed -n 's/.*"country":"\([^"]*\)".*/\1/p' "$MW_RUN/ports/$iface.ipinfo" 2>/dev/null)")"
        printf '%s,' "$(jstr gateway_rdns "${rdns:-}")"
        printf '%s,' "$(jstr dhcp_server "${dhcpsrv:-}")"
        printf '%s'  "$(jstr note "${note:-}")"
        printf '}\n'
    } > "$out"

    # Persist to flash only on a completed test. NOR flash has limited write
    # cycles, so live polling stays in tmpfs and only real results land here.
    cp "$out" "$MW_STATE/portdata/$iface.json" 2>/dev/null
    # Record the result against the LINE (not the port) and re-order priority
    # slots by speed if that is enabled — see site.sh.
    sh /usr/lib/mwadmin/site.sh after-test "$iface" >/dev/null 2>&1

    log "port test complete: $iface down=${down:-?}Mbps up=${up:-?}Mbps lat=${lat:-?}ms isp='${isp:-unknown}'"

    lock_release "test-$iface"; trap - EXIT
    return 0
}

# Last known result, preferring live tmpfs over the persisted copy.
get_port_result() {
    local iface="$1"
    valid_iface "$iface" || { echo 'null'; return; }
    if [ -f "$MW_RUN/ports/$iface.json" ]; then
        cat "$MW_RUN/ports/$iface.json"
    elif [ -f "$MW_STATE/portdata/$iface.json" ]; then
        cat "$MW_STATE/portdata/$iface.json"
    else
        printf '{%s,%s}' "$(jstr iface "$iface")" "$(jstr status never_tested)"
    fi
}

case "$1" in
    test)    run_port_test "$2" ;;
    result)  get_port_result "$2" ;;
    link)    port_link_json "$2" ;;
    counters) iface_counters_json "$2" ;;
esac
