#!/bin/sh
# block.sh — sites the admin has blocked, with per-person exceptions.
#
# The admin blocks a site (a domain; its sub-domains are included). Someone
# who opens it lands on a page with a "Request access" button. The request
# shows up for the admin; once approved, that one device can open the site
# while it stays blocked for everybody else.
#
# How it works: blocking is done in DNS, because that is the only place a
# small router can tell "youtube.com" from the other sites sharing its
# servers. Devices are split into groups by which blocked sites they have
# been allowed. Each group gets a tiny DNS forwarder (a second dnsmasq on its
# own port) that answers the still-blocked names with the router's block-page
# address and passes everything else to the normal DNS. A small nftables
# table of its own ("inet mwblock") steers each device's DNS to its group.
# With nothing blocked there is no table and no extra process at all.
#
# Sourced by api.sh (/sites endpoints) and the portal CGI; the forwarders are
# run by /etc/init.d/mwblock.

. /usr/lib/mwadmin/common.sh
. /usr/lib/mwadmin/pause.sh

B_SITES=/etc/mwadmin/blocked_sites      # one domain per line
B_REQ=/etc/mwadmin/site_requests        # mac <TAB> domain <TAB> epoch <TAB> pending|approved|denied
B_DIR="$MW_RUN/block"
B_NFT="$B_DIR/table.nft"
B_PORT0=5300
B_PAGE_PORT=8188
B_MAX_SITES=60
B_MAX_REQ=400

block_ensure() {
    mkdir -p /etc/mwadmin "$B_DIR"
    [ -f "$B_SITES" ] || : > "$B_SITES"
    [ -f "$B_REQ" ] || { : > "$B_REQ"; chmod 600 "$B_REQ"; }
}

block_lan_ip() { local i; i=$(uget_d network.lan.ipaddr 192.168.1.1); printf '%s' "${i%%/*}"; }

