#!/bin/sh
# deploy.sh — push the MultiWAN config and admin app to the router over SSH.
# POSIX equivalent of deploy.ps1, for Linux/macOS/WSL/Git Bash.
#
# Usage:  ./deploy/deploy.sh [router-ip] [--config-only|--app-only]

set -e

ROUTER="${1:-192.168.20.1}"
case "$ROUTER" in --*) ROUTER="192.168.20.1" ;; esac
MODE="${2:-all}"
case "$1" in --*) MODE="$1" ;; esac

USER_="root"
TARGET="$USER_@$ROUTER"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

say "Verifying this is the expected device"
board=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$TARGET" \
        "cat /tmp/sysinfo/board_name 2>/dev/null") || die "SSH to $TARGET failed."
echo "    board: $board"
if [ "$board" != "tplink,archer-c6-v3" ]; then
    warn "Expected 'tplink,archer-c6-v3', found '$board'."
    printf "Continue anyway? [y/N] "; read -r a
    case "$a" in y|Y) ;; *) die "Aborted." ;; esac
fi

if [ "$MODE" != "--app-only" ]; then
    grep -q '203\.0\.113\.' "$REPO/config/mwan.env" && \
        die "config/mwan.env still has the placeholder WAN1 address. Set your real static IP first."
    grep -q 'CHANGEME' "$REPO/config/mwan.env" && \
        warn "mwan.env still contains a CHANGEME placeholder."

    say "Copying config scripts"
    ssh "$TARGET" "mkdir -p /root/multiwan/config"
    scp -O -q "$REPO"/config/* "$TARGET:/root/multiwan/config/"
    ssh "$TARGET" "chmod +x /root/multiwan/config/*.sh; sed -i 's/\r\$//' /root/multiwan/config/*"
    printf '\033[32m    Run on the router: ssh %s "cd /root/multiwan/config && sh install.sh"\033[0m\n' "$TARGET"
fi

if [ "$MODE" != "--config-only" ]; then
    say "Deploying the admin application"
    ssh "$TARGET" "mkdir -p /www/mwadmin/cgi-bin /usr/lib/mwadmin /etc/hotplug.d/iface"

    scp -O -q -r "$REPO"/package/www/*                        "$TARGET:/www/mwadmin/"
    scp -O -q    "$REPO"/package/cgi-bin/mwadmin              "$TARGET:/www/mwadmin/cgi-bin/"
    scp -O -q    "$REPO"/package/lib/*.sh                     "$TARGET:/usr/lib/mwadmin/"
    scp -O -q    "$REPO"/package/hotplug/95-mwadmin-portdetect "$TARGET:/etc/hotplug.d/iface/"
    scp -O -q    "$REPO"/package/init.d/mwadmin               "$TARGET:/etc/init.d/"
    scp -O -q    "$REPO"/package/init.d/mwremote              "$TARGET:/etc/init.d/"
    scp -O -q    "$REPO"/package/etc/mwan3.user                "$TARGET:/etc/"

    # Records what was just deployed, so the Updates page's "current version"
    # always matches this working tree, not whatever was last pushed to GitHub.
    ssh "$TARGET" "mkdir -p /etc/mwadmin"
    scp -O -q "$REPO/VERSION" "$TARGET:/etc/mwadmin/version"

    ssh "$TARGET" '
set -e
for f in /www/mwadmin/cgi-bin/mwadmin /usr/lib/mwadmin/*.sh \
         /etc/hotplug.d/iface/95-mwadmin-portdetect /etc/init.d/mwadmin /etc/init.d/mwremote /etc/mwan3.user; do
    [ -f "$f" ] && sed -i "s/\r$//" "$f"
done
chmod 755 /www/mwadmin/cgi-bin/mwadmin /etc/init.d/mwadmin /etc/init.d/mwremote /etc/hotplug.d/iface/95-mwadmin-portdetect /etc/mwan3.user
chmod 644 /usr/lib/mwadmin/*.sh /www/mwadmin/*.html /www/mwadmin/*.css /www/mwadmin/*.js
/etc/init.d/mwadmin enable
/etc/init.d/mwadmin restart
# mwremote is intentionally NOT enabled here — it stays off until the admin
# app Remote Access page enables it, same opt-in posture as the WAN-exposure
# firewall rule.
'
    port=$(sed -n 's/^ADMIN_PORT="\([0-9]*\)".*/\1/p' "$REPO/config/mwan.env")
    [ -z "$port" ] && port=8080

    say "Verifying the service responds"
    # Deliberately NOT 127.0.0.1: uhttpd.mwadmin binds only to the LAN address
    # (see package/init.d/mwadmin), never loopback, so a 127.0.0.1 check here
    # always fails regardless of whether the service is actually healthy.
    if ssh "$TARGET" "wget -qO- http://$ROUTER:$port/cgi-bin/mwadmin/ping" 2>/dev/null | grep -q '"ok":true'; then
        printf '\033[32m    API responded correctly.\033[0m\n'
    else
        warn "API did not respond. Check: ssh $TARGET 'logread | grep mwadmin'"
    fi
    printf '\n\033[32mAdmin UI: http://%s:%s\033[0m\n' "$ROUTER" "$port"
fi

say "Done."
