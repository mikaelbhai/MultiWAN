#!/bin/sh
# events.sh - the router's own event log, and the uploader that copies it
# (plus the site-visit and "using now" records from insight.sh) to the
# website whenever the internet is reachable.
#
#   events.sh watch     long-running: turns system log lines into events
#   events.sh push      one upload attempt (run every minute by the watcher)
#   events.sh add KIND SEVERITY MESSAGE
#
# Events live in flash (/etc/mwadmin/events.log, last 3000 kept), so they
# survive reboots and power cuts and are uploaded once the line is back.
# Format: unix-time|kind|severity|message
#   kind: line (internet line up/down), wire (cable plugged/unplugged),
#         power (router was off / rebooted), error, info

. /usr/lib/mwadmin/common.sh

EV_LOG=/etc/mwadmin/events.log
EV_SENT=/etc/mwadmin/events.sent        # how many lines of EV_LOG are uploaded
EV_BEAT=/etc/mwadmin/heartbeat          # last time the router was known running
ACT_SPOOL=/tmp/mwadmin-activity.spool   # written by insight.sh, emptied on upload
EV_MAX=3000
EV_FAIL=/tmp/mwadmin-push.fail          # first-failure time, tries, last error (while uploads are failing)
EV_LS="$MW_RUN/linestate"               # per line: up | down, so a restart is not reported as an outage

ev_add() { ev_add_at "$(date +%s)" "$@"; }

# Same, stamped with the time something happened (not the time it is written):
# the reason for an outage takes a few seconds to work out.
ev_add_at() {
    local ts="$1"; shift
    local msg; msg=$(printf '%s' "$3" | tr '|\n\r' '/  ' | cut -c1-400)
    mkdir -p /etc/mwadmin
    printf '%s|%s|%s|%s\n' "$ts" "$1" "$2" "$msg" >> "$EV_LOG"
    if [ "$(wc -l < "$EV_LOG")" -gt $((EV_MAX + 300)) ]; then
        local drop=$(( $(wc -l < "$EV_LOG") - EV_MAX ))
        tail -n "$EV_MAX" "$EV_LOG" > "$EV_LOG.tmp" && mv "$EV_LOG.tmp" "$EV_LOG"
        local sent; sent=$(cat "$EV_SENT" 2>/dev/null || echo 0)
        sent=$((sent - drop)); [ "$sent" -lt 0 ] && sent=0
        echo "$sent" > "$EV_SENT"
    fi
}

# System CAs plus the intermediates some servers forget to send.
ev_cacert() {
    local b=/tmp/mwadmin-cabundle.pem
    [ -s "$b" ] || cat /etc/ssl/certs/ca-certificates.crt /usr/lib/mwadmin/le-intermediates.pem > "$b" 2>/dev/null
    [ -s "$b" ] && printf -- '--cacert %s' "$b"
}