# Address blocked names resolve to. It has to be an address of this router
# that is NOT the admin panel's, so the block page can be told apart.
block_sink() {
    local s
    # its own address first: the .254 alias is the admin panel (multiwan.router)
    s=$(uci -q get network.lan_block.ipaddr)
    [ -n "$s" ] && { printf '%s' "${s%%/*}"; return; }
    s=$(ip -4 addr show dev br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/32.*/\1/p' | head -n1)
    [ -n "$s" ] || s=$(block_lan_ip)
    printf '%s' "$s"
}

block_any() { [ -s "$B_SITES" ]; }

# "https://WWW.Example.com/path" -> "example.com"; prints nothing if not a domain
block_clean_domain() {
    local d
    d=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n' | sed -e 's#^[a-z]*://##' -e 's#[/?\#].*$##' -e 's#:[0-9]*$##' -e 's#^www\.##' -e 's#\.$##')
    [ "${#d}" -le 80 ] || return 0
    printf '%s' "$d" | grep -qE '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,24}$' && printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Apps. A phone app is blocked by blocking every address it talks to, so an
# app here is simply a named bundle of domains (plus, for apps that connect to
# fixed servers without asking DNS, their address ranges).
#   id | name | domains | address ranges | host names to look up when blocking
# An entry on the block list is a "unit": either a domain (has a dot) or one
# of these ids (never has a dot).
# ---------------------------------------------------------------------------
block_app_table() {
    cat <<'EOT'
tiktok|TikTok|tiktok.com tiktokv.com tiktokv.us tiktokcdn.com tiktokcdn-us.com musical.ly muscdn.com byteoversea.com ibytedtos.com ibyteimg.com ttwstatic.com||m.tiktok.com api.tiktokv.com v16m.tiktokcdn.com
facebook|Facebook and Messenger|facebook.com fbcdn.net fb.com fb.me facebook.net fbsbx.com messenger.com||graph.facebook.com b-graph.facebook.com gateway.facebook.com edge-mqtt.facebook.com star.c10r.facebook.com web.facebook.com m.facebook.com static.xx.fbcdn.net scontent.xx.fbcdn.net
instagram|Instagram|instagram.com cdninstagram.com ig.me||i.instagram.com graph.instagram.com gateway.instagram.com edge-mqtt.instagram.com scontent.cdninstagram.com
whatsapp|WhatsApp|whatsapp.com whatsapp.net wa.me||g.whatsapp.net mmg.whatsapp.net static.whatsapp.net web.whatsapp.com chat.cdn.whatsapp.net media.cdn.whatsapp.net v.whatsapp.net pps.whatsapp.net dit.whatsapp.net e1.whatsapp.net e2.whatsapp.net e3.whatsapp.net e4.whatsapp.net e5.whatsapp.net e6.whatsapp.net e7.whatsapp.net e8.whatsapp.net e9.whatsapp.net e10.whatsapp.net e11.whatsapp.net e12.whatsapp.net e13.whatsapp.net e14.whatsapp.net e15.whatsapp.net e16.whatsapp.net
youtube|YouTube|youtube.com googlevideo.com ytimg.com youtu.be youtubei.googleapis.com youtube.googleapis.com youtube-nocookie.com yt3.ggpht.com||m.youtube.com i.ytimg.com s.ytimg.com
snapchat|Snapchat|snapchat.com snap.com sc-cdn.net sc-gw.com sc-static.net snapkit.co||app.snapchat.com cf-st.sc-cdn.net
twitter|X (Twitter)|twitter.com x.com twimg.com t.co||api.twitter.com api.x.com abs.twimg.com pbs.twimg.com video.twimg.com
telegram|Telegram|telegram.org t.me telegram.me tdesktop.com telegra.ph telesco.pe|149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24|
netflix|Netflix|netflix.com netflix.net nflxvideo.net nflximg.net nflxext.com nflxso.net||
spotify|Spotify|spotify.com scdn.co spotifycdn.com||
discord|Discord|discord.com discordapp.com discordapp.net discord.gg discord.media||
pubg|PUBG Mobile|pubgmobile.com pubg.com igamecj.com proximabeta.com krafton.com||
freefire|Free Fire|freefiremobile.com garena.com||
EOT
}

block_app_field() { block_app_table | awk -F'|' -v id="$1" -v n="$2" '$1 == id { printf "%s", $n }'; }

# What the admin typed or picked -> a unit, or nothing if it is neither a
# known app nor a domain.
block_clean_unit() {
    local u
    u=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n')
    case "$u" in
        ''|*[!a-z0-9]*) block_clean_domain "$1" ;;
        *) [ -n "$(block_app_field "$u" 1)" ] && printf '%s' "$u" ;;
    esac
}

block_is_app() { case "$1" in *.*) return 1 ;; esac; return 0; }

# Name to show people for a unit.
block_unit_label() {
    if block_is_app "$1"; then printf '%s app' "$(block_app_field "$1" 2)"; else printf '%s' "$1"; fi
}

# Domains behind a unit, space separated.
block_unit_domains() {
    if block_is_app "$1"; then block_app_field "$1" 3; else printf '%s' "$1"; fi
}

# Which blocked unit does this host name fall under? (prints it, or nothing)
block_match() {
    local h u d
    h=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    [ -s "$B_SITES" ] || return 0
    while read -r u; do
        [ -n "$u" ] || continue
        for d in $(block_unit_domains "$u"); do
            case "$h" in "$d"|*".$d") printf '%s' "$u"; return ;; esac
        done
    done < "$B_SITES"
}

# pending / approved / denied / "" for one device and site
block_status() {
    awk -F'\t' -v m="$1" -v d="$2" '$1 == m && $2 == d { s = $4 } END { printf "%s", s }' "$B_REQ" 2>/dev/null
}

block_set_status() {     # <mac> <domain> <status|remove>
    block_ensure
    awk -F'\t' -v m="$1" -v d="$2" '!($1 == m && $2 == d)' "$B_REQ" > "$B_REQ.tmp"
    [ "$3" = "remove" ] || printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "$3" >> "$B_REQ.tmp"
    chmod 600 "$B_REQ.tmp"
    mv "$B_REQ.tmp" "$B_REQ"
}

