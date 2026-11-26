#!/bin/sh
# policy.sh - one settings system for the two routers of a location (docs/08 section 5, docs/12).
#
#   Router 1 (main) is the BRAIN: it holds the settings and makes every decision.
#   Router 2 (branch) ENFORCES them and REPORTS what it sees, so Router 1 can decide with the whole picture.
#
#   Down  (Router 1 -> Router 2), the "policy": blocked sites and apps, free-time groups and settings,
#         never-blocked devices, the sign-in list, the access requests WITH Router 1's decisions, today's free-time use.
#   Up    (Router 2 -> Router 1), the "report": the sign-ins and access requests made on Router 2, and its free-time use.
#         Router 1 merges them into its own files, so its panel shows everyone, and the policy it sends back down contains them.
#
# Not shared, ever: Wi-Fi name and password, addresses, DHCP, ports, line setup, passwords, keys and tokens.
# Everything goes through the management website, which knows each router's role; a router is never told its role
# by hand. Once a minute, "policy.sh tick" (called from the mwevents watcher) asks the website and does what the role needs.
# Bundles are plain text with a checksum; a damaged or unknown-format bundle is refused whole, never half-applied.

. /usr/lib/mwadmin/common.sh

PL_STATE=/etc/mwadmin/policy_state       # key<space>value lines, flash, rewritten only when a value changes
PL_TMP="$MW_RUN/policy"
MAC_RE='^([0-9a-f]{2}:){5}[0-9a-f]{2}$'

pl_get() { sed -n "s/^$1 //p" "$PL_STATE" 2>/dev/null | head -n1; }
pl_set() {
    [ "$(pl_get "$1")" = "$2" ] && return 0
    { grep -v "^$1 " "$PL_STATE" 2>/dev/null; printf '%s %s\n' "$1" "$2"; } > "$PL_STATE.new" && mv "$PL_STATE.new" "$PL_STATE"
}
pl_num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

pl_url() { uget_d mwadmin.sync.policy_url "https://mikaelbhai.com/router/policy.php"; }
pl_cacert() {
    local b=/tmp/mwadmin-cabundle.pem
    [ -s "$b" ] || cat /etc/ssl/certs/ca-certificates.crt /usr/lib/mwadmin/le-intermediates.pem > "$b" 2>/dev/null
    [ -s "$b" ] && printf -- '--cacert %s' "$b"
}

# section <file> <name>: the lines between "@name" and the next "@..." (every such section in the file)
pl_section() { awk -v s="@$2" '/^@/ { on = ($0 == s); next } on' "$1"; }
pl_today() { date +%Y%m%d; }


# per-device internet speed limits: mac <TAB> name <TAB> down Mbit/s <TAB> up Mbit/s <TAB> on(1/0)
pl_limits_text() {
    local sec
    for sec in $(uci show mwadmin 2>/dev/null | sed -n 's/^mwadmin\.\(lim_[a-z0-9_]*\)=devlimit$/\1/p'); do
        printf '%s	%s	%s	%s	%s
' "$(uget mwadmin.$sec.mac)" "$(uget mwadmin.$sec.name)" "$(uget_d mwadmin.$sec.down_mbit 0)" "$(uget_d mwadmin.$sec.up_mbit 0)" "$(uget_d mwadmin.$sec.enabled 1)"
    done | sort
}

# ---- the bundles -------------------------------------------------------------------------------------------------
pl_build_policy() {
    echo "# baytaar-policy 2"
    echo "@blocked_sites"; grep -E '^[a-z0-9][a-z0-9.-]*$' /etc/mwadmin/blocked_sites 2>/dev/null | sort -u
    echo "@groups";        grep -v '^$' /etc/mwadmin/groups 2>/dev/null | sort
    echo "@exempt";        grep -v '^$' /etc/mwadmin/exempt_devices 2>/dev/null | sort
    echo "@guests";        grep -v '^$' /etc/mwadmin/guests 2>/dev/null | sort
    echo "@requests";      grep -v '^$' /etc/mwadmin/site_requests 2>/dev/null | sort
    echo "@use";           awk -F'\t' -v d="$(pl_today)" '$2 == d' /etc/mwadmin/pause_use 2>/dev/null | sort
    echo "@limits";        pl_limits_text
    echo "@settings";      echo "guest_enabled=$(uget_d mwadmin.guest.enabled 1)"
    echo "@pause"
    echo "allow_min=$(uget_d mwadmin.pause.allow_min 60)"
    echo "break_from=$(uget mwadmin.pause.break_from)"
    echo "break_to=$(uget mwadmin.pause.break_to)"
    echo "@end"
}

