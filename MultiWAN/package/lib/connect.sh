#!/bin/sh
# connect.sh - join this router to a Baytaar website with a one-time key.
#
#   sh connect.sh join <website> <key> [replace]
#   sh connect.sh status
#
# <website> is just the name, e.g. mikaelbhai.com (https:// and any path are
# ignored). The key is your account's API key: sign in on the website, press
# "Add a router", and the same key works on as many routers as you like; each
# one shows up as its own router in your account. (A one-time key made with
# cli.php new-key also works.)
#
# What happens: the router sends the key over HTTPS to the website's
# enroll.php. The website answers with this router's own token and the
# addresses of its upload and HTTPS channel. The router stores them, turns on
# the upload (events, activity) and the HTTPS channel the website uses to
# reach this router's panel, and restarts those two services. The SSH tunnel
# is NOT needed: the HTTPS channel carries every panel call (slower, but it
# works from any network). Nothing else on the router changes.
#
# A router that already has a token keeps it unless "replace" is given, so a
# stray call cannot silently move it to another website.
#
# Also reachable from the panel API: POST /connect {site, key, replace}, GET /connect.

. /usr/lib/mwadmin/common.sh

CN_TOKEN=/etc/mwadmin/portal_token

cn_cacert() {
    local b=/tmp/mwadmin-cabundle.pem
    [ -s "$b" ] || cat /etc/ssl/certs/ca-certificates.crt /usr/lib/mwadmin/le-intermediates.pem > "$b" 2>/dev/null
    printf '%s' "$b"
}

# A stable id for this router (not its MAC itself): the website uses it to recognise the router,
# so joining twice (a reset, a re-run) gives the same router back instead of a duplicate.
cn_device_id() {
    local mac
    mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    [ -n "$mac" ] || mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
    [ -n "$mac" ] || mac=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    printf 'd%s' "$(printf 'baytaar-router:%s' "$mac" | md5sum | cut -c1-31)"
}

cn_status() {
    local url host last
    url=$(uget mwadmin.sync.url)
    host=$(printf '%s' "$url" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*$##')
    last=$(cat /tmp/mwadmin-push.last 2>/dev/null)
    json_ok "$(jbool connected "$([ -s "$CN_TOKEN" ] && echo 1 || echo 0)"),$(jstr site "$host"),$(jstr router_name "$(uget mwadmin.sync.router_name)"),$(jnum router_id "$(uget mwadmin.sync.router_id)"),$(jnum web_level "$(uget mwadmin.sync.web_level)"),$(jnum last_upload "$last"),$(jbool uploads_failing "$([ -s /tmp/mwadmin-push.fail ] && echo 1 || echo 0)")"
}

cn_join() {
    local site="$1" key="$2" replace="$3" host ca body resp url p token base rid rname err wlevel
    host=$(printf '%s' "$site" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*$##' | tr 'A-Z' 'a-z')
    valid_host "$host" || { json_error "That does not look like a website name."; return 1; }
    printf '%s' "$key" | grep -qE '^[A-Za-z0-9_-]{16,80}$' || { json_error "That key does not look right."; return 1; }
    if [ -s "$CN_TOKEN" ] && [ "$replace" != "replace" ] && [ "$replace" != "1" ]; then
        json_error "This router is already connected to a website. Add 'replace' to move it."; return 1
    fi
    ca=$(cn_cacert)
    body=$(printf '{"key":"%s","device_id":"%s","hostname":"%s","board":"%s","version":"%s"}' "$key" "$(cn_device_id)" \
        "$(json_escape "$(uget system.@system[0].hostname)")" \
        "$(json_escape "$(cat /tmp/sysinfo/board_name 2>/dev/null)")" \
        "$(json_escape "$(cat /etc/mwadmin/fw_version 2>/dev/null)")")
    resp=""
    # the website's folder may be /router/ today or the root later: try both
    for p in router ""; do
        url="https://$host/${p:+$p/}enroll.php"
        resp=$(curl -s -m 25 --connect-timeout 8 --cacert "$ca" -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null)
        printf '%s' "$resp" | grep -q '"ok":true' && break
        err=$(printf '%s' "$resp" | jsonfilter -e '@.error' 2>/dev/null)
        [ -n "$err" ] && break              # the website answered and said no: do not try the other path
        resp=""
    done
    if ! printf '%s' "$resp" | grep -q '"ok":true'; then
        if [ -n "$err" ]; then json_error "$err"
        else json_error "Could not reach https://$host/ (no answer from enroll.php). Check the name and that this router has internet."; fi
        return 1
    fi
    token=$(printf '%s' "$resp" | jsonfilter -e '@.token' 2>/dev/null)
    base=$(printf '%s' "$resp" | jsonfilter -e '@.base' 2>/dev/null)
    rid=$(printf '%s' "$resp" | jsonfilter -e '@.router_id' 2>/dev/null)
    rname=$(printf '%s' "$resp" | jsonfilter -e '@.name' 2>/dev/null)
    wlevel=$(printf '%s' "$resp" | jsonfilter -e '@.web_level' 2>/dev/null)
    printf '%s' "$token" | grep -qE '^[a-f0-9]{48,128}$' || { json_error "The website's answer was not understood."; return 1; }
    case "$base" in https://"$host"/*) ;; *) json_error "The website named an address outside itself; refusing."; return 1 ;; esac
    base="${base%/}"

    ( umask 077; printf '%s' "$token" > "$CN_TOKEN.new" ) && mv "$CN_TOKEN.new" "$CN_TOKEN"
    [ "$(uget mwadmin.sync)"  = "sync" ]  || uci set mwadmin.sync='sync'
    [ "$(uget mwadmin.relay)" = "relay" ] || uci set mwadmin.relay='relay'
    uci set mwadmin.sync.enabled='1'
    uci set mwadmin.sync.url="$base/ingest.php"
    uci set mwadmin.sync.router_id="$rid"
    uci set mwadmin.sync.router_name="$rname"
    uci set mwadmin.sync.web_level="${wlevel:-0}"          # how new the website's side of the contract is (see caps.sh)
    uci set mwadmin.relay.enabled='1'
    uci set mwadmin.relay.url="$base"
    uci commit mwadmin
    log "connected to $host as router $rid ($rname)"
    /etc/init.d/mwrelay restart >/dev/null 2>&1
    /etc/init.d/mwevents restart >/dev/null 2>&1
    sleep 3
    sh /usr/lib/mwadmin/events.sh push >/dev/null 2>&1
    json_ok "$(jstr message "Connected to $host as '$rname'. The website can now reach this router's panel over HTTPS.")$(printf ',%s,%s' "$(jstr site "$host")" "$(jnum router_id "$rid")")"
}

# API entry points (api.sh sources this file)
api_connect_get()  { cn_status; }
api_connect_post() { cn_join "$(bodyval site)" "$(bodyval key)" "$(bodyval replace)"; }

case "${0##*/}" in
    connect.sh)
        case "$1" in
            join)   shift; cn_join "$1" "$2" "$3" ;;
            status) cn_status ;;
            *)      echo "usage: connect.sh join <website> <key> [replace] | status" >&2; exit 1 ;;
        esac ;;
esac