# Write one dnsmasq config per group of devices, and the nftables table that
# sends each device's DNS to its group. Group 0 is "no exceptions".
block_gen() {
    block_ensure
    rm -f "$B_DIR"/g*.conf "$B_NFT"
    block_any || return 0
    # break time: the blocked sites are open for everybody (pause.sh)
    pause_in_break && return 0
    local logq=0
    [ "$(uget dhcp.@dnsmasq[0].logqueries)" = "1" ] && logq=1
    {
        echo "@apps";  block_app_table
        echo "@sites"; cat "$B_SITES"
        echo "@req";   cat "$B_REQ"
    } | awk -v dir="$B_DIR" -v sink="$(block_sink)" -v logq="$logq" \
        -v exm="$(cut -f1 /etc/mwadmin/exempt_devices 2>/dev/null | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')" \
        -v dnslog="$(uget dhcp.@dnsmasq[0].logfacility)" -v port0="$B_PORT0" -v page="$B_PAGE_PORT" -v nftf="$B_NFT" '
        /^@/ { sec = $1; next }
        sec == "@apps" { split($0, a, "|"); adom[a[1]] = a[3]; anet[a[1]] = a[4]; next }
        sec == "@sites" { if ($1 != "" && !($1 in isdom)) { dom[++nd] = $1; isdom[$1] = 1 } next }
        sec == "@req" {
            split($0, a, "\t")
            if (a[4] == "approved" && (a[2] in isdom) && a[1] ~ /^[0-9a-f:]+$/ && length(a[1]) == 17) {
                ok[a[1], a[2]] = 1; macs[a[1]] = 1
                okm[a[2]] = okm[a[2]] (okm[a[2]] == "" ? "" : ", ") a[1]
            }
            next
        }
        END {
            ng = 0
            for (m in macs) {
                k = ""
                for (i = 1; i <= nd; i++) if ((m, dom[i]) in ok) k = k dom[i] ","
                if (k == "") continue
                if (!(k in k2g)) { if (ng >= 12) continue; k2g[k] = ++ng; gk[ng] = "," k }
                g = k2g[k]
                gm[g] = gm[g] (gm[g] == "" ? "" : ", ") m
            }
            for (g = 0; g <= ng; g++) {
                f = dir "/g" g ".conf"
                print "port=" (port0 + g) > f
                print "interface=br-lan" > f
                print "bind-dynamic" > f
                print "no-resolv" > f
                print "server=127.0.0.1" > f
                print "no-hosts" > f
                print "cache-size=0" > f
                print "user=dnsmasq" > f
                print "group=dnsmasq" > f
                print "pid-file=" dir "/g" g ".pid" > f
                if (logq == 1 && dnslog != "") { print "log-queries=extra" > f; print "log-facility=" dnslog > f }
                for (i = 1; i <= nd; i++) {
                    if (index(gk[g], "," dom[i] ",")) continue
                    nn = split((dom[i] in adom) ? adom[dom[i]] : dom[i], dd, " ")
                    for (j = 1; j <= nn; j++) {
                        print "address=/" dd[j] "/" sink > f
                        print "address=/" dd[j] "/::" > f
                    }
                }
                close(f)
            }
            print "table inet mwblock" > nftf
            print "delete table inet mwblock" > nftf
            print "table inet mwblock {" > nftf
            if (exm != "") print "    set ex { type ether_addr; elements = { " exm " } }" > nftf
            for (g = 1; g <= ng; g++) print "    set g" g " { type ether_addr; elements = { " gm[g] " } }" > nftf
            # devices using their free time (pause.sh fills this set)
            print "    set free { type ether_addr; }" > nftf
            print "    chain mwb_nat {" > nftf
            print "        type nat hook prerouting priority dstnat - 9; policy accept;" > nftf
            print "        iifname \"br-lan\" ip daddr " sink " tcp dport 80 redirect to :" page > nftf
            if (exm != "") print "        iifname \"br-lan\" ether saddr @ex return" > nftf
            print "        iifname \"br-lan\" ether saddr @free return" > nftf
            for (g = 1; g <= ng; g++)
                print "        iifname \"br-lan\" ether saddr @g" g " meta l4proto { tcp, udp } th dport 53 redirect to :" (port0 + g) > nftf
            print "        iifname \"br-lan\" meta l4proto { tcp, udp } th dport 53 redirect to :" port0 > nftf
            print "    }" > nftf
            # DNS-over-TLS would walk straight past the block; refusing it makes
            # phones fall back to the router DNS by themselves.
            # "hot": addresses of a site that was blocked a moment ago. Devices
            # remember where a site lives for a few minutes, so DNS alone would
            # let it keep opening for a while; this closes that gap and then
            # empties itself.
            print "    set hot { type ipv4_addr; flags timeout; }" > nftf
            for (i = 1; i <= nd; i++) if (dom[i] in adom) print "    set ip_" dom[i] " { type ipv4_addr; flags timeout; }" > nftf
            print "    chain mwb_fwd {" > nftf
            print "        type filter hook forward priority filter - 9; policy accept;" > nftf
            if (exm != "") print "        iifname \"br-lan\" ether saddr @ex return" > nftf
            print "        iifname \"br-lan\" ether saddr @free return" > nftf
            print "        iifname \"br-lan\" ip daddr @hot meta l4proto tcp reject with tcp reset" > nftf
            print "        iifname \"br-lan\" ip daddr @hot reject" > nftf
            print "        iifname \"br-lan\" tcp dport 853 reject with tcp reset" > nftf
            # Apps do not rely on DNS alone (they remember addresses and keep
            # connections open), so each blocked app also gets a set of the
            # server addresses seen for it (filled by block_fill) and, where
            # known, its fixed ranges. Approved devices are let through.
            for (i = 1; i <= nd; i++) {
                if (!(dom[i] in adom)) continue
                who = ""
                if (okm[dom[i]] != "") who = " ether saddr != { " okm[dom[i]] " }"
                print "        iifname \"br-lan\" ip daddr @ip_" dom[i] who " meta l4proto tcp reject with tcp reset" > nftf
                print "        iifname \"br-lan\" ip daddr @ip_" dom[i] who " reject" > nftf
                if (anet[dom[i]] == "") continue
                nets = anet[dom[i]]; gsub(/ +/, ", ", nets)
                print "        iifname \"br-lan\" ip daddr { " nets " }" who " reject" > nftf
            }
            print "    }" > nftf
            # HTTPS cannot be shown a different page (the browser would see a
            # wrong certificate), so it is refused at once instead of hanging.
            print "    chain mwb_in {" > nftf
            print "        type filter hook input priority filter - 9; policy accept;" > nftf
            print "        iifname \"br-lan\" ip daddr " sink " tcp dport 443 reject with tcp reset" > nftf
            print "    }" > nftf
            print "}" > nftf
        }'
    local f d sink; sink=$(block_sink)
    for f in "$B_DIR"/g*.conf; do
        [ -f "$f" ] || continue
        echo "address=/blocked.router/$sink" >> "$f"
    done
}

