#!/bin/sh
# insight.sh — two read-only views of how the connection is actually doing:
#
#   1. CALL QUALITY. Measures what a voice or video call cares about — delay,
#      jitter (how much the delay wobbles) and packet loss — on every
#      connected line and on the mixed route devices really use. The website
#      turns those numbers into "would WhatsApp / Zoom work well here".
#      It is a measurement of the line, not a real call.
#
#   2. APP USAGE PER DEVICE. Which device moved how much data, and to what.
#      dnsmasq logs each lookup; that tells us which name every remote IP
#      belongs to. Once a minute the connection table is read, each flow's
#      new bytes are credited to (device, app). Kept in RAM only and reset on
#      reboot; the raw lookup log is emptied on every pass, so only the totals
#      per app survive, never a browsing history.
#      Blind spots, stated plainly: a device using its own encrypted DNS
#      (Android "Private DNS", some browsers) shows up as "Unknown", and a
#      flow that starts and ends between two passes is not counted.
#
# Sourced by api.sh for /quality and /apps; run directly for the jobs.

. /usr/lib/mwadmin/common.sh
. /usr/lib/mwadmin/site.sh

Q_DIR="$MW_RUN/quality"
DNS_LOG="/tmp/dnsmasq-queries.log"
A_MAP="$MW_RUN/apps.ipdom"      # remote ip -> name it was looked up as
A_SNAP="$MW_RUN/apps.snap"      # last seen byte count per flow
A_TOT="$MW_RUN/apps.tot"        # device ip <tab> app <tab> bytes
A_DET="$MW_RUN/apps.det"        # device ip <tab> app <tab> name or ip:port/proto <tab> bytes
A_SINCE="$MW_RUN/apps.since"
A_VIS="$MW_RUN/apps.visits"     # this pass: device ip <tab> site it looked up
A_NOW="$MW_RUN/apps.now"        # this pass: device ip <tab> app <tab> bytes
ACT_SPOOL=/tmp/mwadmin-activity.spool   # uploaded by events.sh push

# ---------------------------------------------------------------------------
# 1. Call quality
# ---------------------------------------------------------------------------
# $1 = wan1|wan2|wan3|mix   ("mix" = the default route, i.e. whatever mwan3
# hands a normal device right now, balanced or failover)
quality_one() {
    local which="$1" dev="" label="" down="" up="" out target sent recv
    mkdir -p "$Q_DIR"
    local f="$Q_DIR/$which.json"

    if [ "$which" = "mix" ]; then
        label="All lines together"
        # what the mix can carry: the sum of the lines currently in the policy
        local a d
        for a in $(mwan3_status_cached | awk '
                /Current ipv4 policies/ { p = 1; next } p && /^$/ { exit }
                p && /\(/ { gsub(/^[ \t]+/, ""); print $1 }'); do
            d=$(site_portval "$a" down_mbps); case "$d" in ''|null) d=0 ;; esac
            down=$(awk -v x="${down:-0}" -v y="$d" 'BEGIN { printf "%.1f", x + y }')
            d=$(site_portval "$a" up_mbps); case "$d" in ''|null) d=0 ;; esac
            up=$(awk -v x="${up:-0}" -v y="$d" 'BEGIN { printf "%.1f", x + y }')
        done
    else
        dev=$(site_l3dev "$which")
        site_line_key "$which" >/dev/null 2>&1 || {
            printf '{%s,%s,%s}\n' "$(jstr iface "$which")" "$(jstr label "$(printf '%s' "$which" | tr a-z A-Z)")" \
                "$(jstr status notconnected)" > "$f"
            return 0
        }
        label=$(site_label "$which"); [ -z "$label" ] && label=$(site_portval "$which" isp)
        [ -z "$label" ] && label=$(printf '%s' "$which" | tr a-z A-Z)
        down=$(site_portval "$which" down_mbps); up=$(site_portval "$which" up_mbps)
    fi

    printf '{%s,%s,%s}\n' "$(jstr iface "$which")" "$(jstr label "$label")" "$(jstr status running)" > "$f"

    # 15 pings a second apart: long enough to see jitter, short enough to wait for.
    for target in 1.1.1.1 8.8.8.8; do
        out=$(ping ${dev:+-I "$dev"} -c 15 -i 1 -W 2 "$target" 2>/dev/null)
        printf '%s' "$out" | grep -q 'time=' && break
    done

    printf '%s\n' "$out" | awk -v iface="$which" -v label="$label" -v target="$target" \
                              -v down="$down" -v up="$up" -v now="$(date +%s)" '
        function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
        function num(v) { return (v == "" || v == "null") ? "null" : v }
        /time=/ {
            t = $0; sub(/.*time=/, "", t); sub(/ .*/, "", t); t += 0
            n++; sum += t; if (t > mx) mx = t
            if (n > 1) { d = t - prev; if (d < 0) d = -d; jsum += d }
            prev = t
        }
        /packets transmitted/ { sent = $1; recv = $4 }
        END {
            if (sent == "") sent = 15
            if (recv == "") recv = n + 0
            loss = sent > 0 ? (sent - recv) * 100 / sent : 100
            printf "{\"iface\":%s,\"label\":%s,\"status\":\"ok\",\"tested_at\":%d,\"target\":%s,", q(iface), q(label), now, q(target)
            printf "\"sent\":%d,\"received\":%d,\"loss_pct\":%.1f,", sent, recv, loss
            if (n > 0) printf "\"latency_ms\":%.1f,\"jitter_ms\":%.1f,\"max_ms\":%.1f,", sum / n, (n > 1 ? jsum / (n - 1) : 0), mx
            else       printf "\"latency_ms\":null,\"jitter_ms\":null,\"max_ms\":null,"
            printf "\"down_mbps\":%s,\"up_mbps\":%s}\n", num(down), num(up)
        }' > "$f.tmp" && mv "$f.tmp" "$f"
}

