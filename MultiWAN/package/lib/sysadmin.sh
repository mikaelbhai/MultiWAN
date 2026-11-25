# /usr/lib/mwadmin/sysadmin.sh - the LuCI-equivalent system tools, sourced by
# api.sh: SSH keys and settings, services, scheduled tasks and startup script,
# packages, processes, network status, kernel log, restore, factory reset,
# firmware flashing and a raw config-file editor.
# Long-running work (package installs, firmware download) runs as one
# background job at a time; /job reports its progress.

JOB_DIR=/tmp/mwadmin-job
AUTH_KEYS=/etc/dropbear/authorized_keys

# ---------------------------------------------------------------- jobs
job_running() {
    [ -f "$JOB_DIR/pid" ] && kill -0 "$(cat "$JOB_DIR/pid" 2>/dev/null)" 2>/dev/null
}

# job_start "<title>" "<shell command built from validated input only>"
job_start() {
    job_running && { json_error "Another task is still running. Wait for it to finish."; return 1; }
    mkdir -p "$JOB_DIR"
    rm -f "$JOB_DIR/exit"
    printf '%s' "$1" > "$JOB_DIR/title"
    date +%s > "$JOB_DIR/started"
    : > "$JOB_DIR/log"
    setsid sh -c "( $2 ) >>'$JOB_DIR/log' 2>&1; echo \$? > '$JOB_DIR/exit'" </dev/null >/dev/null 2>&1 &
    echo $! > "$JOB_DIR/pid"
    return 0
}

api_job_get() {
    local running=0 exitc=""
    job_running && running=1
    [ -f "$JOB_DIR/exit" ] && exitc=$(cat "$JOB_DIR/exit")
    json_ok "$(printf '%s,%s,%s,%s,%s' \
        "$(jbool running "$running")" \
        "$(jstr title "$(cat "$JOB_DIR/title" 2>/dev/null)")" \
        "$(jnum started "$(cat "$JOB_DIR/started" 2>/dev/null)")" \
        "$(jnum exit_code "$exitc")" \
        "$(jstr log "$(tail -n 150 "$JOB_DIR/log" 2>/dev/null)")")"
}

# ---------------------------------------------------------------- SSH
ssh_key_valid() {
    printf '%s' "$1" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^"]*)?$'
}

ssh_key_count() { grep -cE '^[a-z]' "$AUTH_KEYS" 2>/dev/null || echo 0; }

api_ssh_get() {
    local keys="" n=0 line type body comment
    if [ -f "$AUTH_KEYS" ]; then
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            set -f; set -- $line; set +f
            type="$1"; body="$2"; shift 2 2>/dev/null; comment="$*"
            [ $n -gt 0 ] && keys="$keys,"
            n=$((n + 1))
            keys="$keys{$(jnum index "$n"),$(jstr type "$type"),$(jstr comment "$comment"),$(jstr tail "$(printf '%s' "$body" | tail -c 16)")}"
        done < "$AUTH_KEYS"
    fi
    json_ok "$(printf '"keys":[%s],%s,%s,%s,%s' "$keys" \
        "$(jstr port "$(uget_d dropbear.@dropbear[0].Port 22)")" \
        "$(jbool password_auth "$([ "$(uget_d dropbear.@dropbear[0].PasswordAuth on)" = "on" ] && echo 1)")" \
        "$(jbool root_password_auth "$([ "$(uget_d dropbear.@dropbear[0].RootPasswordAuth on)" = "on" ] && echo 1)")" \
        "$(jstr interface "$(uget dropbear.@dropbear[0].Interface)")")"
}

api_ssh_key_add() {
    local key; key=$(bodyval key | tr -d '\r' | head -n1 | sed 's/^ *//; s/ *$//')
    ssh_key_valid "$key" || { json_error "That does not look like an SSH public key (it should start with ssh-ed25519, ssh-rsa or ecdsa-sha2-...)."; return; }
    local body; body=$(printf '%s' "$key" | awk '{print $2}')
    grep -qF " $body" "$AUTH_KEYS" 2>/dev/null && { json_error "This key is already allowed."; return; }
    mkdir -p /etc/dropbear
    printf '%s\n' "$key" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    log "SSH key added via admin UI"
    json_ok "$(jstr message 'Key added. It can sign in straight away.')"
}