block_table_load()   { [ -s "$B_NFT" ] && nft -f "$B_NFT"; }
block_table_remove() { nft delete table inet mwblock 2>/dev/null; }

# Current IPv4 addresses of a site and its www name.
block_ips() {
    local n
    for n in "$1" "www.$1"; do
        nslookup "$n" 127.0.0.1 2>/dev/null | awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF }'
    done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(127\.|0\.|192\.168\.|10\.)' | sort -u
}

# Server addresses of one blocked app: everything devices were recently told
# for its names (the app-usage tracker keeps that list), plus a fresh lookup
# of its main names. New ones are remembered, added to the app's firewall set
# and any open connection to them is cut.
block_fill_unit() {
    local u="$1" f="$B_DIR/ips.$1" doms n ip list=""
    block_is_app "$u" || return 0
    doms=$(block_app_field "$u" 3)
    touch "$f"
    {
        [ -s "$MW_RUN/apps.ipdom" ] && awk -v doms="$doms" '
            BEGIN { nd = split(doms, d, " ") }
            $2 !~ /googleapis\.com$/ {
                for (i = 1; i <= nd; i++) {
                    l = length($2) - length(d[i])
                    if ($2 == d[i] || (l > 0 && substr($2, l) == "." d[i])) { print $1; break }
                }
            }' "$MW_RUN/apps.ipdom"
        for n in $doms $(block_app_field "$u" 5); do
            case "$n" in *googleapis.com) continue ;; esac
            nslookup "$n" 127.0.0.1 2>/dev/null | awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF }'
        done
    } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(127\.|0\.|192\.168\.|10\.)' | sort -u > "$f.new"
    while read -r ip; do
        grep -qxF "$ip" "$f" && continue
        echo "$ip" >> "$f"
        conntrack -D -d "$ip" >/dev/null 2>&1
    done < "$f.new"
    rm -f "$f.new"
    tail -n 600 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    list=$(sed 's/$/ timeout 1d/' "$f" | tr '\n' ',' | sed 's/,$//')
    [ -n "$list" ] && nft add element inet mwblock "ip_$u" "{ $list }" 2>/dev/null
    return 0
}