pl_build_report() {
    echo "# baytaar-report 1"
    echo "@guests";   grep -v '^$' /etc/mwadmin/guests 2>/dev/null | sort
    echo "@requests"; grep -v '^$' /etc/mwadmin/site_requests 2>/dev/null | sort
    echo "@use";      awk -F'\t' -v d="$(pl_today)" '$2 == d' /etc/mwadmin/pause_use 2>/dev/null | sort
    echo "@end"
}

pl_check_file() {    # <file> <first line>
    [ "$(head -n1 "$1")" = "$2" ] || { pl_set last_error "unknown bundle format; not applied"; return 1; }
    [ "$(tail -n1 "$1")" = "@end" ] || { pl_set last_error "bundle cut short; not applied"; return 1; }
    [ "$(wc -c < "$1")" -lt 400000 ] || { pl_set last_error "bundle too large; not applied"; return 1; }
    return 0
}

# ---- merge rules shared by both directions ------------------------------------------------------------------------
# free-time use: for each (owner, day) the larger number of seconds wins; the "running" flag stays local
pl_merge_use() {     # <rows file, "owner day used_s ...">
    local f="$1"; touch /etc/mwadmin/pause_use
    [ -s "$f" ] || return 1
    awk -F'\t' -v OFS='\t' -v d="$(pl_today)" '
        FILENAME == ARGV[1] { if ($2 == d && $1 != "" && $3 ~ /^[0-9]+$/) { if (!(($1) in up) || $3 + 0 > up[$1] + 0) up[$1] = $3 + 0 } next }
        { if ($2 == d && ($1 in up) && up[$1] + 0 > $3 + 0) { $3 = up[$1] } if ($2 == d) seen[$1] = 1; print }
        END { for (o in up) if (!(o in seen)) print o, d, up[o], 0, 0 }' "$f" /etc/mwadmin/pause_use > "$PL_TMP/use.new"
    # awk read $f first only for the "up" table: the second file is the local one
    cmp -s "$PL_TMP/use.new" /etc/mwadmin/pause_use && return 1
    cp "$PL_TMP/use.new" /etc/mwadmin/pause_use; return 0
}

# ---- Router 1: take in what Router 2 reported -----------------------------------------------------------------------
pl_merge_reports() {     # <reports file: every branch's report, concatenated>
    local f="$1" d="$PL_TMP/merge" gm n=0 newmax
    rm -rf "$d"; mkdir -p "$d"; touch /etc/mwadmin/guests /etc/mwadmin/site_requests

    # sign-ins: a person who signed in on Router 2 is added (never one already here, never an old one that was removed here)
    pl_section "$f" guests | awk -F'\t' -v re="$MAC_RE" '$1 ~ re && NF >= 3' > "$d/g.up"
    gm=$(pl_num "$(pl_get guest_merge_epoch)")
    awk -F'\t' -v gm="$gm" 'FILENAME == ARGV[1] { have[$1] = 1; next } !($1 in have) && ($3 + 0) > gm' /etc/mwadmin/guests "$d/g.up" > "$d/g.add"
    if [ -s "$d/g.add" ]; then
        cat "$d/g.add" >> /etc/mwadmin/guests; n=$((n + 1))
        sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/guest.sh; guest_apply' >/dev/null 2>&1
    fi
    newmax=$(awk -F'\t' -v gm="$gm" '{ if ($3 + 0 > gm) gm = $3 + 0 } END { print gm }' "$d/g.up")
    pl_set guest_merge_epoch "$newmax"

    # access requests: new ones are added as they are (pending); a request Router 1 already knows keeps Router 1's decision
    pl_section "$f" requests | awk -F'\t' -v re="$MAC_RE" '$1 ~ re && NF >= 4 && $4 ~ /^(pending|approved|denied)$/' > "$d/r.up"
    # only NEW pending requests: newer than the newest one merged before, so a request removed here is not brought back
    # by Router 2 still listing it (found in the first real test: a removed request came back as pending)
    local rm; rm=$(pl_num "$(pl_get request_merge_epoch)")
    awk -F'\t' -v OFS='\t' -v rm="$rm" 'FILENAME == ARGV[1] { have[$1 "\t" $2] = 1; next }
        !(($1 "\t" $2) in have) && $4 == "pending" && ($3 + 0) > rm { print $1, $2, $3, "pending" }' \
        /etc/mwadmin/site_requests "$d/r.up" > "$d/r.add"
    pl_set request_merge_epoch "$(awk -F'\t' -v rm="$rm" '$4 == "pending" { if ($3 + 0 > rm) rm = $3 + 0 } END { print rm }' "$d/r.up")"
    # only for sites that are on the block list here
    awk -F'\t' 'FILENAME == ARGV[1] { s[$1] = 1; next } ($2 in s)' /etc/mwadmin/blocked_sites "$d/r.add" > "$d/r.add2"
    if [ -s "$d/r.add2" ]; then
        cat "$d/r.add2" >> /etc/mwadmin/site_requests
        tail -n 400 /etc/mwadmin/site_requests > "$d/r.cap" && cp "$d/r.cap" /etc/mwadmin/site_requests
        chmod 600 /etc/mwadmin/site_requests; n=$((n + 1))
    fi

    # free-time use
    pl_section "$f" use > "$d/u.up"
    pl_merge_use "$d/u.up" && n=$((n + 1))
    log "Router 2 report merged ($n kinds of change)"
    rm -rf "$d"
}

