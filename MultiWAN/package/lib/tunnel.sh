#!/bin/sh
# tunnel.sh - keeps the SSH tunnel to the website up (run by /etc/init.d/mwremote).
#
# Two things the plain ssh command could not do:
#   * Read the router's LAN address on every reconnect, so changing the LAN
#     address never leaves the tunnel pointing at the old one.
#   * Use a second pair of ports. When the router vanishes without closing
#     the connection (power cut, line drop), the server can keep the old
#     session - and its ports - for hours. Instead of failing on the same
#     port every 15 seconds, a quick failure switches to the other pair.
#     The website tries both. Pair A: remote_port / remote_port+1,
#     pair B: remote_port+2 / remote_port+3 (panel / SSH).

# Dropbear's own client (dbclient), not OpenSSH: it is part of every OpenWrt
# install, and dropping openssh-client + OpenSSL frees ~2 MB of flash.
# Its key is the same ed25519 key in Dropbear's file format.
KEYFILE=/etc/mwadmin/remote_id_dropbear
# services start with HOME=/; dbclient keeps the pinned server keys in ~/.ssh
export HOME=/root
STATE=/tmp/mwremote.pair

host=$(uci -q get mwadmin.remote.host)
user=$(uci -q get mwadmin.remote.user)
ssh_port=$(uci -q get mwadmin.remote.ssh_port); [ -z "$ssh_port" ] && ssh_port=22
base=$(uci -q get mwadmin.remote.remote_port)
local_port=$(uci -q get mwadmin.@main[0].port); [ -z "$local_port" ] && local_port=8080
want_ssh=$(uci -q get mwadmin.remote.ssh_remote_port)
[ -n "$host" ] && [ -n "$user" ] && [ -n "$base" ] || { logger -t mwremote "relay not configured"; sleep 60; exit 1; }
[ -f "$KEYFILE" ] || { logger -t mwremote "no key at $KEYFILE"; sleep 60; exit 1; }
# the server's key, pinned when the tunnel was first set up (dbclient reads
# only ~/.ssh/known_hosts)
mkdir -p /root/.ssh; touch /root/.ssh/known_hosts
if [ -s /etc/mwadmin/remote_known_hosts ]; then
    while read -r l; do grep -qxF "$l" /root/.ssh/known_hosts || echo "$l" >> /root/.ssh/known_hosts; done < /etc/mwadmin/remote_known_hosts
fi

pair=$(cat "$STATE" 2>/dev/null); [ "$pair" = "B" ] || pair=A
fails=0
while true; do
    target=$(uci -q get network.lan.ipaddr); target="${target%%/*}"
    [ -z "$target" ] && target=$(ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    [ -z "$target" ] && target=127.0.0.1
    if [ "$pair" = "A" ]; then p=$base; else p=$((base + 2)); fi
    sshfwd=""
    [ -n "$want_ssh" ] && sshfwd="-R 127.0.0.1:$((p + 1)):127.0.0.1:$(uci -q get dropbear.@dropbear[0].Port || echo 22)"
    logger -t mwremote "tunnel up: ${user}@${host} -> 127.0.0.1:$p (this router $target:$local_port), pair $pair"
    t0=$(date +%s)
    # After two failures in a row on the normal route, try the other online
    # lines one by one (mwan3 use <line>): covers a line that passes pings
    # but cannot reach the website.
    runner=""
    if [ "$fails" -ge 2 ] && command -v mwan3 >/dev/null 2>&1; then
        lines=$(mwan3 status 2>/dev/null | sed -n 's/^[[:space:]]*interface \(wan[0-9]\) is online.*/\1/p')
        nl=$(printf '%s\n' "$lines" | grep -c .)
        if [ "$nl" -gt 0 ]; then
            pick=$(printf '%s\n' "$lines" | sed -n "$(( (fails - 2) % nl + 1 ))p")
            if [ -n "$pick" ]; then runner="mwan3 use $pick"; logger -t mwremote "normal route failed $fails times; trying the tunnel through $pick"; fi
        fi
    fi
    # -y: accept the server's key the first time only (a changed key is refused)
    # -K 15: keepalive; a dead link is dropped after a few missed replies
    $runner /usr/bin/dbclient -N -R "127.0.0.1:$p:$target:$local_port" $sshfwd \
        -i "$KEYFILE" -y -K 15 -I 0 \
        -o ExitOnForwardFailure=yes -o BatchMode=yes \
        -p "$ssh_port" "${user}@${host}" </dev/null 2>/tmp/mwremote.err
    ran=$(( $(date +%s) - t0 ))
    if grep -qiE "forwarding failed|forward request failed" /tmp/mwremote.err 2>/dev/null; then
        # the server still holds these ports: use the other pair next time
        [ "$pair" = "A" ] && pair=B || pair=A
        echo "$pair" > "$STATE"
        logger -t mwremote "ports in use on the server (old session); switching to pair $pair"
        fails=0
        sleep 5
        continue
    fi
    # connection refused / no internet: back off so the server is not hammered
    if [ "$ran" -lt 60 ]; then fails=$((fails + 1)); else fails=0; fi
    w=$((10 * fails)); [ "$w" -gt 120 ] && w=120; [ "$w" -lt 10 ] && w=10
    sleep "$w"
done
