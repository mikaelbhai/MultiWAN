#!/bin/sh
# archive.sh - every router's devices, lists and logs, backed up day by day (docs/13).
#
#   Where:  Router 1's USB drive, folder "Baytaar backup/<router name>/<YYYY-MM-DD>/".
#           A router with no drive (Router 2) sends its days to the management website; Router 1 takes them from there
#           and writes them to its drive, then the website copy is deleted. If Router 1's drive is unplugged or full,
#           Router 1 sends its own days to the website the same way, and puts them on the drive when it is back.
#   What:   events.log, line-history.log, devices.tsv (every device seen that day: first and last seen, address, name,
#           Wi-Fi or cable), sign-ins.tsv, access-requests.tsv, free-time.tsv, rules.txt (the shared settings).
#   Router: keeps 3 days (today and the 2 before) of logs, line history and free-time use; older days go once they are
#           backed up. The sign-in list is never trimmed (nobody is forgotten), it is copied every day.
#
#   archive.sh seen    once a minute: today's "devices seen" record (RAM) from the devices list the upload just made
#   archive.sh tick    once an hour: back up today (again) and every day not yet backed up, take in what waits on the
#                      website (main router with a drive), trim old days
#   archive.sh status  JSON for the panel

. /usr/lib/mwadmin/common.sh
. /usr/lib/mwadmin/policy.sh          # pl_get / pl_set / pl_request / pl_build_policy ... (its own commands do not run when sourced)

AR_KEEP=3                              # days kept on the router
AR_SEEN="$MW_RUN/seen"                 # devices seen, one file per day, RAM
AR_PULLED=/etc/mwadmin/archive_pulled  # "router_id day version" already written from the website
AR_DIR="Baytaar backup"
TAB=$(printf '\t')

ar_today() { date +%Y%m%d; }
ar_dash()  { echo "$1" | sed 's/^\(....\)\(..\)\(..\)$/\1-\2-\3/'; }
ar_days_back() { date -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y%m%d; }

# the first USB drive that is mounted, writable and has at least 50 MB free: prints the backup folder
ar_usb() {
    local id rest m free
    [ -s /etc/mwadmin/drives ] || return 1
    while IFS="$TAB" read -r id rest; do
        [ -n "$id" ] || continue
        m="/mnt/mw/$id"
        grep -q " $m " /proc/mounts 2>/dev/null || continue
        free=$(df -k "$m" 2>/dev/null | awk 'NR == 2 { print $4 }')
        [ "${free:-0}" -gt 51200 ] || continue
        mkdir -p "$m/$AR_DIR" 2>/dev/null && : > "$m/$AR_DIR/.write-test" 2>/dev/null && rm -f "$m/$AR_DIR/.write-test" && { echo "$m/$AR_DIR"; return 0; }
    done < /etc/mwadmin/drives
    return 1
}

ar_name() { local n; n=$(pl_get name); [ -n "$n" ] || n=$(uci -q get system.@system[0].hostname); echo "${n:-Router}" | tr -d '/\\:*?"<>|'; }

# ---- devices seen today: mac first last ip host name wifi ------------------------------------------------------------
ar_seen() {
    local cur="$MW_RUN/devices.now" f now
    [ -s "$cur" ] || return 0
    mkdir -p "$AR_SEEN"; f="$AR_SEEN/$(ar_today).tsv"; now=$(date +%s)
    touch "$f"
    awk -F'\t' -v OFS='\t' -v now="$now" '
        FILENAME == ARGV[1] { fi[$1] = $2; la[$1] = $3; ip[$1] = $4; ho[$1] = $5; na[$1] = $6; wi[$1] = $7; next }
        $1 != "" { if (!($1 in fi)) fi[$1] = now; la[$1] = now
                   if ($2 != "") ip[$1] = $2; if ($3 != "") ho[$1] = $3; if ($4 != "") na[$1] = $4; wi[$1] = $5 }
        END { for (m in fi) print m, fi[m], la[m], ip[m], ho[m], na[m], wi[m] }' "$f" "$cur" > "$f.new" && mv "$f.new" "$f"
    # RAM only: drop days the router no longer keeps
    for dir in "$AR_SEEN" "$AR_VIS" "$AR_USE"; do
        ls "$dir" 2>/dev/null | while read -r x; do
            [ "${x%.tsv}" -lt "$(ar_days_back $AR_KEEP)" ] 2>/dev/null && rm -f "$dir/$x"
        done
    done
}