quality_all() {
    lock_acquire quality || return 0
    mkdir -p "$Q_DIR"; rm -f "$Q_DIR"/*.json
    local i
    # all at once: every line is measured over the same 15 seconds
    for i in $SITE_WANS; do
        [ -z "$(uget "network.$i")" ] && continue
        quality_one "$i" &
    done
    quality_one mix &
    wait
    lock_release quality
    log "call quality test finished"
}

api_quality_get() {
    local running=0 first=1 f
    [ -d "$MW_RUN/locks/quality.lock" ] && running=1
    printf '{"ok":true,%s,"results":[' "$(jbool running "$running")"
    for f in "$Q_DIR"/wan1.json "$Q_DIR"/wan2.json "$Q_DIR"/wan3.json "$Q_DIR"/mix.json; do
        [ -s "$f" ] || continue
        [ $first -eq 0 ] && printf ','
        first=0
        cat "$f" | tr -d '\n'
    done
    printf ']}\n'
}

api_quality_test() {
    [ -d "$MW_RUN/locks/quality.lock" ] && { json_ok "$(jstr message 'A test is already running.')"; return; }
    ( setsid sh /usr/lib/mwadmin/insight.sh quality-all >/dev/null 2>&1 & ) &
    json_ok "$(jstr message 'Test started. It takes about 20 seconds.')"
}

# ---------------------------------------------------------------------------
# 2. App usage per device
# ---------------------------------------------------------------------------
apps_enable() {
    [ "$(uget dhcp.@dnsmasq[0].logqueries)" = "1" ] && \
        [ "$(uget dhcp.@dnsmasq[0].logfacility)" = "$DNS_LOG" ] && return 0
    uci set dhcp.@dnsmasq[0].logqueries='1'
    uci set dhcp.@dnsmasq[0].logfacility="$DNS_LOG"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    log "app usage: DNS lookup logging enabled"
}

apps_disable() {
    uci -q delete dhcp.@dnsmasq[0].logqueries
    uci -q delete dhcp.@dnsmasq[0].logfacility
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    rm -f "$DNS_LOG" "$A_MAP" "$A_SNAP" "$A_TOT" "$A_DET" "$A_SINCE"
    log "app usage: disabled and data cleared"
}

# One pass. Called once a minute from site.sh's watch loop.
apps_sample() {
    [ "$(uget dhcp.@dnsmasq[0].logqueries)" = "1" ] || return 0
    # The query log lives in RAM and is emptied by every pass. If passes stopped (2026-11-27: it reached 120 MB, filled
    # /tmp and stopped the uploads), never let it grow past 8 MB, lock or no lock: a minute of lookups is far smaller.
    [ "$(wc -c < "$DNS_LOG" 2>/dev/null || echo 0)" -gt 8000000 ] && { : > "$DNS_LOG"; log "DNS query log was over 8 MB (passes had stopped); emptied"; }
    lock_acquire apps || return 0
    local lan; lan=$(uget network.lan.ipaddr); lan="${lan%%/*}"; lan="${lan%.*}."

    # --- which name does each remote IP belong to? ---------------------------
    # --log-queries=extra prefixes every line with the query's serial number,
    # so an answer can be tied back to the name the DEVICE asked for even when
    # it was reached through a chain of CNAMEs (www.youtube.com -> ...google.com).
    if [ -s "$DNS_LOG" ]; then
        touch "$A_MAP"
        awk -v mapf="$A_MAP" '
            BEGIN { while ((getline l < mapf) > 0) { split(l, a, " "); if (!(a[1] in m)) { m[a[1]] = a[2]; ord[++n] = a[1] } } close(mapf) }
            {
                for (i = 1; i <= NF; i++) if ($i ~ /^query\[/) { qn[$4 $(i - 2)] = $(i + 1); next }
                for (i = 1; i <= NF; i++) if ($i == "reply" || $i == "cached") {
                    ip = $NF
                    if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ip ~ /:/) {
                        nm = (($4 $(i - 2)) in qn) ? qn[$4 $(i - 2)] : $(i + 1)
                        if (!(ip in m)) ord[++n] = ip
                        m[ip] = nm
                    }
                    next
                }
            }
            END { s = n > 6000 ? n - 6000 + 1 : 1; for (i = s; i <= n; i++) print ord[i], m[ord[i]] }
        ' "$DNS_LOG" > "$A_MAP.tmp" && mv "$A_MAP.tmp" "$A_MAP"
        # Site history (only when tracking is on): one record per device and
        # site per minute. The router's own lookups and local names are left out.
        if [ "$(uget_d mwadmin.sync.track_sites 1)" = "1" ]; then
            awk '{
                q = ""; for (i = 1; i <= NF; i++) if ($i ~ /^query\[(A|AAAA|HTTPS)\]$/) { q = $(i + 1); break }
                if (q == "" || $(NF - 1) != "from") next
                c = $NF; if (c ~ /^127\./ || c == "::1") next
                q = tolower(q); if (q !~ /\./ || q ~ /\.(lan|arpa|local|home|router)$/) next
                k = c "\t" q; if (!(k in s)) { s[k] = 1; printf "v\t%s\t%s\t0\n", c, q }
            }' "$DNS_LOG" > "$A_VIS"
        fi
        : > "$DNS_LOG"
    fi

    # --- credit each flow's new bytes to (device, app) -----------------------
    [ -f "$A_SINCE" ] || date +%s > "$A_SINCE"
    touch "$A_MAP" "$A_TOT" "$A_DET"
    local seed=0; [ -f "$A_SNAP" ] || seed=1
    touch "$A_SNAP"
    : > "$A_NOW"
    awk -v lan="$lan" -v mapf="$A_MAP" -v snapf="$A_SNAP" -v totf="$A_TOT" -v detf="$A_DET" -v nowf="$A_NOW" -v seed="$seed" '
        function app(d,    n, p, i) {
            if (d == "") return "Unknown"
            d = tolower(d)
            for (n = 1; n <= NP; n++) {
                i = index(d, pat[n])
                if (i && (pat[n] !~ /\./ || i == 1 || substr(d, i - 1, 1) == ".")) return nm[n]
            }
            n = split(d, p, ".")
            return n >= 2 ? p[n - 1] "." p[n] : d
        }
        function add(p, n) { pat[++NP] = p; nm[NP] = n }
        BEGIN {
            add("whatsapp", "WhatsApp"); add("wa.me", "WhatsApp")
            add("zoom.us", "Zoom"); add("zoom.com", "Zoom"); add("zoomgov", "Zoom")
            add("googlevideo", "YouTube"); add("youtube", "YouTube"); add("ytimg", "YouTube"); add("youtu.be", "YouTube")
            add("meet.google", "Google Meet")
            add("teams.microsoft", "Microsoft Teams"); add("teams.live", "Microsoft Teams"); add("skype", "Microsoft Teams")
            add("instagram", "Instagram"); add("cdninstagram", "Instagram")
            add("tiktok", "TikTok"); add("byteoversea", "TikTok"); add("ibytedtos", "TikTok"); add("musical.ly", "TikTok"); add("ttwstatic", "TikTok")
            add("netflix", "Netflix"); add("nflx", "Netflix")
            add("facebook", "Facebook"); add("fbcdn", "Facebook"); add("fbsbx", "Facebook"); add("messenger", "Facebook"); add("fb.com", "Facebook")
            add("telegram", "Telegram"); add("t.me", "Telegram")
            add("snapchat", "Snapchat"); add("sc-cdn", "Snapchat")
            add("twitter", "X (Twitter)"); add("twimg", "X (Twitter)"); add("x.com", "X (Twitter)")
            add("spotify", "Spotify"); add("scdn.co", "Spotify")
            add("twitch", "Twitch"); add("ttvnw", "Twitch")
            add("discord", "Discord"); add("linkedin", "LinkedIn"); add("licdn", "LinkedIn")
            add("openai", "ChatGPT"); add("chatgpt", "ChatGPT"); add("oaiusercontent", "ChatGPT")
            add("anthropic", "Claude"); add("claude.ai", "Claude")
            add("speedtest", "Speed test"); add("ookla", "Speed test"); add("fast.com", "Speed test")
            add("steam", "Steam"); add("epicgames", "Epic Games"); add("pubg", "PUBG"); add("roblox", "Roblox")
            add("primevideo", "Prime Video"); add("aiv-cdn", "Prime Video")
            add("github", "GitHub")
            add("icloud", "Apple"); add("apple.com", "Apple"); add("mzstatic", "Apple"); add("aaplimg", "Apple")
            add("windowsupdate", "Windows Update"); add("update.microsoft", "Windows Update"); add("delivery.mp.microsoft", "Windows Update")
            add("office", "Microsoft 365"); add("sharepoint", "Microsoft 365"); add("onedrive", "Microsoft 365"); add("live.com", "Microsoft 365")
            add("microsoft", "Microsoft"); add("msedge", "Microsoft"); add("azure", "Microsoft"); add("bing.com", "Microsoft")
            add("gstatic", "Google"); add("googleapis", "Google"); add("google", "Google"); add("gvt1", "Google"); add("ggpht", "Google")
            add("amazonaws", "Amazon cloud"); add("cloudfront", "Amazon cloud"); add("amazon", "Amazon")
            add("akamai", "Akamai CDN"); add("cloudflare", "Cloudflare"); add("fastly", "Fastly CDN")

            while ((getline l < mapf) > 0)  { split(l, a, " "); dom[a[1]] = a[2] }           close(mapf)
            while ((getline l < snapf) > 0) { n = split(l, a, " "); prev[a[1]] = a[2] }       close(snapf)
            while ((getline l < totf) > 0)  { split(l, a, "\t"); tot[a[1] "\t" a[2]] = a[3] } close(totf)
            while ((getline l < detf) > 0)  { n = split(l, a, "\t"); if (n >= 4) det[a[1] "\t" a[2] "\t" a[3]] = a[4] } close(detf)
        }
        {
            src = ""; dst = ""; sp = ""; dp = ""; b = 0; nb = 0
            for (i = 1; i <= NF; i++) {
                if (src == "" && $i ~ /^src=/) src = substr($i, 5)
                else if (dst == "" && $i ~ /^dst=/) dst = substr($i, 5)
                else if (sp == "" && $i ~ /^sport=/) sp = substr($i, 7)
                else if (dp == "" && $i ~ /^dport=/) dp = substr($i, 7)
                else if ($i ~ /^bytes=/) { b += substr($i, 7); nb++ }
            }
            # only LAN device -> outside world
            if (index(src, lan) != 1 || index(dst, lan) == 1) next
            if (nb == 0) next
            key = $3 "|" src "|" dst "|" sp "|" dp
            d = (key in prev) ? (b >= prev[key] ? b - prev[key] : b) : b
            snap[key] = b
            if (seed == 1 || d <= 0) next
            dn = (dst in dom) ? dom[dst] : ""
            an = app(dn)
            tot[src "\t" an] += d
            cur[src "\t" an] += d
            # what is behind each app: the name looked up, or for traffic with
            # no lookup ("Unknown") the address, port and protocol it went to
            if (dn != "") dk = src "\t" an "\t" tolower(dn)
            else dk = src "\t" an "\t" dst ":" dp "/" $3
            det[dk] += d
        }
        END {
            for (k in snap) print k, snap[k] > snapf
            close(snapf)
            for (k in tot) printf "%s\t%.0f\n", k, tot[k] > totf
            close(totf)
            for (k in det) printf "%s\t%.0f\n", k, det[k] > detf
            close(detf)
            for (k in cur) if (cur[k] >= 20000) printf "u\t%s\t%.0f\n", k, cur[k] > nowf
        }' /proc/net/nf_conntrack
    # keep the destination list small: the 4000 busiest entries
    if [ "$(wc -l < "$A_DET")" -gt 4000 ]; then
        sort -t "$(printf '\t')" -k4,4nr "$A_DET" | head -n 4000 > "$A_DET.t" && mv "$A_DET.t" "$A_DET"
    fi
    if [ "$(uget_d mwadmin.sync.track_sites 1)" = "1" ]; then
        ip neigh show 2>/dev/null > "$MW_RUN/neigh.now"
        # name shown: the person who signed this device in to the network,
        # else the device's own name from DHCP
        cat "$A_VIS" "$A_NOW" 2>/dev/null | awk -F'\t' -v ts="$(date +%s)" -v lf=/tmp/dhcp.leases -v nf="$MW_RUN/neigh.now" -v gf=/etc/mwadmin/guests '
            BEGIN {
                while ((getline l < lf) > 0) { split(l, a, " "); mac[a[3]] = a[2]; nm[a[3]] = (a[4] == "*" ? "" : a[4]) }
                while ((getline l < nf) > 0) { n = split(l, a, " "); for (i = 1; i < n; i++) if (a[i] == "lladdr" && !(a[1] in mac)) mac[a[1]] = a[i + 1] }
                while ((getline l < gf) > 0) { n = split(l, a, "\t"); if (n >= 4 && a[4] != "") who[tolower(a[1])] = a[4] }
            }
            { m = tolower(mac[$2]); n = (m in who) ? who[m] : nm[$2]
              printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, ts, m, $2, n, $3, $4 }' >> "$ACT_SPOOL"
        rm -f "$A_VIS"
        [ "$(wc -c < "$ACT_SPOOL" 2>/dev/null || echo 0)" -gt 3000000 ] && { tail -c 2000000 "$ACT_SPOOL" > "$ACT_SPOOL.t"; mv "$ACT_SPOOL.t" "$ACT_SPOOL"; }
    fi
    lock_release apps
}

# GET /apps/detail?ip=DEVICE&app=NAME : what makes up one app on one device:
# every name it looked up, and for "Unknown" every address it talked to
# without a lookup (port and protocol included, plus the address's own
# reverse name when it has one). Busiest first, at most 60.
api_apps_detail() {
    local ip app
    ip=$(qsval ip); app=$(qsval app)
    valid_ipv4 "$ip" || { json_error "Invalid device address."; return; }
    [ -n "$app" ] || { json_error "No app given."; return; }
    local list; list=$(awk -F'\t' -v ip="$ip" -v app="$app" '$1 == ip && $2 == app { print $4 "\t" $3 }' "$A_DET" 2>/dev/null | sort -rn | head -n 60)
    # reverse names for the busiest bare addresses, looked up side by side, 2 s each at most
    local d="$MW_RUN/ptr.$$" pids="" a killer
    mkdir -p "$d"
    for a in $(printf '%s\n' "$list" | cut -f2 | grep -E '^[0-9.]+:' | cut -d: -f1 | awk '!s[$0]++' | head -n 12); do
        # asked of 1.1.1.1 directly: the family filters used for normal lookups
        # answer reverse lookups slowly or not at all
        ( nslookup "$a" 1.1.1.1 2>/dev/null | sed -n 's/.*name = \([^ ]*\).*/\1/p' | sed 's/\.$//' | head -n1 > "$d/$a" ) &
        pids="$pids $!"
    done
    # no `timeout` on this router: whatever has not answered in 2 s is dropped
    if [ -n "$pids" ]; then
        ( sleep 2; kill $pids 2>/dev/null ) & killer=$!
        wait $pids 2>/dev/null
        kill "$killer" 2>/dev/null
    fi
    printf '{"ok":true,%s,%s,"items":[' "$(jstr ip "$ip")" "$(jstr app "$app")"
    printf '%s\n' "$list" | awk -F'\t' -v d="$d" '
        function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s); return "\"" s "\"" }
        NF >= 2 {
            dest = $2; ptr = ""
            if (dest ~ /^[0-9.]+:/) { split(dest, p, ":"); f = d "/" p[1]; if ((getline ptr < f) <= 0) ptr = ""; close(f) }
            printf "%s{\"dest\":%s,\"bytes\":%d,\"ptr\":%s}", (n++ ? "," : ""), q(dest), $1, q(ptr)
        }'
    printf ']}\n'
    rm -rf "$d"
}

