#!/bin/sh
# migrate-router.sh — copy data + config from one Baytaar/MultiWAN router to a
# fresh OpenWrt router, install the Baytaar software on it, and set its
# admin password.  Run from Git Bash or WSL on this PC, next to fw/:
#
#   sh ./migrate-router.sh [old-ip] [new-ip]
#   (defaults: 192.168.67.1 -> 192.168.1.1)
#
# You will be asked for each router's root password by ssh. Nothing is stored.
# NOT TESTED ON HARDWARE: read the output of each step before continuing.
set -e
OLD="${1:-192.168.67.1}"
NEW="${2:-192.168.1.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$HERE/migration-$STAMP"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
mkdir -p "$WORK"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }
[ -f "$HERE/fw/baytaar-fw.tar.gz" ] || die "fw/baytaar-fw.tar.gz missing (run build_fw.py)."

say "1/6 Identify both routers"
OLD_BOARD=$(ssh $SSHO root@"$OLD" 'cat /tmp/sysinfo/board_name') || die "cannot ssh to $OLD"
NEW_BOARD=$(ssh $SSHO root@"$NEW" 'cat /tmp/sysinfo/board_name') || die "cannot ssh to $NEW"
echo "    old $OLD: $OLD_BOARD"
echo "    new $NEW: $NEW_BOARD"

say "2/6 Full backup of the OLD router (kept in $WORK)"
ssh $SSHO root@"$OLD" 'sysupgrade -b -' > "$WORK/old-full-backup.tar.gz"
ssh $SSHO root@"$OLD" 'uci export' > "$WORK/old-uci-export.txt"

# What gets copied. Hardware-specific files (network, wireless) only move if
# both boards match: DSA port names and radio paths differ between models.
# Left out ON PURPOSE: the root password (/etc/shadow), this router's tunnel
# identity (portal_token, remote_id_ed25519, remote_known_hosts) — the new box
# must register as its own router, not as a clone of the old one.
PATHS="etc/config/mwan3 etc/config/mwadmin etc/config/dhcp etc/config/firewall etc/config/sqm etc/config/system etc/mwadmin"
if [ "$OLD_BOARD" = "$NEW_BOARD" ]; then
    PATHS="$PATHS etc/config/network etc/config/wireless"
    echo "    same board: network + wireless will be copied too"
    echo "    WARNING: the new router will take the OLD router's LAN address."
else
    echo "    different boards: network + wireless are NOT copied (saved for reference in old-uci-export.txt)"
fi

say "3/6 Pull the selected data from the OLD router"
ssh $SSHO root@"$OLD" "cd / && for p in $PATHS; do [ -e \$p ] && echo \$p; done | tar czf - \
    -T - --exclude=etc/mwadmin/portal_token --exclude=etc/mwadmin/remote_id_ed25519 \
    --exclude=etc/mwadmin/remote_known_hosts" > "$WORK/migrate-data.tar.gz"
tar tzf "$WORK/migrate-data.tar.gz" | sed 's/^/    /'

say "4/6 Install the Baytaar software on the NEW router"
scp -O -q "$HERE/fw/baytaar-fw.tar.gz" root@"$NEW":/tmp/baytaar-fw.tar.gz
VER=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$HERE/fw/version.json")
ssh $SSHO root@"$NEW" "rm -rf /tmp/bfw && mkdir /tmp/bfw && cd /tmp/bfw && tar xzf /tmp/baytaar-fw.tar.gz && sh ./apply.sh '$VER'"

say "5/6 Restore the data on the NEW router"
scp -O -q "$WORK/migrate-data.tar.gz" root@"$NEW":/tmp/migrate-data.tar.gz
ssh $SSHO root@"$NEW" 'sysupgrade -b /tmp/new-preMigrate.tar.gz 2>/dev/null; cd / && tar xzf /tmp/migrate-data.tar.gz && /etc/init.d/mwadmin restart; echo "restored (pre-migration backup: /tmp/new-preMigrate.tar.gz)"'

say "6/6 Set the admin account on the NEW router"
echo "    The Baytaar admin login is the router's root password (there is no separate user)."
echo "    Choose it now; it is typed into ssh, not into this script."
ssh -t $SSHO root@"$NEW" passwd

echo
echo "Done. Open the admin page on the NEW router and sign in as root."
echo "Backups are in $WORK. NOT TESTED ON HARDWARE."
