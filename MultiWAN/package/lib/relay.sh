#!/bin/sh
# relay.sh - the router side of the website's HTTPS fallback channel.
#
# The website normally reaches this router through the SSH tunnel (mwremote).
# On a line that blocks outgoing SSH, it queues the call instead and this
# loop picks it up over ordinary HTTPS (port 443), replays it against this
# router's own admin API and posts the answer back. Only paths under
# /cgi-bin/mwadmin/ are ever replayed.

. /usr/lib/mwadmin/common.sh
# curl_any: tries the normal route, then each other online line
. /usr/lib/mwadmin/netfall.sh

CAB=/tmp/mwadmin-cabundle.pem
BASE=$(uget_d mwadmin.relay.url "https://mikaelbhai.com/router")
TOK=$(cat /etc/mwadmin/portal_token 2>/dev/null)
PORT=$(uget_d mwadmin.@main[0].port 8080)

answer() {   # id method path body
    local id="$1" method="$2" path="$3" body="$4" d="/tmp/mwrelay.$1" lan code ctype disp enc
    case "$path" in /cgi-bin/mwadmin/*) ;; *) return ;; esac
    lan=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
    mkdir -p "$d"
    if [ "$method" = "POST" ]; then
        printf '%s' "$body" > "$d/in"
        curl -s -m 120 -D "$d/h" -o "$d/out" -X POST -H 'Content-Type: application/json' --data-binary @"$d/in" "http://$lan:$PORT$path"
    else
        curl -s -m 120 -D "$d/h" -o "$d/out" "http://$lan:$PORT$path"
    fi
    code=$(sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' "$d/h"); [ -z "$code" ] && code=502
    enc() { printf '%s' "$1" | tr -d '\r' | sed 's/%/%25/g; s/ /%20/g; s/"/%22/g; s/;/%3B/g; s/=/%3D/g; s/&/%26/g; s/+/%2B/g; s#/#%2F#g'; }
    ctype=$(enc "$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$d/h" | head -n1)")
    disp=$(enc "$(sed -n 's/^[Cc]ontent-[Dd]isposition: *//p' "$d/h" | head -n1)")
    touch "$d/out"
    curl_any -s -m 60 --connect-timeout 8 --cacert "$CAB" -X POST -H 'Content-Type: application/octet-stream' --data-binary @"$d/out" \
        "$BASE/relay.php?token=$TOK&id=$id&code=$code&ctype=$ctype&disp=$disp" >/dev/null 2>&1
    rm -rf "$d"
}

[ -n "$TOK" ] || { logger -t mwrelay "no portal token; HTTPS channel not started"; sleep 60; exit 1; }
[ -s "$CAB" ] || cat /etc/ssl/certs/ca-certificates.crt /usr/lib/mwadmin/le-intermediates.pem > "$CAB" 2>/dev/null

while true; do
    [ "$(uget_d mwadmin.relay.enabled 1)" = "1" ] || { sleep 60; continue; }
    r=$(curl_any -s -m 35 --connect-timeout 8 --cacert "$CAB" "$BASE/relay.php?token=$TOK" 2>/dev/null)
    case "$r" in *'"ok":true'*) ;; *) sleep 10; continue ;; esac
    n=0
    while id=$(printf '%s' "$r" | jsonfilter -e "@.calls[$n].id" 2>/dev/null) && [ -n "$id" ]; do
        m=$(printf '%s' "$r" | jsonfilter -e "@.calls[$n].method")
        p=$(printf '%s' "$r" | jsonfilter -e "@.calls[$n].path")
        bd=$(printf '%s' "$r" | jsonfilter -e "@.calls[$n].body")
        ( answer "$id" "$m" "$p" "$bd" ) &
        n=$((n + 1))
    done
done
