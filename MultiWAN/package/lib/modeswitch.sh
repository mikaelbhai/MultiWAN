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
# Written by the rollback timer itself, as its first act. This is what proves
# the timer is genuinely running — see arm_rollback for why $! cannot.
TIMER_FILE="$MW_RUN/mode-timer"

CONFIGS="network firewall dhcp wireless mwan3 system"

# Dry run ("preview"): MW_DRY=1 MW_UCI_DIR=<copy of /etc/config> edits only that copy, starts and stops
# nothing and writes no mode file, so a mode change can be inspected without touching the running router.
uci() { command uci ${MW_UCI_DIR:+-c "$MW_UCI_DIR"} "$@"; }
svc() { [ -n "$MW_DRY" ] || "$@"; }

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
    svc /etc/init.d/mwan3 stop 2>/dev/null
    svc /etc/init.d/mwan3 disable 2>/dev/null
    svc /etc/init.d/firewall stop 2>/dev/null
    svc /etc/init.d/firewall disable 2>/dev/null

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
    [ -n "$MW_DRY" ] || echo ap > "$MODE_FILE"
}

# --- Apply Router 2 (DHCP on) -------------------------------------------------
# A second router behind Router 1: ONE uplink (the former WAN1 port, an ordinary DHCP client on Router 1's
# network), its own LAN with its own address range and DHCP server, NAT and firewall on, Wi-Fi unchanged.
# No multi-WAN (mwan3 off). Built from the saved main-router configuration, so going back is the same
# profile restore as before. With DHCP OFF the Router 2 role is the bridged mode above (apply_ap_mode).
apply_router2_mode() {
    local lan_ip="${1:-192.168.2.1}" lan_mask="${2:-255.255.255.0}" bridge_all="${3:-1}"
    log "applying Router 2 mode (lan=$lan_ip/$lan_mask bridge_all=$bridge_all)"

    # Ports of the two spare lines join the LAN (when asked): they are not uplinks here.
    local p2 p3 p have
    p2=$(uci -q get network.wan2.device); p3=$(uci -q get network.wan3.device)
    if [ "$bridge_all" = "1" ]; then
        have=" $(uci -q get network.br_lan.ports) "
        for p in $p2 $p3; do
            case "$have" in *" $p "*) continue ;; esac
            [ -e "/sys/class/net/$p" ] && uci add_list network.br_lan.ports="$p"
        done
    fi
    uci -q delete network.wan2
    uci -q delete network.wan3

    # the one uplink: a plain DHCP client on Router 1's network
    uci set network.wan1.proto='dhcp'
    uci -q delete network.wan1.ipaddr
    uci -q delete network.wan1.netmask
    uci -q delete network.wan1.gateway
    uci -q delete network.wan1.dns
    uci -q delete network.wan1.pppd_options

    # its own network (must differ from Router 1's)
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask="$lan_mask"
    if uci -q get network.lan_admin >/dev/null; then
        uci set network.lan_admin.ipaddr="${lan_ip%.*}.254"
    fi
    # the block-page address, the name that points at it, and the panel's host name must follow the new network
    # (found on the first real switch: they stayed on the old 192.168.1.x, unreachable from the new LAN)
    if uci -q get network.lan_block >/dev/null; then
        uci set network.lan_block.ipaddr="${lan_ip%.*}.253"
        local a
        for a in $(uci -q get dhcp.@dnsmasq[0].address); do
            case "$a" in /sites.router/*) uci -q del_list dhcp.@dnsmasq[0].address="$a" ;; esac
        done
        uci add_list dhcp.@dnsmasq[0].address="/sites.router/${lan_ip%.*}.253"
    fi
    if uci -q get dhcp.mwadmin_alias.ip >/dev/null; then
        uci set dhcp.mwadmin_alias.ip="${lan_ip%.*}.254"
    fi

    # DHCP server stays ON for the LAN (the default); make sure it is not switched off
    uci -q delete dhcp.lan.ignore
    uci -q delete dhcp.@dnsmasq[0].port

    # one line: nothing for the multi-WAN tracker to do (and no false "line down" alerts for lines that do not exist)
    svc /etc/init.d/mwan3 stop 2>/dev/null
    svc /etc/init.d/mwan3 disable 2>/dev/null
    svc /etc/init.d/firewall enable 2>/dev/null

    uci commit
    [ -n "$MW_DRY" ] || echo router2 > "$MODE_FILE"
}

# --- Apply Router mode --------------------------------------------------------
# --- Apply mode 3 (node) ----------------------------------------------------------------------------------------------------
# Replaces "Router 2 with DHCP off": bridged like the access point mode above (no DHCP, no routing), plus the uplink
# chosen for this node and Router 2's Wi-Fi name and password with fast roaming. See lib/node.sh and docs/14.
# Reads NODE_UPLINK (cable|mesh|repeater), NODE_SSID, NODE_KEY, NODE_MESH_ID, NODE_MESH_KEY, NODE_CHANNEL,
# NODE_REP_BAND, NODE_REP_SSID, NODE_REP_KEY, NODE_REP_ENC.
apply_node_mode() {
    . /usr/lib/mwadmin/node.sh
    apply_ap_mode 1 dhcp
    uci -q delete wireless.mwmesh; uci -q delete wireless.mwsta; uci -q delete network.wwan; uci -q delete network.mwrelay
    case "$NODE_UPLINK" in
        cable)    node_wifi_align "$NODE_SSID" "$NODE_KEY" ;;
        mesh)     node_wifi_align "$NODE_SSID" "$NODE_KEY"
                  node_mesh_iface "$NODE_MESH_ID" "$NODE_MESH_KEY" "$NODE_CHANNEL" || return 1 ;;
        repeater) node_repeater "$NODE_REP_BAND" "$NODE_REP_SSID" "$NODE_REP_KEY" "$NODE_REP_ENC" "$NODE_SSID" "$NODE_KEY" || return 1 ;;
        *) return 1 ;;
    esac
    uci set mwadmin.node='node'; uci set mwadmin.node.uplink="$NODE_UPLINK"
    uci commit
    [ -n "$MW_DRY" ] || echo node > "$MODE_FILE"
    log "mode 3 (node, $NODE_UPLINK) applied"
}

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
    rm -f "$CONFIRM_FILE" "$TIMER_FILE"
    date +%s > "$PENDING_FILE"
    echo "$restore_to" >> "$PENDING_FILE"

    # setsid detaches from the CGI process group, so the timer survives uhttpd
    # reaping the request handler — which it will, because the network is about
    # to go down underneath this very connection.
    #
    # Run through `sh` explicitly. Everything in /usr/lib/mwadmin is deployed
    # mode 644 — correctly, these are sourced libraries, not programs — so
    # exec'ing this path directly fails with EACCES. It did exactly that,
    # silently, for the entire life of this install: stderr went to /dev/null
    # and the "armed" line below logged unconditionally straight afterwards,
    # so every AP-mode switch and every LAN address change reported a
    # 90-second safety net that did not exist. Confirmed on the device, not
    # theorised: mode 644, zero timer processes, a mode-pending file stale by
    # 20 minutes, and a half-applied LAN change that was never reverted.
    setsid sh /usr/lib/mwadmin/modeswitch.sh _rollback_timer "$restore_to" \
        >/dev/null 2>&1 < /dev/null &

    # Verify the timer came up instead of assuming it did. $! is no use here:
    # busybox setsid forks when it is already a process group leader, so the
    # pid it hands back can belong to a process that has already exited while
    # the real timer runs on under another. The timer writing its own pid is
    # the only signal that distinguishes "running" from "never started".
    local waited=0
    while [ "$waited" -lt 5 ]; do
        if [ -f "$TIMER_FILE" ]; then
            log "rollback armed: reverting to '$restore_to' in ${ROLLBACK_SECONDS}s unless confirmed"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Nothing is protecting this change. Clear the pending flag before
    # returning: left set, with no timer alive to ever clear it, it blocks
    # every subsequent change through api_lan_set's rollback-pending guard —
    # which is precisely the state this device was found in.
    rm -f "$PENDING_FILE"
    log "ROLLBACK FAILED TO ARM: timer did not start. This change is NOT protected by an automatic revert."
    return 1
}

_rollback_timer() {
    local restore_to="$1"
    # First act, before any waiting: this file is arm_rollback's only proof
    # that the timer actually started.
    echo $$ > "$TIMER_FILE"
    local waited=0
    while [ $waited -lt $ROLLBACK_SECONDS ]; do
        if [ -f "$CONFIRM_FILE" ]; then
            log "mode switch confirmed by user; rollback cancelled"
            rm -f "$PENDING_FILE" "$TIMER_FILE"
            exit 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log "NO CONFIRMATION AFTER ${ROLLBACK_SECONDS}s — rolling back to '$restore_to'"
    profile_restore "$restore_to"
    # Only AP/Router are real modes. Other checkpoint names (e.g. "lan-rollback",
    # used for a plain LAN IP/netmask revert) restore config files without
    # representing a mode of their own, so MODE_FILE is left untouched.
    case "$restore_to" in
        router|ap|router2|node) echo "$restore_to" > "$MODE_FILE" ;;
    esac
    rm -f "$PENDING_FILE" "$TIMER_FILE"
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

    # Never claim a safety net that did not arm. The UI counts down from
    # rollback_seconds and tells the user they are protected; reporting 90
    # when no timer exists is worse than reporting the failure, because it
    # is the exact situation where the user needs to know to stay reachable.
    local secs="$ROLLBACK_SECONDS" msg
    if arm_rollback router; then
        msg='AP mode applied. Reconnect and confirm within 90 seconds or the device reverts to Router mode automatically.'
    else
        secs=0
        msg='AP mode applied, but the automatic revert timer FAILED TO START — nothing will undo this if you cannot reconnect. Recover with failsafe mode, or restore the saved "router" profile over SSH.'
    fi

    json_ok "$(printf '%s,%s,%s' \
        "$(jstr mode ap)" \
        "$(jnum rollback_seconds "$secs")" \
        "$(jstr message "$msg")")"

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

    # Same honesty requirement as switch_to_ap above.
    local secs="$ROLLBACK_SECONDS" msg
    if arm_rollback ap; then
        msg='Router mode restored with your multi-WAN configuration. Reconnect and confirm within 90 seconds.'
    else
        secs=0
        msg='Router mode restored, but the automatic revert timer FAILED TO START — nothing will undo this if you cannot reconnect. Recover with failsafe mode, or restore the saved "ap" profile over SSH.'
    fi

    json_ok "$(printf '%s,%s,%s' \
        "$(jstr mode router)" \
        "$(jnum rollback_seconds "$secs")" \
        "$(jstr message "$msg")")"

    ( sleep 2; /etc/init.d/network restart; /etc/init.d/firewall restart; \
      /etc/init.d/mwan3 restart; wifi reload ) >/dev/null 2>&1 &
}

# Router 2 role: dhcp=1 -> its own network (routed), dhcp=0 -> joins Router 1's network (bridged, the old
# access point mode). Works from the main router and between the two Router 2 variants.
switch_to_role2() {
    local dhcp="${1:-1}" lan_ip="$2" lan_mask="$3" bridge_all="${4:-1}" proto="${5:-dhcp}" ip="$6" mask="$7" gw="$8"
    local cur target
    cur=$(current_mode)
    [ "$dhcp" = "0" ] && target=ap || target=router2
    [ "$cur" = "$target" ] && { json_error "Already in that mode."; return 1; }
    if [ "$target" = "router2" ]; then
        valid_ipv4 "${lan_ip:-192.168.2.1}" && valid_ipv4 "${lan_mask:-255.255.255.0}" || { json_error "Enter a valid address and netmask for Router 2's network."; return 1; }
        # Router 2's network must not be the one it is plugged into: refuse the obvious clash
        local up; up=$(ip route show default 2>/dev/null | sed -n 's/.* via \([0-9.]*\) .*/\1/p' | head -n1)
        [ -n "$up" ] && [ "${up%.*}" = "${lan_ip%.*}" ] && { json_error "That is the same network as the one Router 2 is plugged into. Pick a different address, e.g. 192.168.3.1."; return 1; }
    fi

    if [ "$cur" = "router" ]; then
        profile_save router                       # what rollback and "back to main router" restore
    else
        profile_exists router || { json_error "No saved main-router profile exists."; return 1; }
        profile_save "$cur"                       # so a failed change returns to exactly what runs now
        profile_restore router                    # build the new variant from the main configuration
    fi

    if [ "$target" = "ap" ]; then
        apply_ap_mode "$bridge_all" "$proto" "$ip" "$mask" "$gw"
    else
        apply_router2_mode "${lan_ip:-192.168.2.1}" "${lan_mask:-255.255.255.0}" "$bridge_all"
    fi

    local secs="$ROLLBACK_SECONDS" msg
    if arm_rollback "$cur"; then
        msg="Router 2 applied. Reconnect and confirm within 90 seconds or the device returns to how it was."
    else
        secs=0
        msg="Router 2 applied, but the automatic revert timer FAILED TO START: nothing will undo this if you cannot reconnect. Recover with failsafe mode, or restore the saved profile over SSH."
    fi
    json_ok "$(printf '%s,%s,%s' "$(jstr mode "$target")" "$(jnum rollback_seconds "$secs")" "$(jstr message "$msg")")"
    ( sleep 2; /etc/init.d/network restart; /etc/init.d/firewall restart; wifi reload ) >/dev/null 2>&1 &
}