api_apps_get() {
    local enabled=0
    [ "$(uget dhcp.@dnsmasq[0].logqueries)" = "1" ] && enabled=1

    # who is on Wi-Fi (and which band); everything else on the LAN is wired
    local wifi="" ifc band
    for ifc in $(iwinfo 2>/dev/null | sed -n 's/^\([a-z0-9-]*\)[[:space:]]*ESSID.*/\1/p'); do
        band=$(iwinfo "$ifc" info 2>/dev/null | sed -n 's/.*Channel: [0-9]* (\([0-9.]*\) GHz).*/\1/p' | head -n1)
        case "$band" in 2.*) band="2.4 GHz" ;; 5.*) band="5 GHz" ;; 6.*) band="6 GHz" ;; *) band="" ;; esac
        wifi="$wifi$(iwinfo "$ifc" assoclist 2>/dev/null | sed -n "s/^\([0-9A-Fa-f:]\{17\}\).*/\1 $band/p")
"
    done

    printf '{"ok":true,%s,%s,"devices":' "$(jbool enabled "$enabled")" "$(jnum since "$(cat "$A_SINCE" 2>/dev/null)")"
    {
        echo "@leases";  cat /tmp/dhcp.leases 2>/dev/null
        echo "@arp";     cat /proc/net/arp 2>/dev/null
        echo "@wifi";    printf '%s' "$wifi"
        # Which bridge port each device was last seen on: that is what says
        # wired vs Wi-Fi vs not here at all, independent of DHCP leases that
        # outlive the device by hours.
        echo "@ports";   for ifc in /sys/class/net/br-lan/brif/*; do
                             [ -e "$ifc/port_no" ] && echo "$(printf '%d' "$(cat "$ifc/port_no")") ${ifc##*/}"
                         done
        echo "@fdb";     brctl showmacs br-lan 2>/dev/null
        echo "@nlbw";    nlbw -c csv -g mac -q 2>/dev/null
        echo "@tot";     cat "$A_TOT" 2>/dev/null
        # names people gave at the network sign-in beat DHCP host names
        echo "@guests";  cat /etc/mwadmin/guests 2>/dev/null
    } | awk '
        function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s); return "\"" s "\"" }
        /^@/ { sec = $1; next }
        sec == "@leases" && NF >= 3 { ip = $3; mac[ip] = tolower($2); name[ip] = ($4 == "*" ? "" : $4); next }
        sec == "@arp" && $6 == "br-lan" && $3 != "0x0" { if (!($1 in mac)) mac[$1] = tolower($4); next }
        sec == "@wifi" && NF >= 1 { w[tolower($1)] = ($2 == "" ? "Wi-Fi" : $2 " " $3); next }
        sec == "@ports" { pname[$1] = $2; next }
        sec == "@fdb" { if ($3 == "no" && ($1 in pname)) port[tolower($2)] = pname[$1]; next }
        sec == "@nlbw" {
            gsub(/"/, ""); n = split($0, c, /[\t;,]/)
            if (c[1] ~ /^[0-9a-f:]+$/ && n >= 5) { rx[c[1]] = c[3]; tx[c[1]] = c[5] }
            next
        }
        sec == "@guests" { n = split($0, a, "	"); if (n >= 4) gname[a[1]] = a[4]; next }
        sec == "@tot" { split($0, a, "\t"); ips[a[1]] = 1; ab[a[1] "\t" a[2]] = a[3]; sumb[a[1]] += a[3]; next }
        END {
            for (ip in mac) ips[ip] = 1
            printf "["
            first = 1
            for (ip in ips) {
                m = mac[ip]
                if (m == "" && sumb[ip] == 0) continue
                if (!first) printf ","
                first = 0
                pt = port[m]
                link = ((m in w) || pt ~ /^(phy|wl)/) ? "wifi" : (pt != "" ? "lan" : "offline")
                printf "{\"ip\":%s,\"mac\":%s,\"name\":%s,\"link\":%s,\"band\":%s,\"port\":%s,", q(ip), q(m), q((m in gname) ? gname[m] : name[ip]), q(link), q((m in w) ? w[m] : ""), q(link == "lan" ? pt : "")
                printf "\"down_bytes\":%.0f,\"up_bytes\":%.0f,\"tracked_bytes\":%.0f,\"apps\":[", rx[m] + 0, tx[m] + 0, sumb[ip] + 0
                # top 6 apps for this device
                na = 0
                for (k in ab) { split(k, p, "\t"); if (p[1] == ip) { na++; an[na] = p[2]; av[na] = ab[k] + 0 } }
                for (i = 1; i <= na && i <= 6; i++) {
                    best = i
                    for (j = i + 1; j <= na; j++) if (av[j] > av[best]) best = j
                    t = an[i]; an[i] = an[best]; an[best] = t
                    t = av[i]; av[i] = av[best]; av[best] = t
                    printf "%s{\"app\":%s,\"bytes\":%.0f}", (i > 1 ? "," : ""), q(an[i]), av[i]
                }
                printf "]}"
            }
            printf "]"
        }'
    printf '}\n'
}

api_apps_set() {
    case "$(bodyval enabled)" in
        1|true)  apps_enable;  json_ok "$(jstr message 'App usage tracking is on.')" ;;
        0|false) apps_disable; json_ok "$(jstr message 'App usage tracking is off and its data was cleared.')" ;;
        *)
            if [ "$(bodyval reset)" = "1" ]; then
                rm -f "$A_TOT" "$A_DET" "$A_SNAP" "$A_SINCE"
                json_ok "$(jstr message 'Counters cleared.')"
            else
                json_error "Nothing to change."
            fi ;;
    esac
}

case "${0##*/}" in
    insight.sh)
        case "$1" in
            quality-all) quality_all ;;
            sample)      apps_sample ;;
            enable)      apps_enable ;;
            disable)     apps_disable ;;
        esac
        ;;
esac