# ---- sites visited and app use, per device and day (RAM), from the activity records the upload sends -----------------
# record: kind <TAB> ts <TAB> mac <TAB> ip <TAB> name <TAB> site-or-app <TAB> bytes     (kind v = visit, u = app use)
AR_VIS="$MW_RUN/visits"; AR_USE="$MW_RUN/usage"
ar_visits() {    # <activity file>
    local f="$1" t d
    [ -s "$f" ] || return 0
    mkdir -p "$AR_VIS" "$AR_USE"; t="$PL_TMP/act.$$"; mkdir -p "$PL_TMP"
    awk -F'\t' -v OFS='\t' '$2 ~ /^[0-9]+$/ && ($1 == "v" || $1 == "u") { print strftime("%Y%m%d", $2), $0 }' "$f" > "$t"
    for d in $(cut -f1 "$t" | sort -u); do
        case "$d" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
        touch "$AR_VIS/$d.tsv" "$AR_USE/$d.tsv"
        # visits: mac site first last times ip name
        awk -F'\t' -v OFS='\t' -v d="$d" '
            FILENAME == ARGV[1] { k = $1 SUBSEP $2; fi[k] = $3; la[k] = $4; n[k] = $5; ip[k] = $6; na[k] = $7; next }
            $1 == d && $2 == "v" && $7 != "" { k = $4 SUBSEP $7; if (!(k in fi) || $3 < fi[k]) fi[k] = $3; if ($3 > la[k]) la[k] = $3; n[k]++
                                               if ($5 != "") ip[k] = $5; if ($6 != "") na[k] = $6 }
            END { for (k in fi) { split(k, p, SUBSEP); print p[1], p[2], fi[k], la[k], n[k], ip[k], na[k] } }' "$AR_VIS/$d.tsv" "$t" > "$AR_VIS/$d.tsv.new" &&
            mv "$AR_VIS/$d.tsv.new" "$AR_VIS/$d.tsv"
        # app use: mac app bytes ip name
        awk -F'\t' -v OFS='\t' -v d="$d" '
            FILENAME == ARGV[1] { k = $1 SUBSEP $2; b[k] = $3; ip[k] = $4; na[k] = $5; next }
            $1 == d && $2 == "u" && $7 != "" { k = $4 SUBSEP $7; b[k] += $8; if ($5 != "") ip[k] = $5; if ($6 != "") na[k] = $6 }
            END { for (k in b) { split(k, p, SUBSEP); print p[1], p[2], b[k], ip[k], na[k] } }' "$AR_USE/$d.tsv" "$t" > "$AR_USE/$d.tsv.new" &&
            mv "$AR_USE/$d.tsv.new" "$AR_USE/$d.tsv"
    done
    rm -f "$t"
}

