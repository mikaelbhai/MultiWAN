#!/bin/sh
# common.sh — shared helpers for the MultiWAN admin app.
# Sourced by the CGI handlers, the port detector, and the mode switcher.

MW_ROOT="/usr/lib/mwadmin"
MW_RUN="/tmp/mwadmin"            # tmpfs: live state, rewritten constantly
MW_STATE="/etc/mwadmin"          # flash: persisted results, written rarely
MW_PROFILES="$MW_STATE/profiles"

mkdir -p "$MW_RUN/ports" "$MW_RUN/locks" "$MW_STATE/portdata" "$MW_PROFILES" 2>/dev/null

# ---------------------------------------------------------------------------
# JSON emission
# ---------------------------------------------------------------------------
# Escapes the characters JSON forbids in a string, plus control characters.
# Everything user- or network-derived (SSIDs, ISP names, hostnames, log lines)
# goes through this before reaching the browser.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/"/\\"/g' \
                           -e 's/\t/\\t/g' \
                           -e 's/\r/\\r/g' \
                           -e ':a;N;$!ba;s/\n/\\n/g' \
                           -e 's/[\x00-\x1f]//g'
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