api_ssh_key_del() {
    local idx; idx=$(bodyval index)
    valid_int "$idx" || { json_error "Invalid key."; return; }
    local pw; pw=$(uget_d dropbear.@dropbear[0].PasswordAuth on)
    if [ "$(ssh_key_count)" -le 1 ] && [ "$pw" != "on" ]; then
        json_error "This is the last key and password sign-in is off, so removing it would lock SSH. Turn password sign-in on first."; return
    fi
    awk -v want="$idx" 'BEGIN{n=0} /^[a-z]/{n++; if (n == want) next} {print}' "$AUTH_KEYS" > "$AUTH_KEYS.new" && mv "$AUTH_KEYS.new" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    log "SSH key $idx removed via admin UI"
    json_ok "$(jstr message 'Key removed.')"
}

# Replace the whole list in one go. Empty is allowed only while password
# sign-in is on, so SSH can never be locked out from here.
api_ssh_key_reset() {
    local text tmp="/tmp/mwadmin-keys.$$" line bad=0
    text=$(bodyval keys | tr -d '\r')
    : > "$tmp"
    printf '%s\n' "$text" | while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/^ *//; s/ *$//')
        [ -z "$line" ] && continue
        ssh_key_valid "$line" || { echo BAD > "$tmp.bad"; continue; }
        printf '%s\n' "$line" >> "$tmp"
    done
    if [ -f "$tmp.bad" ]; then rm -f "$tmp" "$tmp.bad"; json_error "One of the lines is not a valid SSH public key. Nothing was changed."; return; fi
    if [ ! -s "$tmp" ] && [ "$(uget_d dropbear.@dropbear[0].PasswordAuth on)" != "on" ]; then
        rm -f "$tmp"; json_error "Password sign-in is off, so an empty key list would lock SSH. Nothing was changed."; return
    fi
    mkdir -p /etc/dropbear
    mv "$tmp" "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
    log "SSH key list replaced via admin UI ($(ssh_key_count) keys)"
    json_ok "$(jstr message "Key list replaced. $(ssh_key_count) key(s) allowed.")"
}

api_ssh_set() {
    local port pw rootpw
    port=$(bodyval port); pw=$(bodyval password_auth); rootpw=$(bodyval root_password_auth)
    valid_port "$port" || { json_error "Port must be 1-65535."; return; }
    case "$pw" in 1|true) pw=on ;; *) pw=off ;; esac
    case "$rootpw" in 1|true) rootpw=on ;; *) rootpw=off ;; esac
    if [ "$pw" = "off" ] && [ "$(ssh_key_count)" -eq 0 ]; then
        json_error "Add at least one SSH key before turning password sign-in off, or you will be locked out of SSH."; return
    fi
    uci set dropbear.@dropbear[0].Port="$port"
    uci set dropbear.@dropbear[0].PasswordAuth="$pw"
    uci set dropbear.@dropbear[0].RootPasswordAuth="$rootpw"
    uci commit dropbear
    ( sleep 1; /etc/init.d/dropbear restart ) >/dev/null 2>&1 &
    log "SSH settings changed: port=$port password=$pw root_password=$rootpw"
    json_ok "$(jstr message "SSH settings saved. SSH now listens on port $port.")"
}

# ---------------------------------------------------------------- services
api_services_get() {
    local out="" n=0 f s en run st
    for f in /etc/init.d/*; do
        [ -x "$f" ] || continue
        s=${f##*/}
        case "$s" in *[!a-zA-Z0-9_.-]*) continue ;; esac
        en=0; "$f" enabled 2>/dev/null && en=1
        run=0; ubus call service list "{\"name\":\"$s\"}" 2>/dev/null | grep -q '"running": true' && run=1
        # START=00 is common; JSON forbids leading zeros, so go through awk's number
        st=$(sed -n 's/^START=\([0-9][0-9]*\).*/\1/p' "$f" | head -n1 | awk '{ print $1 + 0 }')
        [ -z "$st" ] && st=null
        [ $n -gt 0 ] && out="$out,"
        n=$((n + 1))
        out="$out{\"name\":\"$s\",\"enabled\":$([ $en = 1 ] && echo true || echo false),\"running\":$([ $run = 1 ] && echo true || echo false),\"start\":$st}"
    done
    printf '{"ok":true,"services":[%s]}\n' "$out"
}

api_services_action() {
    local s a; s=$(bodyval name); a=$(bodyval action)
    case "$s" in ''|*[!a-zA-Z0-9_.-]*) json_error "Invalid service."; return ;; esac
    [ -x "/etc/init.d/$s" ] || { json_error "No such service."; return; }
    case "$a" in start|stop|restart|reload|enable|disable) ;; *) json_error "Invalid action."; return ;; esac
    log "service $s: $a (admin UI)"
    case "$a" in
        enable|disable) "/etc/init.d/$s" "$a" >/dev/null 2>&1 ;;
        *) ( sleep 1; "/etc/init.d/$s" "$a" ) >/dev/null 2>&1 & ;;
    esac
    json_ok "$(jstr message "$s: $a done.")"
}