block_fill() {
    local u
    [ -s "$B_SITES" ] || return 0
    while read -r u; do
        [ -n "$u" ] && block_fill_unit "$u"
    done < "$B_SITES"
}

# Cut connections that are already open to a site, so a change is felt at
# once instead of when the browser next reconnects. With "hot" the site's
# addresses are also refused outright for five minutes.
block_kick() {       # <unit> [hot]
    local d ip
    for d in $(block_unit_domains "$1"); do
        for ip in $(block_ips "$d"); do
            # an app's servers are shared with other apps of the same company,
            # so only a single site is refused by address
            [ "$2" = "hot" ] && ! block_is_app "$1" && nft add element inet mwblock hot "{ $ip timeout 5m }" 2>/dev/null
            conntrack -D -d "$ip" >/dev/null 2>&1
        done
    done
    if block_is_app "$1"; then
        for ip in $(block_app_field "$1" 4); do conntrack -D -d "$ip" >/dev/null 2>&1; done
        block_fill_unit "$1"
        # also the addresses known from before this change
        [ -s "$B_DIR/ips.$1" ] && while read -r ip; do conntrack -D -d "$ip" >/dev/null 2>&1; done < "$B_DIR/ips.$1"
    fi
    return 0
}

# Apply the current lists (called after every change).
block_apply() {
    /etc/init.d/mwblock restart >/dev/null 2>&1
    # the rebuilt table starts with empty app address sets
    block_fill
}

# Once a minute from the mwsite watcher: if sites are blocked but a forwarder
# died or the table is gone, put things back; DNS must never be left pointing
# at a port nobody answers on.
block_tick() {
    # free time and break time first: break switches this whole table off
    pause_tick
    pause_in_break && return 0
    block_any || return 0
    if ! pgrep -f "$B_DIR/g0.conf" >/dev/null 2>&1; then
        block_table_remove
        block_apply
    elif ! nft list table inet mwblock >/dev/null 2>&1; then
        block_table_load
        pause_sync
    fi
    block_fill
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
api_sites_get() {
    block_ensure
    printf '{"ok":true,%s,' "$(jstr page "http://$(block_lan_ip):$B_PAGE_PORT")"
    {
        echo "@apps";   block_app_table
        echo "@sites";  cat "$B_SITES" 2>/dev/null
        echo "@guests"; cat /etc/mwadmin/guests 2>/dev/null
        echo "@leases"; cat /tmp/dhcp.leases 2>/dev/null
        echo "@req";    cat "$B_REQ" 2>/dev/null
    } | awk '
        function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s); return "\"" s "\"" }
        function lab(u) { return (u in an) ? an[u] " app" : u }
        /^@/ { sec = $1; next }
        sec == "@apps" { split($0, a, "|"); an[a[1]] = a[2]; aid[++napp] = a[1]; next }
        sec == "@sites" { if ($1 != "") { dom[++nd] = $1; isdom[$1] = 1 } next }
        sec == "@guests" { n = split($0, a, "\t"); if (n >= 4) { gn[a[1]] = a[4]; gp[a[1]] = a[2] } next }
        sec == "@leases" && NF >= 3 { host[tolower($2)] = ($4 == "*" ? "" : $4); next }
        sec == "@req" { n = split($0, a, "\t"); if (n >= 4 && (a[2] in isdom)) { nr++; rm[nr] = a[1]; rd[nr] = a[2]; rt[nr] = a[3]; rs[nr] = a[4]; if (a[4] == "approved") na[a[2]]++; if (a[4] == "pending") np++ } next }
        END {
            printf "\"pending\":%d,\"sites\":[", np + 0
            for (i = 1; i <= nd; i++) printf "%s{\"domain\":%s,\"label\":%s,\"app\":%s,\"approved\":%d}", (i > 1 ? "," : ""), q(dom[i]), q(lab(dom[i])), ((dom[i] in an) ? "true" : "false"), na[dom[i]] + 0
            printf "],\"apps\":["
            for (i = 1; i <= napp; i++) printf "%s{\"id\":%s,\"name\":%s,\"blocked\":%s}", (i > 1 ? "," : ""), q(aid[i]), q(an[aid[i]]), ((aid[i] in isdom) ? "true" : "false")
            printf "],\"requests\":["
            f = 1
            for (pass = 1; pass <= 2; pass++) for (i = nr; i >= 1; i--) {
                if ((pass == 1) != (rs[i] == "pending")) continue
                m = rm[i]
                printf "%s{\"mac\":%s,\"name\":%s,\"phone\":%s,\"host\":%s,\"domain\":%s,\"label\":%s,\"ts\":%d,\"status\":%s}", (f ? "" : ","), q(m), q(gn[m]), q(gp[m]), q(host[m]), q(rd[i]), q(lab(rd[i])), rt[i] + 0, q(rs[i])
                f = 0
            }
            printf "]"
        }'
    printf '}\n'
}