# ---- one day, as one text bundle -----------------------------------------------------------------------------------
ar_build() {     # <YYYYMMDD>
    local d="$1"
    echo "# baytaar-archive 1 $d"
    echo "@events";   awk -F'|' -v d="$d" '$1 ~ /^[0-9]+$/ && strftime("%Y%m%d", $1) == d' /etc/mwadmin/events.log 2>/dev/null
    echo "@lines";    cat /etc/mwadmin/history/*.log 2>/dev/null | awk -F'|' -v d="$d" '$1 ~ /^[0-9]+$/ && strftime("%Y%m%d", $1) == d'
    echo "@devices";  cat "$AR_SEEN/$d.tsv" 2>/dev/null
    echo "@visits";   cat "$AR_VIS/$d.tsv" 2>/dev/null
    echo "@usage";    cat "$AR_USE/$d.tsv" 2>/dev/null
    echo "@signins";  cat /etc/mwadmin/guests 2>/dev/null
    echo "@requests"; cat /etc/mwadmin/site_requests 2>/dev/null
    echo "@freetime"; awk -F'\t' -v d="$d" '$2 == d' /etc/mwadmin/pause_use 2>/dev/null
    echo "@rules";    pl_build_policy 2>/dev/null | sed '1d;$d' | sed 's/^@/# /'
    echo "@end"
}

# ---- written as readable files on the drive --------------------------------------------------------------------------
ar_write() {     # <backup folder> <router name> <YYYYMMDD> <bundle file>
    local base="$1" name="$2" d="$3" f="$4" dir
    [ "$(head -n1 "$f" | cut -d' ' -f1-3)" = "# baytaar-archive 1" ] && [ "$(tail -n1 "$f")" = "@end" ] || return 1
    dir="$base/$name/$(ar_dash "$d")"
    mkdir -p "$dir" || return 1
    pl_section "$f" events | awk -F'|' -v OFS='  ' '{ m = $4; for (i = 5; i <= NF; i++) m = m "|" $i; print strftime("%Y-%m-%d %H:%M:%S", $1), $2, $3, m }' > "$dir/events.log.tmp" &&
        mv "$dir/events.log.tmp" "$dir/events.log" || return 1
    pl_section "$f" lines | awk -F'|' -v OFS='  ' '{ $1 = strftime("%Y-%m-%d %H:%M:%S", $1); print }' > "$dir/line-history.log.tmp" &&
        mv "$dir/line-history.log.tmp" "$dir/line-history.log" || return 1
    { printf 'mac\tfirst seen\tlast seen\taddress\thost name\tname\tconnection\n'
      pl_section "$f" devices | awk -F'\t' -v OFS='\t' '{ print $1, strftime("%H:%M", $2), strftime("%H:%M", $3), $4, $5, $6, ($7 == 1 ? "Wi-Fi" : "cable") }' | sort -t"$TAB" -k2
    } > "$dir/devices.tsv.tmp" && mv "$dir/devices.tsv.tmp" "$dir/devices.tsv" || return 1
    if grep -qx '@visits' "$f"; then
        { printf 'mac\tsite\tfirst\tlast\ttimes\taddress\tname\n'
          pl_section "$f" visits | awk -F'\t' -v OFS='\t' '{ print $1, $2, strftime("%H:%M", $3), strftime("%H:%M", $4), $5, $6, $7 }' | sort -t"$TAB" -k1,1 -k5,5nr
        } > "$dir/sites-visited.tsv.tmp" && mv "$dir/sites-visited.tsv.tmp" "$dir/sites-visited.tsv" || return 1
        { printf 'mac\tapp\tMB\taddress\tname\n'
          pl_section "$f" usage | awk -F'\t' -v OFS='\t' '{ printf "%s\t%s\t%.1f\t%s\t%s\n", $1, $2, $3 / 1000000, $4, $5 }' | sort -t"$TAB" -k1,1 -k3,3nr
        } > "$dir/app-usage.tsv.tmp" && mv "$dir/app-usage.tsv.tmp" "$dir/app-usage.tsv" || return 1
    fi
    { printf 'mac\tphone\tsigned in\tname\n'
      pl_section "$f" signins | awk -F'\t' -v OFS='\t' '{ $3 = ($3 ~ /^[0-9]+$/ ? strftime("%Y-%m-%d %H:%M", $3) : $3); print }'
    } > "$dir/sign-ins.tsv.tmp" && mv "$dir/sign-ins.tsv.tmp" "$dir/sign-ins.tsv" || return 1
    { printf 'mac\tsite or app\tasked\tdecision\n'
      pl_section "$f" requests | awk -F'\t' -v OFS='\t' '{ $3 = ($3 ~ /^[0-9]+$/ ? strftime("%Y-%m-%d %H:%M", $3) : $3); print }'
    } > "$dir/access-requests.tsv.tmp" && mv "$dir/access-requests.tsv.tmp" "$dir/access-requests.tsv" || return 1
    { printf 'person or group\tday\tseconds used\n'
      pl_section "$f" freetime | awk -F'\t' -v OFS='\t' '{ print $1, $2, $3 }'
    } > "$dir/free-time.tsv.tmp" && mv "$dir/free-time.tsv.tmp" "$dir/free-time.tsv" || return 1
    pl_section "$f" rules > "$dir/rules.txt.tmp" && mv "$dir/rules.txt.tmp" "$dir/rules.txt" || return 1
    grep -q 'sites-visited' "$base/READ ME.txt" 2>/dev/null || printf '%s\r\n' \
        "Baytaar backup: one folder per router, one folder per day." \
        "events.log            what happened (lines, cables, alerts, sign-ins)" \
        "line-history.log      internet lines and access points going up and down" \
        "devices.tsv           every device seen that day: first and last time, address, name, Wi-Fi or cable" \
        "sites-visited.tsv     the sites each device opened that day: first and last time, how many times" \
        "app-usage.tsv         how much each device used each app that day (MB)" \
        "sign-ins.tsv          everyone who has signed in (the whole list, as it was that day)" \
        "access-requests.tsv   requests to open a blocked site, and the decisions" \
        "free-time.tsv         free time used that day" \
        "rules.txt             the shared rules (blocked sites, free time, never-blocked devices)" \
        "The .tsv files open in Excel. Routers keep only the last 3 days themselves." > "$base/READ ME.txt"
    return 0
}

# ---- the website: a router without a drive leaves its days there --------------------------------------------------
ar_upload() {    # <token> <YYYYMMDD> <bundle file>: 0 when the website kept it
    local v code
    v=$(md5sum "$3" | cut -d' ' -f1)
    code=$(pl_request "$1" -X POST --data-binary @"$3" -H 'Content-Type: text/plain' "$(pl_url)?kind=archive&day=$2&version=$v")
    pl_ok "$code" && [ "$(pl_json stored)" = "true" ]
}

# main router with a drive: write what waits on the website (the other routers' days, and own days from when the
# drive was missing), then let the website delete the days that are complete
ar_pull() {      # <backup folder> <token> <today>
    local base="$1" tok="$2" today="$3" code n i rid rname day ver got key
    code=$(pl_request "$tok" "$(pl_url)?archives=1")
    pl_ok "$code" || return 1
    cp "$PL_TMP/resp" "$PL_TMP/ar.list"
    n=$(jsonfilter -i "$PL_TMP/ar.list" -e '@.archives[*].day' 2>/dev/null | wc -l)
    i=0
    while [ "$i" -lt "$n" ]; do
        rid=$(jsonfilter -i "$PL_TMP/ar.list" -e "@.archives[$i].router_id"); rname=$(jsonfilter -i "$PL_TMP/ar.list" -e "@.archives[$i].router" | tr -d '/\\:*?"<>|')
        day=$(jsonfilter -i "$PL_TMP/ar.list" -e "@.archives[$i].day"); ver=$(jsonfilter -i "$PL_TMP/ar.list" -e "@.archives[$i].version")
        i=$((i + 1))
        case "$day" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
        key="$rid $day $ver"
        if ! grep -qxF "$key" "$AR_PULLED" 2>/dev/null; then
            code=$(pl_request "$tok" "$(pl_url)?archive=$rid&day=$day")
            got=$(md5sum "$PL_TMP/resp" 2>/dev/null | cut -d' ' -f1)
            [ "$code" = "200" ] && [ "$got" = "$ver" ] || continue
            ar_write "$base" "${rname:-Router $rid}" "$day" "$PL_TMP/resp" || continue
            { grep -v "^$rid $day " "$AR_PULLED" 2>/dev/null; echo "$key"; } | tail -n 200 > "$AR_PULLED.new" && mv "$AR_PULLED.new" "$AR_PULLED"
        fi
        # a finished day is safe on the drive: the website copy can go
        [ "$day" -lt "$today" ] && pl_request "$tok" -X POST --data-binary '' "$(pl_url)?kind=archive_ack&router=$rid&day=$day" >/dev/null
    done
    rm -f "$PL_TMP/ar.list"
}

# ---- the router keeps only 3 days, and only drops a day once it is backed up -----------------------------------------
ar_trim() {
    local keep through cut
    keep=$(ar_days_back $((AR_KEEP - 1)))           # oldest day kept
    through=$(pl_get archived_through)              # newest day fully backed up
    case "$through" in [0-9]*) ;; *) return 0 ;; esac
    cut=$keep; [ "$through" -lt "$cut" ] && cut=$((through + 1))   # never drop a day that is not backed up yet
    for f in /etc/mwadmin/history/*.log; do
        [ -s "$f" ] || continue
        awk -F'|' -v c="$cut" '!($1 ~ /^[0-9]+$/ && strftime("%Y%m%d", $1) < c)' "$f" > "$f.new"
        cmp -s "$f" "$f.new" && rm -f "$f.new" || mv "$f.new" "$f"
    done
    if [ -s /etc/mwadmin/pause_use ]; then
        awk -F'\t' -v c="$cut" '!($2 ~ /^[0-9]+$/ && $2 < c)' /etc/mwadmin/pause_use > /etc/mwadmin/pause_use.new
        cmp -s /etc/mwadmin/pause_use /etc/mwadmin/pause_use.new && rm -f /etc/mwadmin/pause_use.new || mv /etc/mwadmin/pause_use.new /etc/mwadmin/pause_use
    fi
}

# ---- clutter guard: nothing may fill the router's RAM disk or flash (every 10 minutes, and with every backup) -----------
# Everything that grows already has its own limit or leaves the router (see docs/13); this catches whatever does not:
# leftovers are always cleared, and when /tmp passes 60 % the known caches are emptied and an event says so.
ar_guard() {
    local use freed="" f ov day
    # always: package lists from a software install and stray temporary copies older than a day
    find /tmp/cache/apk -type f -mtime +0 2>/dev/null | while read -r f; do rm -f "$f"; done
    find /tmp -maxdepth 1 -type f \( -name '*.new' -o -name '*.tmp' -o -name 't_*.sh' \) -mtime +0 2>/dev/null | while read -r f; do rm -f "$f"; done
    use=$(df /tmp 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
    if [ "${use:-0}" -ge "$MW_LIM_GUARD" ]; then
        rm -rf /tmp/cache/apk 2>/dev/null && freed="$freed package lists,"
        rm -f /tmp/mwadmin-push.failed.json /tmp/mwadmin-push.failed.resp && freed="$freed failed-upload copies,"
        [ -s /tmp/dnsmasq-queries.log ] && { : > /tmp/dnsmasq-queries.log; freed="$freed DNS query log,"; }
        if [ "$(wc -c < /tmp/mwadmin-activity.spool 2>/dev/null || echo 0)" -gt 500000 ]; then
            tail -c 500000 /tmp/mwadmin-activity.spool > /tmp/mwadmin-activity.spool.t && mv /tmp/mwadmin-activity.spool.t /tmp/mwadmin-activity.spool; freed="$freed old activity records,"
        fi
        f="$MW_RUN/apps.det"; [ -s "$f" ] && { sort -t"$TAB" -k4,4nr "$f" | head -n 1000 > "$f.t" && mv "$f.t" "$f"; freed="$freed app details,"; }
        sh /usr/lib/mwadmin/events.sh add sys warn "Memory disk was ${use}% full; emptied:${freed%,} (now $(df /tmp | awk 'NR == 2 { print $5 }'))" >/dev/null 2>&1
    fi
    # flash: only a warning (nothing big should ever be there), once a day
    ov=$(df /overlay 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }'); day=$(ar_today)
    if [ "${ov:-0}" -ge 80 ] && [ "$(cat "$MW_RUN/flashwarn" 2>/dev/null)" != "$day" ]; then
        echo "$day" > "$MW_RUN/flashwarn"
        sh /usr/lib/mwadmin/events.sh add sys warn "Router storage is ${ov}% full" >/dev/null 2>&1
    fi
    return 0
}

ar_tick() {
    lock_acquire archive || return 0
    ar_guard
    mkdir -p "$PL_TMP"
    local usb today tok name i d last ok where now
    usb=$(ar_usb); today=$(ar_today); now=$(date +%s); name=$(ar_name)
    tok=$(cat /etc/mwadmin/portal_token 2>/dev/null)
    last=$(pl_get archived_through)
    # today (written again every hour) and every day after the last fully backed-up one, at most a week back
    i=7
    while [ "$i" -ge 0 ]; do
        d=$(ar_days_back "$i"); i=$((i - 1))
        [ -n "$last" ] && [ "$d" -le "$last" ] 2>/dev/null && continue
        [ -z "$last" ] && [ "$d" -lt "$(ar_days_back $((AR_KEEP - 1)))" ] && continue
        ar_build "$d" > "$PL_TMP/ar.$d"
        ok=0; where=""
        if [ -n "$usb" ] && ar_write "$usb" "$name" "$d" "$PL_TMP/ar.$d"; then ok=1; where=usb
        elif [ -n "$tok" ] && ar_upload "$tok" "$d" "$PL_TMP/ar.$d"; then ok=1; where=website; fi
        rm -f "$PL_TMP/ar.$d"
        if [ $ok -eq 1 ]; then
            pl_set archive_where "$where"; pl_set archive_at "$now"; pl_set archive_error ""
            [ "$d" -lt "$today" ] && pl_set archived_through "$d"
        else
            pl_set archive_error "day $d could not be backed up (no drive, and the website did not take it)"
            break
        fi
    done
    [ -n "$usb" ] && [ -n "$tok" ] && [ "$(pl_get role)" = "main" ] && ar_pull "$usb" "$tok" "$today"
    ar_trim
    lock_release archive
}

ar_status() {
    local usb; usb=$(ar_usb)
    printf '{%s,%s,%s,%s,%s,%s}\n' \
        "$(jstr drive "${usb:+${usb%/$AR_DIR}}")" \
        "$(jstr where "$(pl_get archive_where)")" \
        "$(jnum at "$(pl_get archive_at)")" \
        "$(jstr through "$(pl_get archived_through)")" \
        "$(jnum keep_days "$AR_KEEP")" \
        "$(jstr error "$(pl_get archive_error)")"
}

case "${0##*/}" in
    archive.sh)
        case "$1" in
            seen)   ar_seen ;;
            visits) ar_visits "$2" ;;
            guard)  ar_guard ;;
            tick)   ar_tick ;;
            status) ar_status ;;
            build)  ar_build "${2:-$(ar_today)}" ;;
        esac ;;
esac