# ---------------------------------------------------------------- schedule + startup
api_cron_get() {
    json_ok "$(printf '%s,%s' "$(jstr cron "$(cat /etc/crontabs/root 2>/dev/null)")" "$(jstr rclocal "$(cat /etc/rc.local 2>/dev/null)")")"
}

api_cron_set() {
    local cron rc line
    cron=$(bodyval cron | tr -d '\r'); rc=$(bodyval rclocal | tr -d '\r')
    [ ${#cron} -gt 16384 ] || [ ${#rc} -gt 16384 ] && { json_error "Too long."; return; }
    line=$(printf '%s\n' "$cron" | awk '
        /^[ \t]*$/ || /^[ \t]*#/ { next }
        $1 ~ /^@(reboot|yearly|annually|monthly|weekly|daily|hourly)$/ { if (NF < 2) { print NR; exit } next }
        { if (NF < 6) { print NR; exit }
          for (i = 1; i <= 5; i++) if ($i !~ /^[0-9*\/,-]+$/) { print NR; exit } }')
    [ -n "$line" ] && { json_error "Line $line of the schedule is not valid (minute hour day month weekday command)."; return; }
    if [ -n "$rc" ]; then
        printf '%s\n' "$rc" > /tmp/mwadmin-rc.check
        sh -n /tmp/mwadmin-rc.check 2>/dev/null || { rm -f /tmp/mwadmin-rc.check; json_error "The startup script has a syntax error. Nothing was saved."; return; }
        rm -f /tmp/mwadmin-rc.check
        printf '%s\n' "$rc" > /etc/rc.local
    fi
    mkdir -p /etc/crontabs
    printf '%s\n' "$cron" | sed '/^$/d' > /etc/crontabs/root
    /etc/init.d/cron enable >/dev/null 2>&1
    /etc/init.d/cron restart >/dev/null 2>&1
    log "scheduled tasks / startup script saved via admin UI"
    json_ok "$(jstr message 'Saved. The schedule is active now; the startup script runs at the next boot.')"
}

# ---------------------------------------------------------------- packages
PKG_PROTECTED=" base-files busybox kernel libc dropbear uhttpd uhttpd-mod-ubus rpcd ubus ubusd procd netifd firewall4 nftables-json fstools apk-mbedtls apk-openssl opkg mtd ucode jshn jsonfilter uci dnsmasq odhcpd-ipv6only wpad-basic-mbedtls mwan3 "

pkg_name_valid() { case "$1" in ''|-*|*[!a-z0-9._+-]*) return 1 ;; esac; [ ${#1} -le 64 ]; }

api_packages_get() {
    local q; q=$(qsval q)
    local free; free=$(df -h /overlay 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$q" ]; then
        pkg_name_valid "$q" || { json_error "Search for letters, digits, dot, dash or plus."; return; }
        printf '{"ok":true,"free":"%s","query":"%s","results":[' "$free" "$q"
        apk search "*$q*" 2>/dev/null | head -n 60 | awk '{
            t=$1; n=t; v="";
            if (match(t, /-[0-9][^-]*(-r[0-9]+)?$/)) { n=substr(t,1,RSTART-1); v=substr(t,RSTART+1) }
            gsub(/[^a-zA-Z0-9._+~-]/, "", n); gsub(/[^a-zA-Z0-9._+~-]/, "", v);
            printf "%s{\"name\":\"%s\",\"version\":\"%s\"}", (NR>1?",":""), n, v }'
        printf ']}\n'
        return
    fi
    printf '{"ok":true,"free":"%s","installed":[' "$free"
    apk list -I 2>/dev/null | awk '{
        t=$1; n=t; v=""; up=($0 ~ /upgradable/) ? "true" : "false";
        if (match(t, /-[0-9][^-]*(-r[0-9]+)?$/)) { n=substr(t,1,RSTART-1); v=substr(t,RSTART+1) }
        gsub(/[^a-zA-Z0-9._+~-]/, "", n); gsub(/[^a-zA-Z0-9._+~-]/, "", v);
        printf "%s{\"name\":\"%s\",\"version\":\"%s\",\"upgradable\":%s}", (NR>1?",":""), n, v, up }'
    printf ']}\n'
}

api_packages_action() {
    local a n; a=$(bodyval action); n=$(bodyval name)
    case "$a" in
        install)
            pkg_name_valid "$n" || { json_error "Invalid package name."; return; }
            job_start "Installing $n" "apk update && apk add --no-interactive '$n'" || return ;;
        remove)
            pkg_name_valid "$n" || { json_error "Invalid package name."; return; }
            case "$PKG_PROTECTED" in *" $n "*) json_error "$n is needed by the router itself and cannot be removed here."; return ;; esac
            job_start "Removing $n" "apk del --no-interactive '$n'" || return ;;
        update)
            job_start "Refreshing package lists" "apk update" || return ;;
        upgrade)
            pkg_name_valid "$n" || { json_error "Invalid package name."; return; }
            job_start "Upgrading $n" "apk update && apk add --no-interactive --upgrade '$n'" || return ;;
        *) json_error "Invalid action."; return ;;
    esac
    log "package $a ${n:-} (admin UI)"
    json_ok "$(jstr message 'Started.')"
}