# Devices connected to this router right now, as a JSON list for the website:
# [["mac","ip","host name","name",wifi(1/0)], ...]. "Connected" = answering on the LAN (ARP). The name is the
# one this router knows (signed-in name), else the host name the device gave. Wi-Fi = on a radio's station list.
ev_devices_json() {
    local wifi i
    wifi=$( for i in $(ls /sys/class/net 2>/dev/null | grep -E '^phy[0-9]+-ap'); do
                iwinfo "$i" assoclist 2>/dev/null | awk 'toupper($1) ~ /^([0-9A-F][0-9A-F]:){5}[0-9A-F][0-9A-F]$/ { print tolower($1) }'
            done | tr '\n' ' ')
    { echo "@wifi $wifi"; echo "@guests"; cat /etc/mwadmin/guests 2>/dev/null
      echo "@leases"; cat /tmp/dhcp.leases 2>/dev/null; echo "@arp"; cat /proc/net/arp 2>/dev/null; } | awk -v tsv="$MW_RUN/devices.now.new" '
        function clean(s) { gsub(/\\/, "", s); gsub(/"/, "", s); gsub(/[\001-\037]/, "", s); return s }
        /^@wifi/ { n = split($0, a, " "); for (i = 2; i <= n; i++) w[a[i]] = 1; next }
        /^@/ { sec = $1; next }
        sec == "@guests" { n = split($0, g, "\t"); if (n >= 4) gn[g[1]] = g[4]; next }
        sec == "@leases" && NF >= 3 { m = tolower($2); h[m] = ($4 == "*" ? "" : $4); next }
        sec == "@arp" && $6 == "br-lan" && $3 != "0x0" { m = tolower($4); ip[m] = $1; on[m] = 1; next }
        END {
            printf "["
            f = 1
            for (m in on) {
                printf "%s[\"%s\",\"%s\",\"%s\",\"%s\",%d]", (f ? "" : ","), clean(m), clean(ip[m]), clean(h[m]), clean(gn[m]), ((m in w) ? 1 : 0)
                if (tsv != "") printf "%s\t%s\t%s\t%s\t%d\n", clean(m), clean(ip[m]), clean(h[m]), clean(gn[m]), ((m in w) ? 1 : 0) > tsv
                f = 0
            }
            printf "]"
        }'
}

# One upload. Sends unsent events and the activity spool; marks them sent
# only when the website confirms. Quiet when the internet is down.
ev_push() {
    [ "$(uget_d mwadmin.sync.enabled 1)" = "1" ] || return 0
    local url; url=$(uget_d mwadmin.sync.url "https://mikaelbhai.com/router/ingest.php")
    local tok; tok=$(cat /etc/mwadmin/portal_token 2>/dev/null)
    [ -n "$tok" ] || return 0
    lock_acquire evpush || return 0
    local total sent body=/tmp/mwadmin-push.json act=/tmp/mwadmin-push.act
    total=$(wc -l < "$EV_LOG" 2>/dev/null || echo 0)
    sent=$(cat "$EV_SENT" 2>/dev/null || echo 0)
    [ "$sent" -gt "$total" ] && sent=0
    # take the spool atomically, so records written meanwhile go to the next push
    rm -f "$act"; [ -s "$ACT_SPOOL" ] && mv "$ACT_SPOOL" "$act"
    # the sites visited and app use also go into the day's backup (archive.sh), as a per-device summary in RAM
    [ -s "$act" ] && sh /usr/lib/mwadmin/archive.sh visits "$act" >/dev/null 2>&1
    # sent every minute even with nothing new: the upload is also the
    # heartbeat the website uses to tell the phone app the router went silent
    {
        printf '{"token":"%s","now":%s,"events":[' "$tok" "$(date +%s)"
        tail -n +"$((sent + 1))" "$EV_LOG" | head -n 500 | awk -F'|' 'BEGIN{ORS=""} {
            m=$4; for (i=5;i<=NF;i++) m=m "|" $i
            gsub(/\\/,"",m); gsub(/"/,"",m); gsub(/[\001-\037]/," ",m)
            printf "%s[%d,\"%s\",\"%s\",\"%s\"]", (NR>1?",":""), $1, $2, $3, m }'
        printf '],"activity":['
        [ -s "$act" ] && awk -F'\t' 'BEGIN{ORS=""} {
            for (i=1;i<=NF;i++) { gsub(/\\/,"",$i); gsub(/"/,"",$i); gsub(/[\001-\037]/,"",$i) }
            printf "%s[\"%s\",%d,\"%s\",\"%s\",\"%s\",\"%s\",%d]", (NR>1?",":""), $1, $2, $3, $4, $5, $6, $7 }' "$act"
        printf '],"devices":'
        rm -f "$MW_RUN/devices.now.new"; : > "$MW_RUN/devices.now.new"
        ev_devices_json
        mv "$MW_RUN/devices.now.new" "$MW_RUN/devices.now" 2>/dev/null
        printf '}'
    } > "$body"
    local n_ev; n_ev=$(tail -n +"$((sent + 1))" "$EV_LOG" | head -n 500 | wc -l)
    # The normal route first; if that fails, each other online line in turn
    # (netfall.sh). Short timeouts, so one bad minute cannot stall the loop.
    local resp=/tmp/mwadmin-push.resp code
    . /usr/lib/mwadmin/netfall.sh
    curl_any -s -m 15 --connect-timeout 8 $(ev_cacert) -X POST -H 'Content-Type: application/json' \
        --data-binary @"$body" -o "$resp" -w '%{http_code}' "$url" > "$resp.code" 2>/dev/null
    code=$(cat "$resp.code" 2>/dev/null)
    if grep -q '"ok":true' "$resp" 2>/dev/null; then
        echo $((sent + n_ev)) > "$EV_SENT"
        date +%s > /tmp/mwadmin-push.last
        rm -f "$act"
        # Say so when uploads had been failing: this is what tells us, later,
        # whether a "router offline" alert was the router or the path to the website.
        if [ -s "$EV_FAIL" ]; then
            local t1 n1 rc1 via
            read -r t1 n1 rc1 < "$EV_FAIL"
            via=$(cat "$MW_RUN/lastvia" 2>/dev/null)
            ev_add sync warn "Uploads to the website failed for $(( ($(date +%s) - t1) / 60 + 1 )) min ($n1 tries, last error: $rc1); got through again${via:+ via $via}"
            rm -f "$EV_FAIL"
        fi
        ev_prune
    else
        local why; why=$(curl_why "$(cat "$MW_RUN/lastrc" 2>/dev/null)")
        [ "$(cat "$MW_RUN/lastrc" 2>/dev/null)" = "0" ] && why="the website answered HTTP ${code:-?} instead of accepting the upload"
        if [ -s "$EV_FAIL" ]; then
            local t1 n1 rc1; read -r t1 n1 rc1 < "$EV_FAIL"
            echo "$t1 $((n1 + 1)) $why" > "$EV_FAIL"
        else
            echo "$(date +%s) 1 $why" > "$EV_FAIL"
        fi
        # keep the last failed upload and the website's answer, to replay it and find the cause
        cp "$body" /tmp/mwadmin-push.failed.json 2>/dev/null; cp "$resp" /tmp/mwadmin-push.failed.resp 2>/dev/null
        # put the activity back in front of anything written meanwhile, capped at ~2 MB
        [ -s "$act" ] && { cat "$ACT_SPOOL" >> "$act" 2>/dev/null; tail -c 2000000 "$act" > "$ACT_SPOOL"; rm -f "$act"; }
    fi
    rm -f "$resp" "$resp.code"
    rm -f "$body"
    lock_release evpush
}

# Keep only today's events on the router: once the website has confirmed an
# upload, events from earlier days that it already has are deleted (the
# website keeps the full history). Events not yet uploaded are never
# deleted, however old. Runs once a day, right after a confirmed upload.
ev_prune() {
    local today sent mid drop
    today=$(date +%F)
    [ "$(cat /tmp/mwadmin-pruned 2>/dev/null)" = "$today" ] && return 0
    sent=$(cat "$EV_SENT" 2>/dev/null || echo 0)
    valid_int "$sent" || return 0
    # local midnight (router clock is Asia/Karachi), two days back: the router keeps today and the 2 days before
    # (3 days), long enough for the hourly backup (archive.sh) to have put them on the USB drive or the website
    mid=$(( $(date +%s) - $(date '+%H %M %S' | awk '{ print $1 * 3600 + $2 * 60 + $3 }') - 2 * 86400 ))
    drop=$(awk -F'|' -v n="$sent" -v m="$mid" 'NR <= n && $1 < m { c++ } END { print c + 0 }' "$EV_LOG" 2>/dev/null)
    if [ "${drop:-0}" -gt 0 ]; then
        awk -F'|' -v n="$sent" -v m="$mid" '!(NR <= n && $1 < m)' "$EV_LOG" > "$EV_LOG.tmp" &&
            mv "$EV_LOG.tmp" "$EV_LOG" && echo $((sent - drop)) > "$EV_SENT"
        log "event log: removed $drop uploaded entries older than 3 days"
    fi
    echo "$today" > /tmp/mwadmin-pruned
}

# Was the router off? Compare the last heartbeat with this boot.
ev_boot_check() {
    local up boot last
    up=$(awk '{printf "%d", $1}' /proc/uptime)
    boot=$(( $(date +%s) - up ))
    last=$(cat "$EV_BEAT" 2>/dev/null)
    if [ -n "$last" ] && [ "$up" -lt 600 ]; then
        local off=$(( boot - last ))
        [ "$off" -gt 0 ] && ev_add power warn "Router was off or restarting for about $(( off / 60 )) min (last seen $(date -d @"$last" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$last"))"
    fi
    [ "$up" -lt 600 ] && ev_add power info "Router started"
}

# A line changed state, as mwan3 sees it ($1 wanN, $2 offline|online).
#   * "went down" carries the router's own opinion of why (linewhy.sh), worked
#     out in the background and stamped with the moment it went down
#   * "is back" is only written for a line that was really down: mwan3 prints
#     "is online" again every time it restarts (a setting changed, a port
#     switched), and that is not news
ev_line_change() {
    local i="$1" what="$2" f t0 prev
    mkdir -p "$EV_LS"
    # also drop mwan3's sticky memory here (the same as /etc/mwan3.user does): a second chance if that hook is late
    for s in $(ipset list -n 2>/dev/null | grep '^mwan3_rule_'); do ipset flush "$s" 2>/dev/null; done
    f="$EV_LS/$i"; t0=$(date +%s); prev=$(cat "$f" 2>/dev/null)
    case "$what" in
        offline)
            [ "$prev" = "down" ] && return 0
            echo down > "$f"; echo "$t0" > "$f.t"; : > "$f.pending"
            ( why=$(sh /usr/lib/mwadmin/linewhy.sh "$i" 2>/dev/null)
              ev_add_at "$t0" line error "Internet line $i went down${why:+ - reason: $why}"
              rm -f "$f.pending"
              # tell the website now, not at the next once-a-minute upload (a late "down" arrives together with the "up")
              sh /usr/lib/mwadmin/events.sh push >/dev/null 2>&1 ) >/dev/null 2>&1 &
            ;;
        online)
            if [ "$prev" != "down" ]; then echo up > "$f"; return 0; fi
            echo up > "$f"
            ( n=0; while [ -e "$f.pending" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
              d=$(( $(date +%s) - $(cat "$f.t" 2>/dev/null || echo "$t0") ))
              ev_add line info "Internet line $i is back (it was down for about $d s)"
              sh /usr/lib/mwadmin/events.sh push >/dev/null 2>&1 ) >/dev/null 2>&1 &
            ;;
    esac
}