# Mode 3: <request file> holds NODE_* values (single-quoted, written by api.sh). Same safety as the other modes:
# snapshot, build from the main-router profile, apply, 90 s rollback unless confirmed.
node_load() {
    [ -f "$1" ] || { json_error "No node settings were given."; return 1; }
    . "$1"
    case "$NODE_UPLINK" in cable|mesh|repeater) ;; *) json_error "Choose how this node connects: cable, mesh or repeater."; return 1 ;; esac
    if [ "$NODE_UPLINK" = "repeater" ]; then
        [ -n "$NODE_REP_SSID" ] || { json_error "Choose or type the Wi-Fi to repeat."; return 1; }
        [ "$NODE_REP_ENC" = "none" ] || [ ${#NODE_REP_KEY} -ge 8 ] || { json_error "Enter that Wi-Fi's password (8 characters or more)."; return 1; }
    else
        [ -n "$NODE_SSID" ] || { json_error "Enter Router 2's Wi-Fi name: nodes use the same one."; return 1; }
        [ ${#NODE_KEY} -ge 8 ] || { json_error "Enter Router 2's Wi-Fi password (8 characters or more)."; return 1; }
    fi
    if [ "$NODE_UPLINK" = "mesh" ]; then
        [ -n "$NODE_MESH_ID" ] && [ ${#NODE_MESH_KEY} -ge 8 ] || { json_error "Enter the mesh name and mesh password shown on Router 2 (Wi-Fi, Mesh for nodes)."; return 1; }
        case "$NODE_CHANNEL" in ''|*[!0-9]*) NODE_CHANNEL=36 ;; esac
    fi
    return 0
}

switch_to_node() {         # <request file>
    node_load "$1" || return 1
    . /usr/lib/mwadmin/node.sh
    local cur; cur=$(current_mode)
    # the extra Wi-Fi software is fetched NOW, while this router still has its current connection
    if [ "$NODE_UPLINK" = "mesh" ]; then node_pkg mesh || { json_error "Could not install the Wi-Fi mesh software. Connect this router to the internet and try again."; return 1; }; fi
    if [ "$NODE_UPLINK" = "repeater" ]; then node_pkg relay || { json_error "Could not install the repeater software (relayd). Connect this router to the internet and try again."; return 1; }; fi
    if [ "$cur" = "router" ]; then profile_save router
    else
        profile_exists router || { json_error "No saved main-router profile exists."; return 1; }
        profile_save "$cur"; profile_restore router
    fi
    apply_node_mode || { profile_restore "$cur"; json_error "Mode 3 could not be applied; nothing was changed."; return 1; }
    rm -f "$1"
    local secs="$ROLLBACK_SECONDS" msg
    if arm_rollback "$cur"; then
        case "$NODE_UPLINK" in
            repeater) msg="Mode 3 (repeater) applied. It now joins that Wi-Fi; connect to this router's Wi-Fi and confirm within 90 seconds, or it returns to how it was." ;;
            mesh)     msg="Mode 3 (mesh node) applied. Confirm within 90 seconds from Router 2's network, or it returns to how it was." ;;
            *)        msg="Mode 3 (cable node) applied. Plug it into Router 2 and confirm within 90 seconds, or it returns to how it was." ;;
        esac
    else
        secs=0; msg="Mode 3 applied, but the automatic revert timer FAILED TO START. Recover with failsafe mode if you cannot reconnect."
    fi
    json_ok "$(printf '%s,%s,%s' "$(jstr mode node)" "$(jnum rollback_seconds "$secs")" "$(jstr message "$msg")")"
    ( sleep 2; /etc/init.d/network restart; wifi reload ) >/dev/null 2>&1 &
}

preview_node() {           # <request file>: the result on a COPY of the settings
    node_load "$1" >/dev/null || { cat "$1" >/dev/null 2>&1; echo "invalid settings"; return 1; }
    local d=/tmp/mw-preview.$$
    rm -rf "$d"; mkdir -p "$d"
    for c in $CONFIGS mwadmin; do [ -f "/etc/config/$c" ] && cp "/etc/config/$c" "$d/$c"; done
    ( export MW_DRY=1 MW_UCI_DIR="$d"; apply_node_mode ) >/dev/null 2>&1
    echo "--- network"; uci -c "$d" show network | grep -E "^network\.(wan[123]|wwan|mwrelay|lan|br_lan)(\.|=)"
    echo "--- dhcp";    uci -c "$d" show dhcp | grep -E "dhcp\.lan\.ignore|dnsmasq\[0\]\.port"
    echo "--- wireless"; uci -c "$d" show wireless | grep -E "\.(ssid|mode|network|ieee80211r|mobility_domain|mesh_id|encryption|channel|device)=" | grep -v "\.key="
    rm -rf "$d"
}

# What a Router 2 change would do, on a COPY of the settings: prints the resulting network and DHCP lines.
# Nothing running is touched. Usage: modeswitch.sh preview <dhcp 0|1> [lan_ip] [lan_mask]
preview_role2() {
    local dhcp="${1:-1}" d=/tmp/mw-preview.$$
    rm -rf "$d"; mkdir -p "$d"
    for c in $CONFIGS; do [ -f "/etc/config/$c" ] && cp "/etc/config/$c" "$d/$c"; done
    ( export MW_DRY=1 MW_UCI_DIR="$d"
      if [ "$dhcp" = "0" ]; then apply_ap_mode 1 dhcp; else apply_router2_mode "${2:-192.168.2.1}" "${3:-255.255.255.0}" 1; fi ) >/dev/null 2>&1
    echo "--- network"; uci -c "$d" show network | grep -E "^network\.(wan[123]|lan|lan_admin|br_lan)(\.|=)"
    echo "--- dhcp";    uci -c "$d" show dhcp | grep -E "dhcp\.lan\.|dnsmasq\[0\]\.port|guest"
    rm -rf "$d"
}

case "$1" in
    mode)            printf '{%s}' "$(jstr mode "$(current_mode)")" ;;
    to-ap)           switch_to_ap "$2" "$3" "$4" "$5" "$6" ;;
    to-router)       switch_to_router ;;
    to-router2)      switch_to_role2 "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" ;;
    preview)         preview_role2 "$2" "$3" "$4" ;;
    to-node)         switch_to_node "$2" ;;
    preview-node)    preview_node "$2" ;;
    confirm)         confirm_switch ;;
    rollback-status) rollback_status ;;
    save-profile)    profile_save "$2" ;;
    # Generic checkpoint+rollback, used outside the AP/Router flow too (e.g.
    # a LAN IP change from api.sh) — anything that risks locking the browser
    # out gets the same "snapshot, apply, arm a timer, wait for confirm" net.
    rollback-pending) [ -f "$PENDING_FILE" ] && echo 1 || echo 0 ;;
    arm)             arm_rollback "$2" ;;
    _rollback_timer) _rollback_timer "$2" ;;
    *)               json_error "unknown modeswitch command" ;;
esac
