#!/bin/sh
# common.sh — shared helpers for the MultiWAN admin app.
# Sourced by the CGI handlers, the port detector, and the mode switcher.

MW_ROOT="/usr/lib/mwadmin"
MW_RUN="/tmp/mwadmin"            # tmpfs: live state, rewritten constantly
MW_STATE="/etc/mwadmin"          # flash: persisted results, written rarely
MW_PROFILES="$MW_STATE/profiles"

mkdir -p "$MW_RUN/ports" "$MW_RUN/locks" "$MW_STATE/portdata" "$MW_PROFILES" 2>/dev/null

# Memory profile. A router with 128 MB of memory (under ~200 MB: /tmp is then only ~60 MB) runs the same software with
# smaller RAM caches and earlier clean-up; everything else, the website connection included, is the same (docs/14).
# MW_LIM_* are the limits every RAM cache uses.
MW_MEM_KB=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)
if [ "${MW_MEM_KB:-0}" -gt 0 ] && [ "${MW_MEM_KB:-0}" -lt 200000 ]; then
    MW_LOWMEM=1
    MW_LIM_DNSLOG=2000000; MW_LIM_DNSLOG2=4000000; MW_LIM_SPOOL=1000000; MW_LIM_DET=1500; MW_LIM_MAP=2500; MW_LIM_GUARD=45
else
    MW_LOWMEM=0
    MW_LIM_DNSLOG=8000000; MW_LIM_DNSLOG2=16000000; MW_LIM_SPOOL=3000000; MW_LIM_DET=4000; MW_LIM_MAP=6000; MW_LIM_GUARD=60
fi

# ---------------------------------------------------------------------------
# JSON emission
# ---------------------------------------------------------------------------
# Escapes the characters JSON forbids in a string, plus control characters.
# Everything user- or network-derived (SSIDs, ISP names, hostnames, log lines)
# goes through this before reaching the browser.
#
# BusyBox sed takes ":a;N;$!ba;..." as one label name and reads [\x00-\x1f]
# as a range of ordinary characters, so the old one-sed version dropped
# capital letters and digits from any multi-line text. Single-line text with
# no control characters (nearly every call) keeps the one-fork fast path.
JE_NL='
'
JE_TAB=$(printf '\t')
json_escape() {
    case "$1" in
        *"$JE_NL"*|*[[:cntrl:]]*)
            printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\015' | \
                sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$JE_TAB/\\\\t/g" | \
                awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }' ;;
        *)
            printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' ;;
    esac
}

jstr() { printf '"%s":"%s"' "$1" "$(json_escape "$2")"; }

# Numbers must not be quoted, but must also never emit invalid JSON if the
# source was empty or non-numeric.
jnum() {
    local v="$2"
    case "$v" in
        ''|*[!0-9.-]*) v="null" ;;
    esac
    [ -z "$v" ] && v="null"
    printf '"%s":%s' "$1" "$v"
}

jbool() {
    case "$2" in
        1|true|yes|on) printf '"%s":true' "$1" ;;
        *)             printf '"%s":false' "$1" ;;
    esac
}

json_error() {
    printf '{"ok":false,%s}\n' "$(jstr error "$1")"
}

json_ok() {
    if [ -n "$1" ]; then
        printf '{"ok":true,%s}\n' "$1"
    else
        printf '{"ok":true}\n'
    fi
}

# ---------------------------------------------------------------------------
# UCI helpers
# ---------------------------------------------------------------------------
uget() { uci -q get "$1" 2>/dev/null; }
uget_d() { local v; v=$(uci -q get "$1" 2>/dev/null); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
# The CGI passes user input into shell contexts. Everything that will be
# interpolated is validated against a strict allowlist first — reject rather
# than sanitise, so an unexpected input fails loudly instead of being silently
# mangled into something that still executes.

valid_port() {
    case "$1" in
        wan|lan1|lan2|lan3|lan4) return 0 ;;
        *) return 1 ;;
    esac
}

valid_iface() {
    case "$1" in
        wan1|wan2|wan3|lan|guest) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    case "$ip" in
        *[!0-9.]*|"") return 1 ;;
    esac
    IFS=. read -r o1 o2 o3 o4 extra <<EOF
$ip
EOF
    [ -n "$extra" ] && return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ -z "$o" ] && return 1
        [ "$o" -gt 255 ] 2>/dev/null && return 1
    done
    return 0
}

# Hostname or IP, for ping/traceroute targets. Deliberately strict: letters,
# digits, dot, hyphen only. No spaces, no shell metacharacters, no semicolons.
valid_host() {
    case "$1" in
        ""|*[!a-zA-Z0-9.-]*) return 1 ;;
        -*) return 1 ;;
        *) [ ${#1} -le 253 ] ;;
    esac
}

valid_int() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Locking — prevents two speed tests racing on the same uplink
# ---------------------------------------------------------------------------
lock_acquire() {
    local name="$1" f="$MW_RUN/locks/$1.lock"
    if mkdir "$f" 2>/dev/null; then
        echo $$ > "$f/pid"
        return 0
    fi
    # Reap a lock whose owner died, otherwise a crashed test blocks the port
    # until reboot.
    local pid
    pid=$(cat "$f/pid" 2>/dev/null)
    if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then
        rm -rf "$f"
        mkdir "$f" 2>/dev/null && { echo $$ > "$f/pid"; return 0; }
    fi
    return 1
}

lock_release() { rm -rf "$MW_RUN/locks/$1.lock"; }

log() { logger -t mwadmin "$*"; }

# `mwan3 status` takes over a second on this CPU and nearly every page asks
# for it (often twice per request). One reading is shared by all requests
# for 5 seconds.
# Router 2 mode runs without mwan3 (one line, nothing to fail over to), so there is no real status to read.
# This writes the same text `mwan3 status` would, for the one line: online when its port has a link and an
# address. Everything that parses the status (dashboard, website, line state) then works unchanged.
mwan3_router2_text() {
    local d; d=$(uci -q get network.wan1.device)
    if [ -n "$d" ] && [ "$(cat "/sys/class/net/$d/carrier" 2>/dev/null)" = "1" ] && [ -n "$(ip -4 -o addr show dev "$d" 2>/dev/null)" ]; then
        printf 'Interface status:\n interface wan1 is online and tracking is active (Router 2: one line, not tracked)\n\nCurrent ipv4 policies:\nprio_failover:\n wan1 (100%%)\n\n'
    else
        printf 'Interface status:\n interface wan1 is offline and tracking is down (Router 2: no link or no address)\n\n'
    fi
}

mwan3_status_cached() {
    local f="$MW_RUN/mwan3.status" now then
    now=$(cut -d. -f1 /proc/uptime)
    if [ -s "$f" ]; then
        then=$(head -n1 "$f")
        case "$then" in ''|*[!0-9]*) then=0 ;; esac
        if [ $((now - then)) -ge 0 ] && [ $((now - then)) -lt 5 ]; then sed 1d "$f"; return; fi
    fi
    { echo "$now"; if [ "$(cat /etc/mwadmin/mode 2>/dev/null)" = "router2" ]; then mwan3_router2_text; else mwan3 status 2>/dev/null; fi; } > "$f.$$" && mv "$f.$$" "$f"
    sed 1d "$f"
}