# ---------------------------------------------------------------- processes / status / logs
api_processes_get() {
    json_ok "$(printf '%s,%s,%s' \
        "$(jstr ps "$(ps w 2>/dev/null)")" \
        "$(jstr load "$(cut -d' ' -f1-3 /proc/loadavg)")" \
        "$(jstr mem "$(awk '/^(MemTotal|MemAvailable|Buffers|Cached):/{printf "%s %s\n",$1,$2}' /proc/meminfo)")")"
}

api_processes_kill() {
    local pid sig; pid=$(bodyval pid); sig=$(bodyval signal)
    valid_int "$pid" || { json_error "Invalid process."; return; }
    [ "$pid" -le 1 ] && { json_error "That process cannot be stopped."; return; }
    case "$sig" in TERM|KILL|HUP|INT) ;; *) sig=TERM ;; esac
    kill -"$sig" "$pid" 2>/dev/null || { json_error "Could not signal process $pid (already gone?)."; return; }
    log "process $pid sent SIG$sig (admin UI)"
    json_ok "$(jstr message "Sent $sig to process $pid.")"
}

api_netstatus_get() {
    local dump; dump=$(ubus call network.interface dump 2>/dev/null)
    [ -z "$dump" ] && dump='{"interface":[]}'
    printf '{"ok":true,"interfaces":%s,%s,%s,%s,%s}\n' "$dump" \
        "$(jstr routes "$(ip -4 route show table all 2>/dev/null | grep -v '^local\|^broadcast')")" \
        "$(jstr routes6 "$(ip -6 route 2>/dev/null)")" \
        "$(jstr neigh "$(ip neigh 2>/dev/null)")" \
        "$(jstr conntrack "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)")"
}

api_dmesg() { json_ok "$(jstr log "$(dmesg 2>/dev/null | tail -n 400)")"; }

# ---------------------------------------------------------------- maintenance
api_restore() {
    local data f=/tmp/mwadmin-restore.tar.gz
    data=$(bodyval data)
    [ ${#data} -lt 100 ] && { json_error "No backup file received."; return; }
    printf '%s' "$data" | tr -d ' \r\n' > /tmp/mwadmin-restore.b64
    ucode -e 'import * as fs from "fs"; let d = b64dec(trim(fs.readfile("/tmp/mwadmin-restore.b64"))); if (d == null) exit(1); fs.writefile("/tmp/mwadmin-restore.tar.gz", d);' 2>/dev/null
    local rc=$?; rm -f /tmp/mwadmin-restore.b64
    [ $rc -eq 0 ] && tar tzf "$f" 2>/dev/null | grep -q '^etc/config/' || { rm -f "$f"; json_error "That file is not a router backup (it must be a .tar.gz made by Download backup)."; return; }
    log "configuration restore requested via admin UI"
    ( sleep 2; sysupgrade -r "$f" && reboot ) >/dev/null 2>&1 &
    json_ok "$(jstr message 'Backup accepted. Restoring and rebooting; the router is back in about a minute.')"
}

api_factory_reset() {
    [ "$(bodyval confirm)" = "RESET" ] || { json_error "Type RESET to confirm."; return; }
    log "FACTORY RESET requested via admin UI"
    ( sleep 2; firstboot -y; reboot ) >/dev/null 2>&1 &
    json_ok "$(jstr message 'Erasing all settings and rebooting. The router comes back as a fresh OpenWrt on 192.168.1.1 with no password.')"
}

api_flash_fetch() {
    local url; url=$(bodyval url)
    printf '%s' "$url" | grep -qE '^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$' || { json_error "Enter a full http:// or https:// link to a sysupgrade .bin image."; return; }
    case "$url" in *"'"*|*'"'*|*' '*) json_error "Invalid link."; return ;; esac
    rm -f /tmp/mwadmin-fw.bin /tmp/mwadmin-fw.ok
    job_start "Downloading and checking firmware" \
        "uclient-fetch -O /tmp/mwadmin-fw.bin '$url' && echo 'Checking image...' && sysupgrade -T /tmp/mwadmin-fw.bin && touch /tmp/mwadmin-fw.ok && echo 'IMAGE OK - ready to flash.'" || return
    json_ok "$(jstr message 'Download started.')"
}

api_flash_apply() {
    [ -f /tmp/mwadmin-fw.ok ] && [ -f /tmp/mwadmin-fw.bin ] || { json_error "Download and check an image first."; return; }
    local keep; keep=$(bodyval keep)
    log "FIRMWARE FLASH started via admin UI (keep settings: ${keep:-1})"
    if [ "$keep" = "0" ]; then
        ( sleep 2; sysupgrade -n /tmp/mwadmin-fw.bin ) >/dev/null 2>&1 &
    else
        ( sleep 2; sysupgrade /tmp/mwadmin-fw.bin ) >/dev/null 2>&1 &
    fi
    json_ok "$(jstr message 'Flashing. Do not unplug the router. It reboots by itself in 2-4 minutes.')"
}

# ---------------------------------------------------------------- raw config files
cfg_name_valid() { case "$1" in ''|*[!a-z0-9_-]*) return 1 ;; esac; [ -f "/etc/config/$1" ]; }

