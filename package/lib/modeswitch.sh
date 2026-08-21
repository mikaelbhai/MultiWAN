#!/bin/sh
# modeswitch.sh — switch the device between Router mode and Access Point mode.
#
# ===========================================================================
# THE LOCKOUT PROBLEM, AND HOW THIS SOLVES IT
# ===========================================================================
#
# Switching to AP mode tears down DHCP, the firewall, and routing, and moves
# the device onto a different subnet supplied by the upstream router. If
# anything about that goes wrong — the upstream has no DHCP server, the cable
# is in the wrong port, the subnet collides — the device becomes unreachable
# and the only recovery is a physical failsafe-mode reset.
#
# So this never applies a mode switch permanently in one step. It:
#
#   1. Snapshots the current config to a named profile on flash.
#   2. Applies the new mode.
#   3. Arms a detached rollback timer.
#   4. Waits for the browser to call `confirm` after it successfully reconnects.
#   5. If no confirmation arrives before the deadline, restores the snapshot
#      and reboots back to a known-good state.
#
# This is the same pattern LuCI uses for network changes, and it is the single
# most important safety feature in this application. The user cannot brick
# their access by clicking the wrong button.
# ===========================================================================

. /usr/lib/mwadmin/common.sh

ROLLBACK_SECONDS=90
MODE_FILE="$MW_STATE/mode"
PENDING_FILE="$MW_RUN/mode-pending"
CONFIRM_FILE="$MW_RUN/mode-confirm"

CONFIGS="network firewall dhcp wireless mwan3 system"

current_mode() {
    if [ -f "$MODE_FILE" ]; then
        cat "$MODE_FILE"
    else
        echo router
    fi
}

# --- Profile save / restore ---------------------------------------------------
profile_save() {
    local name="$1"
    local dir="$MW_PROFILES/$name"
    mkdir -p "$dir"
    for c in $CONFIGS; do
        [ -f "/etc/config/$c" ] && cp "/etc/config/$c" "$dir/$c"
    done
    date +%s > "$dir/.saved_at"
    log "profile saved: $name"
}

profile_restore() {
    local name="$1"
    local dir="$MW_PROFILES/$name"
    [ -d "$dir" ] || { log "profile_restore: no profile '$name'"; return 1; }
    for c in $CONFIGS; do
        [ -f "$dir/$c" ] && cp "$dir/$c" "/etc/config/$c"
    done
    log "profile restored: $name"
}

profile_exists() { [ -d "$MW_PROFILES/$1" ]; }

# --- Apply Access Point mode --------------------------------------------------
apply_ap_mode() {
    # bridge_all=1 pulls the former WAN ports into the bridge too, so all five
    # ports become LAN. bridge_all=0 leaves them out, which is what you want if
    # you plan to switch back to Router mode often.
    local bridge_all="${1:-1}"
    local ap_proto="${2:-dhcp}"       # dhcp | static
    local ap_ip="${3:-192.168.1.2}"
    local ap_mask="${4:-255.255.255.0}"
    local ap_gw="${5:-192.168.1.1}"

    log "applying AP mode (bridge_all=$bridge_all proto=$ap_proto)"

    # --- Every port into one bridge ------------------------------------------
    uci -q delete network.br_lan.ports
    if [ "$bridge_all" = "1" ]; then
        for p in wan lan1 lan2 lan3 lan4; do
            [ -e "/sys/class/net/$p" ] && uci add_list network.br_lan.ports="$p"
        done
    else
        for p in lan3 lan4; do
            [ -e "/sys/class/net/$p" ] && uci add_list network.br_lan.ports="$p"
        done
    fi

    # --- Remove the WAN interfaces entirely ----------------------------------
    # An AP does not route. Leaving these defined would keep mwan3's trackers
    # and the NAT rules alive with nothing to act on.
    uci -q delete network.wan1
    uci -q delete network.wan2
    uci -q delete network.wan3
    uci -q delete network.guest
    uci -q delete network.br_guest

    # --- LAN becomes a client of the upstream router -------------------------
    uci set network.lan.device='br-lan'
    if [ "$ap_proto" = "static" ]; then
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr="$ap_ip"
        uci set network.lan.netmask="$ap_mask"
        uci set network.lan.gateway="$ap_gw"
        uci -q delete network.lan.dns
        uci add_list network.lan.dns="$ap_gw"
    else
        # DHCP client. The upstream router assigns the address, so the device
        # simply appears on the existing LAN as another host.
        uci set network.lan.proto='dhcp'
        uci -q delete network.lan.ipaddr
        uci -q delete network.lan.netmask
        uci -q delete network.lan.gateway
    fi

    # --- DHCP server OFF -----------------------------------------------------
    # Two DHCP servers on one broadcast domain is the classic way to break a
    # network subtly: clients get leases from whichever answers first, half of
    # them get the wrong gateway, and it looks like random connectivity loss.
    uci set dhcp.lan.ignore='1'
    uci -q delete dhcp.guest
    # Stop answering DNS too; the upstream router handles it.
    uci set dhcp.@dnsmasq[0].port='0'

    # --- Routing and firewall OFF --------------------------------------------
    /etc/init.d/mwan3 stop 2>/dev/null
    /etc/init.d/mwan3 disable 2>/dev/null
    /etc/init.d/firewall stop 2>/dev/null
    /etc/init.d/firewall disable 2>/dev/null

    # --- Wireless stays an AP, now bridged to the upstream LAN ---------------
    # This is the wireless half of AP mode: the radios keep broadcasting, but
    # clients that associate land directly on the upstream subnet and get their
    # addresses from the upstream DHCP server.
    for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([a-z0-9_]*\)=wifi-iface$/\1/p"); do
        case "$s" in
            *guest*) uci -q delete wireless.$s ;;   # no isolated guest net without a firewall
            *)       uci set wireless.$s.network='lan' ;;
        esac
    done

    uci commit
    echo ap > "$MODE_FILE"
}