# ---- Router 2: take in Router 1's policy -------------------------------------------------------------------------------
pl_apply_policy() {      # <bundle file>
    local f="$1" d="$PL_TMP/apply" ch_block=0 ch_groups=0 ch_ex=0 ch_g=0 ch_p=0 ch_r=0 ch_l=0 now
    pl_check_file "$f" "# baytaar-policy 2" || return 1
    now=$(date +%s); rm -rf "$d"; mkdir -p "$d"
    touch /etc/mwadmin/guests /etc/mwadmin/site_requests /etc/mwadmin/groups /etc/mwadmin/exempt_devices /etc/mwadmin/blocked_sites

    # blocked sites and apps: a domain or an app id, nothing else; Router 1's list is the list
    pl_section "$f" blocked_sites | grep -E '^[a-z0-9][a-z0-9.-]*$' | sort -u > "$d/blocked"
    sort -u /etc/mwadmin/blocked_sites > "$d/blocked.local"
    cmp -s "$d/blocked" "$d/blocked.local" || { cp "$d/blocked" /etc/mwadmin/blocked_sites; ch_block=1; }

    # free-time groups: id <TAB> name <TAB> mac,mac,...
    pl_section "$f" groups | awk -F'\t' 'NF == 3 && $1 ~ /^[A-Za-z0-9_-]+$/ && $3 ~ /^([0-9a-f:]|,)*$/' | sort > "$d/groups"
    grep -v '^$' /etc/mwadmin/groups | sort > "$d/groups.local"
    cmp -s "$d/groups" "$d/groups.local" || { cp "$d/groups" /etc/mwadmin/groups; ch_groups=1; }

    # never-blocked devices: mac <TAB> name
    pl_section "$f" exempt | awk -F'\t' -v re="$MAC_RE" '$1 ~ re' | sort > "$d/exempt"
    grep -v '^$' /etc/mwadmin/exempt_devices | sort > "$d/exempt.local"
    cmp -s "$d/exempt" "$d/exempt.local" || { cp "$d/exempt" /etc/mwadmin/exempt_devices; ch_ex=1; }

    # sign-in list: Router 1's list, plus anyone who signed in here in the last 10 minutes (Router 1 has not seen them yet)
    pl_section "$f" guests | awk -F'\t' -v re="$MAC_RE" '$1 ~ re && NF >= 3' > "$d/g.master"
    awk -F'\t' -v now="$now" 'FILENAME == ARGV[1] { have[$1] = 1; next } !($1 in have) && ($3 + 0) > now - 600' "$d/g.master" /etc/mwadmin/guests > "$d/g.keep"
    sort "$d/g.master" "$d/g.keep" > "$d/g.new"
    sort /etc/mwadmin/guests | grep -v '^$' > "$d/g.local"
    cmp -s "$d/g.new" "$d/g.local" || { cp "$d/g.new" /etc/mwadmin/guests; ch_g=1; }

    # access requests: Router 1's table (its decisions), plus pending ones made here in the last 10 minutes
    pl_section "$f" requests | awk -F'\t' -v re="$MAC_RE" '$1 ~ re && NF >= 4 && $4 ~ /^(pending|approved|denied)$/' > "$d/r.master"
    awk -F'\t' -v now="$now" 'FILENAME == ARGV[1] { have[$1 "\t" $2] = 1; next } !(($1 "\t" $2) in have) && $4 == "pending" && ($3 + 0) > now - 600' "$d/r.master" /etc/mwadmin/site_requests > "$d/r.keep"
    sort "$d/r.master" "$d/r.keep" > "$d/r.new"
    sort /etc/mwadmin/site_requests | grep -v '^$' > "$d/r.local"
    cmp -s "$d/r.new" "$d/r.local" || { cp "$d/r.new" /etc/mwadmin/site_requests; chmod 600 /etc/mwadmin/site_requests; ch_r=1; }

    # free-time use: the larger number wins
    pl_section "$f" use > "$d/u.master"
    pl_merge_use "$d/u.master" && ch_p=1

    # free-time settings
    local a bf bt
    a=$(pl_section "$f" pause | sed -n 's/^allow_min=//p'); bf=$(pl_section "$f" pause | sed -n 's/^break_from=//p'); bt=$(pl_section "$f" pause | sed -n 's/^break_to=//p')
    case "$a" in ''|*[!0-9]*) a="" ;; esac
    if [ -n "$a" ] && [ "$a" -le 1440 ]; then
        [ "$(uget mwadmin.pause)" = "pause" ] || uci set mwadmin.pause='pause'
        if [ "$(uget mwadmin.pause.allow_min)" != "$a" ] || [ "$(uget mwadmin.pause.break_from)" != "$bf" ] || [ "$(uget mwadmin.pause.break_to)" != "$bt" ]; then
            uci set mwadmin.pause.allow_min="$a"; uci set mwadmin.pause.break_from="$bf"; uci set mwadmin.pause.break_to="$bt"
            uci commit mwadmin; ch_p=1
        fi
    fi

    # device speed limits (only when the bundle has the section, so an older Router 1 cannot wipe them)
    if grep -qx '@limits' "$f"; then
        pl_section "$f" limits | awk -F'	' -v re="$MAC_RE" '$1 ~ re && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $3 + 0 <= 1000 && $4 + 0 <= 1000 && $5 ~ /^[01]$/ { gsub(/[^a-zA-Z0-9_ .-]/, "", $2); print $1 "	" $2 "	" $3 "	" $4 "	" $5 }' | sort > "$d/limits"
        pl_limits_text > "$d/limits.local"
        if ! cmp -s "$d/limits" "$d/limits.local"; then
            local sec lm ln ld lu le
            for sec in $(uci show mwadmin 2>/dev/null | sed -n 's/^mwadmin\.\(lim_[a-z0-9_]*\)=devlimit$/\1/p'); do uci -q delete "mwadmin.$sec"; done
            while IFS="$(printf '	')" read -r lm ln ld lu le; do
                [ -n "$lm" ] || continue
                sec="lim_$(echo "$lm" | tr -d ':')"
                uci set "mwadmin.$sec=devlimit"; uci set "mwadmin.$sec.mac=$lm"
                [ -n "$ln" ] && uci set "mwadmin.$sec.name=$ln"
                uci set "mwadmin.$sec.down_mbit=$ld"; uci set "mwadmin.$sec.up_mbit=$lu"; uci set "mwadmin.$sec.enabled=$le"
            done < "$d/limits"
            uci commit mwadmin; ch_l=1
        fi
    fi

    # sign-in on or off
    local ge; ge=$(pl_section "$f" settings | sed -n 's/^guest_enabled=//p')
    case "$ge" in 0|1) if [ "$(uget_d mwadmin.guest.enabled 1)" != "$ge" ]; then
        [ "$(uget mwadmin.guest)" = "guest" ] || uci set mwadmin.guest='guest'
        uci set mwadmin.guest.enabled="$ge"; uci commit mwadmin; ch_g=1; fi ;; esac

    # put what changed to work, with the same functions the panel uses
    if [ $ch_ex -eq 1 ]; then
        sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/allow.sh; ex_apply' >/dev/null 2>&1       # also redoes sites and sign-in
    else
        if [ $ch_block -eq 1 ] || [ $ch_r -eq 1 ]; then sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/block.sh; block_apply' >/dev/null 2>&1; fi
        [ $ch_g -eq 1 ] && sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/guest.sh; guest_apply' >/dev/null 2>&1
    fi
    if [ $ch_groups -eq 1 ] || [ $ch_p -eq 1 ]; then
        sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/block.sh; pause_tick' >/dev/null 2>&1
    fi
    [ $ch_l -eq 1 ] && sh /usr/lib/mwadmin/devlimit.sh apply >/dev/null 2>&1
    [ $((ch_block + ch_groups + ch_ex + ch_g + ch_p + ch_r + ch_l)) -gt 0 ] && log "Router 1 settings applied (sites $ch_block, groups $ch_groups, never-blocked $ch_ex, sign-in $ch_g, requests $ch_r, free time $ch_p, speed limits $ch_l)"
    rm -rf "$d"
    return 0
}