api_config_get() {
    local n; n=$(qsval name)
    if [ -z "$n" ]; then
        printf '{"ok":true,"files":[%s]}\n' "$(ls /etc/config 2>/dev/null | grep -E '^[a-z0-9_-]+$' | awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')"
        return
    fi
    cfg_name_valid "$n" || { json_error "No such config file."; return; }
    json_ok "$(printf '%s,%s' "$(jstr name "$n")" "$(jstr text "$(cat "/etc/config/$n")")")"
}

api_config_set() {
    local n text d=/tmp/mwadmin-cfgcheck
    n=$(bodyval name); text=$(bodyval text | tr -d '\r')
    cfg_name_valid "$n" || { json_error "No such config file."; return; }
    [ ${#text} -gt 131072 ] && { json_error "File too large."; return; }
    rm -rf "$d"; mkdir -p "$d"
    printf '%s\n' "$text" > "$d/$n"
    uci -c "$d" show "$n" >/dev/null 2>&1 || { rm -rf "$d"; json_error "That is not valid UCI syntax. Nothing was saved."; return; }
    mkdir -p /tmp/mwadmin-cfgbak
    cp "/etc/config/$n" "/tmp/mwadmin-cfgbak/$n.$(date +%s)"
    cp "$d/$n" "/etc/config/$n"
    rm -rf "$d"
    log "config file $n edited via admin UI"
    ( sleep 1; reload_config ) >/dev/null 2>&1 &
    json_ok "$(jstr message "$n saved and applied. The previous version is kept in /tmp/mwadmin-cfgbak until reboot.")"
}

# ---------------------------------------------------------------- event log + upload
api_events_get() {
    local n; n=$(qsval lines); valid_int "$n" || n=300
    [ "$n" -gt 3000 ] && n=3000
    json_ok "$(printf '%s,%s,%s,%s,%s,%s' \
        "$(jstr log "$(tail -n "$n" /etc/mwadmin/events.log 2>/dev/null)")" \
        "$(jnum total "$(wc -l < /etc/mwadmin/events.log 2>/dev/null)")" \
        "$(jnum uploaded "$(cat /etc/mwadmin/events.sent 2>/dev/null)")" \
        "$(jnum last_push "$(cat /tmp/mwadmin-push.last 2>/dev/null)")" \
        "$(jbool sync_enabled "$(uget_d mwadmin.sync.enabled 1)")" \
        "$(jbool track_sites "$(uget_d mwadmin.sync.track_sites 1)")")"
}

api_sync_set() {
    local en tr; en=$(bodyval enabled); tr=$(bodyval track_sites)
    uci set mwadmin.sync=sync
    [ -n "$en" ] && uci set mwadmin.sync.enabled="$([ "$en" = "1" ] && echo 1 || echo 0)"
    if [ -n "$tr" ]; then
        uci set mwadmin.sync.track_sites="$([ "$tr" = "1" ] && echo 1 || echo 0)"
    fi
    uci commit mwadmin
    if [ "$tr" = "1" ]; then sh -c '. /usr/lib/mwadmin/insight.sh; apps_enable' >/dev/null 2>&1; fi
    if [ "$tr" = "0" ]; then rm -f /tmp/mwadmin-activity.spool; fi
    log "upload settings: enabled=${en:-unchanged} track_sites=${tr:-unchanged}"
    json_ok "$(jstr message 'Saved.')"
}