api_sites_block() {
    block_ensure
    local d
    d=$(block_clean_unit "$(bodyval domain)")
    [ -n "$d" ] || { json_error "That does not look like a site address. Type it like youtube.com"; return; }
    grep -qxF "$d" "$B_SITES" && { json_error "That is already blocked."; return; }
    if ! block_is_app "$d"; then
        [ -n "$(block_match "$d")" ] && { json_error "That site is already covered by something on the block list."; return; }
    fi
    [ "$(wc -l < "$B_SITES")" -lt "$B_MAX_SITES" ] || { json_error "The block list is full."; return; }
    echo "$d" >> "$B_SITES"
    block_apply
    block_kick "$d" hot
    log "site blocked: $d"
    json_ok "$(jstr message "$(block_unit_label "$d") is blocked.")"
}

api_sites_unblock() {
    block_ensure
    local d
    d=$(block_clean_unit "$(bodyval domain)")
    [ -n "$d" ] && grep -qxF "$d" "$B_SITES" || { json_error "That site is not on the block list."; return; }
    grep -vxF "$d" "$B_SITES" > "$B_SITES.tmp"; mv "$B_SITES.tmp" "$B_SITES"
    rm -f "$B_DIR/ips.$d"
    awk -F'\t' -v d="$d" '$2 != d' "$B_REQ" > "$B_REQ.tmp"; chmod 600 "$B_REQ.tmp"; mv "$B_REQ.tmp" "$B_REQ"
    block_apply
    log "site unblocked: $d"
    json_ok "$(jstr message "$(block_unit_label "$d") is open for everyone again.")"
}

# Admin answers a request: approve | deny | remove (remove = forget it, the
# device is blocked again and may ask again).
api_sites_decide() {
    block_ensure
    local mac d what was
    mac=$(printf '%s' "$(bodyval mac)" | tr 'A-F' 'a-f')
    printf '%s' "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { json_error "Unknown device."; return; }
    d=$(block_clean_unit "$(bodyval domain)")
    [ -n "$d" ] && grep -qxF "$d" "$B_SITES" || { json_error "That site is not on the block list."; return; }
    what=$(bodyval decision)
    was=$(block_status "$mac" "$d")
    case "$what" in
        approve) block_set_status "$mac" "$d" approved; block_apply; block_fill
                 log "site request approved: $mac -> $d"
                 json_ok "$(jstr message "Approved. $(block_unit_label "$d") opens for that device within a minute.")" ;;
        deny)    block_set_status "$mac" "$d" denied
                 [ "$was" = "approved" ] && { block_apply; block_kick "$d"; }
                 json_ok "$(jstr message 'Request declined.')" ;;
        remove)  block_set_status "$mac" "$d" remove
                 [ "$was" = "approved" ] && { block_apply; block_kick "$d"; }
                 json_ok "$(jstr message 'Removed.')" ;;
        *) json_error "Nothing to change." ;;
    esac
}

case "${0##*/}" in
    block.sh)
        case "$1" in
            tick) block_tick ;;
            gen)  block_gen ;;
        esac ;;
esac