# ---- talking to the website -----------------------------------------------------------------------------------------
pl_request() {   # <token> <curl args...>: prints the HTTP code; the answer is in $PL_TMP/resp
    local tok="$1"; shift
    . /usr/lib/mwadmin/netfall.sh
    curl_any -s -m 25 --connect-timeout 8 $(pl_cacert) -H "X-Router-Token: $tok" -o "$PL_TMP/resp" -w '%{http_code}' "$@" 2>/dev/null
}
pl_ok() { [ "$1" = "200" ] && grep -q '"ok":true' "$PL_TMP/resp" 2>/dev/null; }
pl_json() { jsonfilter -i "$PL_TMP/resp" -e "@.$1" 2>/dev/null; }

pl_push() {      # <token> <now> <kind: policy|report>
    local tok="$1" now="$2" kind="$3" v pv pat code
    "pl_build_$kind" > "$PL_TMP/out"
    v=$(md5sum "$PL_TMP/out" | cut -d' ' -f1)
    if [ "$kind" = "policy" ]; then pv=$(pl_get pushed_version); pat=$(pl_num "$(pl_get pushed_at)")
    else pv=$(pl_get report_pushed_version); pat=$(pl_num "$(pl_get report_pushed_at)"); fi
    [ "$v" = "$pv" ] && [ $((now - pat)) -lt 3600 ] && return 0
    code=$(pl_request "$tok" -X POST --data-binary @"$PL_TMP/out" -H 'Content-Type: text/plain' "$(pl_url)?kind=$kind&version=$v")
    if pl_ok "$code" && [ "$(pl_json stored)" = "true" ]; then
        if [ "$kind" = "policy" ]; then pl_set pushed_version "$v"; pl_set pushed_at "$now"
        else pl_set report_pushed_version "$v"; pl_set report_pushed_at "$now"; fi
        pl_set last_error ""
    else
        pl_set last_error "the website did not take the $kind (answer ${code:-none})"
    fi
}