ev_watch() {
    ev_boot_check
    [ "$(uget_d mwadmin.sync.track_sites 1)" = "1" ] && sh -c '. /usr/lib/mwadmin/insight.sh; apps_enable' >/dev/null 2>&1
    # heartbeat + upload, once a minute; heartbeat to flash every 5 minutes
    (
        n=0
        while true; do
            date +%s > /tmp/mwadmin-heartbeat
            [ $((n % 5)) -eq 0 ] && cp /tmp/mwadmin-heartbeat "$EV_BEAT"
            sh /usr/lib/mwadmin/events.sh push >/dev/null 2>&1
            # switches / access points / routers listed under Nodes: down for 2 min = an event
            sh /usr/lib/mwadmin/nodewatch.sh tick >/dev/null 2>&1
            # settings shared between the routers of one location (Router 1 sends, Router 2 follows)
            sh /usr/lib/mwadmin/policy.sh tick >/dev/null 2>&1
            # devices seen today (RAM), and once an hour the daily backup to the USB drive (or the website)
            sh /usr/lib/mwadmin/archive.sh seen >/dev/null 2>&1
            # a second guard on the RAM disk, independent of the minute jobs in site.sh: the DNS query log never above 16 MB
            [ "$(wc -c < /tmp/dnsmasq-queries.log 2>/dev/null || echo 0)" -gt 16000000 ] && { : > /tmp/dnsmasq-queries.log; ev_add sys warn "The DNS query log had grown past 16 MB (site tracking had stopped); emptied it"; }
            [ $((n % 60)) -eq 5 ] && sh /usr/lib/mwadmin/archive.sh tick >/dev/null 2>&1
            # shared USB drives follow devices whose address changed (every 3 min)
            [ $((n % 3)) -eq 1 ] && [ -s /etc/mwadmin/drives ] && sh /usr/lib/mwadmin/drive.sh apply >/dev/null 2>&1
            n=$((n + 1))
            sleep 60
        done
    ) &
    local lastmsg="" lastts=0
    logread -f | while IFS= read -r line; do
        case "$line" in
            *": Link is Up"*|*": Link is Down"*)
                p=$(printf '%s' "$line" | sed -nE 's/.* ([a-z0-9.-]+): Link is (Up|Down).*/\1/p')
                case "$line" in
                    *"Link is Up"*) ev_add wire info "Cable connected on $p ($(printf '%s' "$line" | sed -n 's/.*Link is Up - \([^ ]*\).*/\1/p'))" ;;
                    *) ev_add wire warn "Cable disconnected on $p" ;;
                esac ;;
            *"mwan3track"*" is offline"*|*"mwan3track"*" is online"*)
                w=$(printf '%s' "$line" | sed -nE 's/.*Interface (wan[0-9]).* is (offline|online).*/\1 \2/p')
                [ -n "$w" ] && ev_line_change "${w% *}" "${w#* }" ;;
            *"procd: - shutdown -"*|*"procd: - reboot -"*)
                ev_add power warn "Router is restarting"
                cp /tmp/mwadmin-heartbeat "$EV_BEAT" 2>/dev/null ;;
            *".err "*|*".crit "*|*".alert "*|*".emerg "*)
                # skip our own noise and repeat lines within 10 minutes
                case "$line" in *"mwadmin"*|*"Warning: Permanently added"*) continue ;; esac
                msg=$(printf '%s' "$line" | cut -d' ' -f6- | cut -c1-240)
                key=$(printf '%s' "$msg" | sed 's/\[[0-9]*\]//g')
                now=$(date +%s)
                if [ "$key" != "$lastmsg" ] || [ $((now - lastts)) -gt 600 ]; then
                    ev_add error error "$msg"
                    lastmsg="$key"; lastts=$now
                fi ;;
        esac
    done
}

case "$1" in
    watch) ev_watch ;;
    push)  ev_push ;;
    add)   ev_add "$2" "$3" "$4" ;;
esac