# --- Apply Router mode --------------------------------------------------------
apply_router_mode() {
    log "restoring Router mode from saved profile"
    profile_restore router || return 1

    /etc/init.d/firewall enable 2>/dev/null
    /etc/init.d/mwan3 enable 2>/dev/null

    echo router > "$MODE_FILE"
}

# --- Rollback machinery -------------------------------------------------------
arm_rollback() {
    local restore_to="$1"
    rm -f "$CONFIRM_FILE"
    date +%s > "$PENDING_FILE"
    echo "$restore_to" >> "$PENDING_FILE"

    # setsid detaches from the CGI process group, so the timer survives uhttpd
    # reaping the request handler — which it will, because the network is about
    # to go down underneath this very connection.
    setsid /usr/lib/mwadmin/modeswitch.sh _rollback_timer "$restore_to" \
        >/dev/null 2>&1 < /dev/null &
    log "rollback armed: reverting to '$restore_to' in ${ROLLBACK_SECONDS}s unless confirmed"
}

_rollback_timer() {
    local restore_to="$1"
    local waited=0
    while [ $waited -lt $ROLLBACK_SECONDS ]; do
        if [ -f "$CONFIRM_FILE" ]; then
            log "mode switch confirmed by user; rollback cancelled"
            rm -f "$PENDING_FILE"
            exit 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log "NO CONFIRMATION AFTER ${ROLLBACK_SECONDS}s — rolling back to '$restore_to'"
    profile_restore "$restore_to"
    echo "$restore_to" > "$MODE_FILE"
    rm -f "$PENDING_FILE"
    # Reboot rather than reload: the failed mode left services in an unknown
    # state, and a clean boot from a known-good config is the only reliable
    # way back.
    sync
    reboot
}

confirm_switch() {
    if [ ! -f "$PENDING_FILE" ]; then
        json_error "No mode switch is pending confirmation."
        return 1
    fi
    touch "$CONFIRM_FILE"
    json_ok "$(jstr message 'Mode switch confirmed. Rollback cancelled.')"
}

rollback_status() {
    if [ -f "$PENDING_FILE" ]; then
        local started; started=$(head -n1 "$PENDING_FILE")
        local target;  target=$(sed -n 2p "$PENDING_FILE")
        local elapsed=$(( $(date +%s) - started ))
        local remain=$(( ROLLBACK_SECONDS - elapsed ))
        [ $remain -lt 0 ] && remain=0
        printf '{%s,%s,%s}' \
            "$(jbool pending 1)" \
            "$(jnum seconds_remaining "$remain")" \
            "$(jstr revert_to "$target")"
    else
        printf '{%s}' "$(jbool pending 0)"
    fi
}

# --- Entry points -------------------------------------------------------------
switch_to_ap() {
    local bridge_all="${1:-1}" proto="${2:-dhcp}" ip="$3" mask="$4" gw="$5"

    [ "$(current_mode)" = "ap" ] && { json_error "Already in Access Point mode."; return 1; }

    # Snapshot the working router config BEFORE changing anything. This is what
    # gets restored on rollback, and what "switch back to Router mode" replays,
    # so the multi-WAN setup returns without reconfiguring from scratch.
    profile_save router

    apply_ap_mode "$bridge_all" "$proto" "$ip" "$mask" "$gw"
    arm_rollback router

    json_ok "$(printf '%s,%s,%s' \
        "$(jstr mode ap)" \
        "$(jnum rollback_seconds "$ROLLBACK_SECONDS")" \
        "$(jstr message 'AP mode applied. Reconnect and confirm within 90 seconds or the device reverts to Router mode automatically.')")"

    # Apply after responding, so the browser actually receives the JSON before
    # the network drops out from under the connection.
    ( sleep 2; /etc/init.d/network restart; wifi reload ) >/dev/null 2>&1 &
}

switch_to_router() {
    [ "$(current_mode)" = "router" ] && { json_error "Already in Router mode."; return 1; }

    if ! profile_exists router; then
        json_error "No saved Router-mode profile exists. Re-run config/install.sh to rebuild it."
        return 1
    fi

    profile_save ap
    apply_router_mode || { json_error "Failed to restore the Router profile."; return 1; }
    arm_rollback ap

    json_ok "$(printf '%s,%s,%s' \
        "$(jstr mode router)" \
        "$(jnum rollback_seconds "$ROLLBACK_SECONDS")" \
        "$(jstr message 'Router mode restored with your multi-WAN configuration. Reconnect and confirm within 90 seconds.')")"

    ( sleep 2; /etc/init.d/network restart; /etc/init.d/firewall restart; \
      /etc/init.d/mwan3 restart; wifi reload ) >/dev/null 2>&1 &
}

case "$1" in
    mode)            printf '{%s}' "$(jstr mode "$(current_mode)")" ;;
    to-ap)           switch_to_ap "$2" "$3" "$4" "$5" "$6" ;;
    to-router)       switch_to_router ;;
    confirm)         confirm_switch ;;
    rollback-status) rollback_status ;;
    save-profile)    profile_save "$2" ;;
    _rollback_timer) _rollback_timer "$2" ;;
    *)               json_error "unknown modeswitch command" ;;
esac