pl_tick() {
    [ "$(uget_d mwadmin.sync.enabled 1)" = "1" ] || return 0
    local tok now last role code ver newer rver rnewer got have rhave
    tok=$(cat /etc/mwadmin/portal_token 2>/dev/null); [ -n "$tok" ] || return 0
    now=$(date +%s)
    role=$(pl_get role)
    last=$(pl_num "$(cat "$MW_RUN/policy.last" 2>/dev/null)")
    # a router that is not part of any location asks only every 15 minutes
    if [ -z "$role" ] || [ "$role" = "none" ]; then [ $((now - last)) -ge 900 ] || return 0; fi
    lock_acquire plsync || return 0
    mkdir -p "$PL_TMP"; echo "$now" > "$MW_RUN/policy.last"

    have=$(pl_get applied_version); rhave=$(pl_get reports_applied)
    code=$(pl_request "$tok" "$(pl_url)?have=${have:-none}&rhave=${rhave:-none}")
    if ! pl_ok "$code"; then pl_set last_error "the website answered ${code:-nothing} to the check"; rm -f "$PL_TMP/resp"; lock_release plsync; return 0; fi
    role=$(pl_json role); ver=$(pl_json version); newer=$(pl_json newer); rver=$(pl_json reports_version); rnewer=$(pl_json reports_newer)
    pl_set role "${role:-none}"; pl_set checked_at "$now"

    case "$role" in
        main)
            # 1. what Router 2 reported comes in
            if [ "$rnewer" = "true" ] && [ -n "$rver" ]; then
                code=$(pl_request "$tok" "$(pl_url)?body=reports")
                got=$(md5sum "$PL_TMP/resp" 2>/dev/null | cut -d' ' -f1)
                if [ "$code" = "200" ] && [ "$got" = "$rver" ]; then
                    cp "$PL_TMP/resp" "$PL_TMP/reports.in"; pl_merge_reports "$PL_TMP/reports.in" && pl_set reports_applied "$rver"; pl_set reports_applied_at "$now"; rm -f "$PL_TMP/reports.in"
                else pl_set last_error "the reports did not match their checksum; nothing merged"; fi
            fi
            # 2. the settings go out
            pl_push "$tok" "$now" policy ;;
        branch)
            # 1. Router 1's settings come in
            if [ "$newer" = "true" ] && [ -n "$ver" ]; then
                code=$(pl_request "$tok" "$(pl_url)?body=policy")
                got=$(md5sum "$PL_TMP/resp" 2>/dev/null | cut -d' ' -f1)
                if [ "$code" = "200" ] && [ "$got" = "$ver" ]; then
                    cp "$PL_TMP/resp" "$PL_TMP/policy.in"
                    if pl_apply_policy "$PL_TMP/policy.in"; then
                        pl_set applied_version "$ver"; pl_set applied_at "$now"; pl_set last_error ""
                        cp "$PL_TMP/policy.in" /etc/mwadmin/policy_last      # kept, to apply again (below)
                    fi
                    rm -f "$PL_TMP/policy.in"
                else pl_set last_error "the download did not match its checksum; nothing applied"; fi
            elif [ -s /etc/mwadmin/policy_last ] && [ $((now - $(pl_num "$(cat "$MW_RUN/policy.reapply" 2>/dev/null)"))) -ge 300 ]; then
                # every 5 minutes the last settings are applied again: what was kept only for a while (requests and
                # sign-ins made here in the last 10 minutes) then follows Router 1. Nothing changes if nothing differs.
                echo "$now" > "$MW_RUN/policy.reapply"
                pl_apply_policy /etc/mwadmin/policy_last >/dev/null 2>&1
            fi
            # 2. what this router sees goes up
            pl_push "$tok" "$now" report ;;
    esac
    rm -f "$PL_TMP/resp" "$PL_TMP/out"
    lock_release plsync
}

pl_status() {
    printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(jstr role "$(pl_get role)")" \
        "$(jstr mode "$(cat /etc/mwadmin/mode 2>/dev/null)")" \
        "$(jstr applied_version "$(pl_get applied_version)")" \
        "$(jnum applied_at "$(pl_get applied_at)")" \
        "$(jstr pushed_version "$(pl_get pushed_version)")" \
        "$(jnum pushed_at "$(pl_get pushed_at)")" \
        "$(jnum report_pushed_at "$(pl_get report_pushed_at)")" \
        "$(jnum reports_applied_at "$(pl_get reports_applied_at)")" \
        "$(jnum checked_at "$(pl_get checked_at)")" \
        "$(jstr last_error "$(pl_get last_error)")"
}

case "${0##*/}" in
    policy.sh)
        mkdir -p "$PL_TMP"
        case "$1" in
            tick)         pl_tick ;;
            status)       pl_status ;;
            build)        pl_build_policy ;;
            report)       pl_build_report ;;
            apply)        pl_apply_policy "$2" ;;       # tests: apply a policy file by hand
            merge)        pl_merge_reports "$2" ;;      # tests: merge a reports file by hand
        esac ;;
esac
