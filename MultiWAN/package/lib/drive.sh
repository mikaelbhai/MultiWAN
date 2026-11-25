#!/bin/sh
# drive.sh - USB drives shared on the home network, one access list per drive.
#
# Every drive plugged into a USB port is mounted under /mnt/mw/<id> and shared
# as \\<router>\<drive name> (Windows file sharing, ksmbd). On the panel's
# Drives page each device is Off, View (open and copy files) or Add (also add,
# change and delete files) for each drive. A device that joins the network
# later starts Off. A Google Wifi / mesh point counts as one device, so
# switching it on lets everything behind it in.
#
# How that is enforced (tested on this router, Nov 2026):
#   * the firewall lets only devices that are switched on for some drive
#     reach file sharing at all (ksmbd's own "hosts allow" is ignored by this
#     build, so it is not relied on)
#   * each such device gets its own login; a drive opens only for the logins
#     listed on it ("valid users"), and only "Add" logins may change it
#     ("write list"). No guest access.
#   * or, with the password switched off on the Drives page, no login at all:
#     then the firewall gate is the only check, and every switched-on device
#     gets the most any device has on that drive (Add if anyone has Add).
#
# Drives are remembered by their own ID (or name + size), so the list follows
# a drive to whichever USB port it is plugged into next time.
#
#   drive.sh apply     mount what is plugged in, write the share list and the
#                      firewall gate, start or stop file sharing
#                      (hotplug, boot, and every few minutes for new addresses)
#   drive.sh boot      the same, after switching off block-mount's own mounting

. /usr/lib/mwadmin/common.sh

DR_F=/etc/mwadmin/drives               # id <TAB> name <TAB> mac=view|add,...
DR_U=/etc/mwadmin/drive_users          # mac <TAB> login <TAB> password
DR_MNT=/mnt/mw
DR_RUN=/tmp/mwadmin/drive
DR_CONF=/etc/ksmbd/ksmbd.conf
DR_NFT=/etc/nftables.d/22-mwdrive.nft
DR_OPEN=/etc/mwadmin/drive_nopassword  # present: drives open without a password

dr_mac_ok() { printf '%s' "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }

# ---- what is plugged in ---------------------------------------------------
# One line per usable partition:
#   dev <TAB> id <TAB> type <TAB> label <TAB> bytes <TAB> port <TAB> speed <TAB> model
dr_scan() {
    local disk part dev info type label uuid bytes path seg port speed model id
    for disk in /sys/block/sd*; do
        [ -e "$disk" ] || continue
        path=$(readlink -f "$disk")
        seg=$(printf '%s\n' "$path" | tr '/' '\n' | grep -E '^[0-9]+-[0-9.]+$' | tail -n1)
        port=${seg#*-}
        speed=$(cat "/sys/bus/usb/devices/$seg/speed" 2>/dev/null)
        model=$(printf '%s %s' "$(cat "$disk/device/vendor" 2>/dev/null)" "$(cat "$disk/device/model" 2>/dev/null)" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')
        for part in "$disk"/sd* ; do
            [ -e "$part" ] || part="$disk"
            dev=/dev/${part##*/}
            info=$(block info "$dev" 2>/dev/null)
            type=$(printf '%s' "$info" | sed -n 's/.* TYPE="\([^"]*\)".*/\1/p')
            label=$(printf '%s' "$info" | sed -n 's/.* LABEL="\([^"]*\)".*/\1/p')
            uuid=$(printf '%s' "$info" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p')
            bytes=$(( $(cat "$part/size" 2>/dev/null || echo 0) * 512 ))
            case "$type" in
                vfat|exfat|ntfs|ntfs3|hfsplus|ext2|ext3|ext4) ;;
                *) [ "$part" = "$disk" ] && break; continue ;;
            esac
            # the hidden start-up partition Macs and PCs put on a disk
            if [ "$type" = "vfat" ] && [ "$bytes" -lt 600000000 ]; then
                case "$label" in EFI|efi|ESP|SYSTEM|"") [ "$part" = "$disk" ] && break; continue ;; esac
            fi
            if [ -n "$uuid" ]; then id=$(printf '%s' "$uuid" | tr -cd 'A-Za-z0-9' | cut -c1-24)
            else id=$(printf '%s|%s|%s' "$label" "$type" "$bytes" | md5sum | cut -c1-12); fi
            [ -n "$label" ] || label="USB drive $(( bytes / 1000000000 )) GB"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dev" "d$id" "$type" "$label" "$bytes" "$port" "$speed" "$model"
            [ "$part" = "$disk" ] && break
        done
    done
}

dr_list() { grep -v '^#' "$DR_F" 2>/dev/null | awk -F'\t' 'NF >= 2'; }

# "mac level" lines for one drive (a bare mac from an older list means view)
dr_allow() {
    dr_list | awk -F'\t' -v i="$1" '$1 == i { print $3; exit }' | tr ',' '\n' | \
        awk -F'=' '$1 ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/ && length($1) == 17 { print $1, ($2 == "add") ? "add" : "view" }'
}

# Remember a drive the first time it is seen (nobody allowed yet).
dr_remember() {
    mkdir -p /etc/mwadmin; touch "$DR_F"
    dr_list | awk -F'\t' -v i="$1" '$1 == i { f = 1 } END { exit !f }' && return 0
    printf '%s\t%s\t\n' "$1" "$(printf '%s' "$2" | tr -d '\t\r\n')" >> "$DR_F"
}

dr_set_allow() {   # id mac=level,...
    dr_list | awk -F'\t' -v OFS='\t' -v i="$1" -v m="$2" '$1 == i { $3 = m } { print $1, $2, $3 }' > "$DR_F.new"
    mv "$DR_F.new" "$DR_F"
}

# ---- logins ---------------------------------------------------------------
dr_user() { awk -F'\t' -v m="$1" '$1 == m { print $2; exit }' "$DR_U" 2>/dev/null; }

# A device's name: its reservation, else the name it gave for its lease.
dr_name() {
    local s n=""
    s=$(uci -q show dhcp | grep -i "\.mac='*$1'*$" | sed -n 's/^dhcp\.\([^.]*\)\.mac=.*/\1/p' | head -n1)
    [ -n "$s" ] && n=$(uci -q get "dhcp.$s.name")
    [ -n "$n" ] || n=$(awk -v m="$1" 'tolower($2) == m && $4 != "*" { print $4; exit }' /tmp/dhcp.leases 2>/dev/null)
    printf '%s' "$n"
}

# Give a device its own login the first time it is switched on for a drive.
dr_user_make() {   # mac name
    local u base n=1
    u=$(dr_user "$1"); [ -n "$u" ] && return 0
    base=$(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-20)
    [ -n "$base" ] || base=device
    case "$base" in [0-9]*) base="d$base" ;; esac
    u=$base
    while awk -F'\t' -v u="$u" '$2 == u { f = 1 } END { exit !f }' "$DR_U" 2>/dev/null; do n=$((n + 1)); u="$base$n"; done
    mkdir -p /etc/mwadmin; touch "$DR_U"; chmod 600 "$DR_U"
    printf '%s\t%s\t%s\n' "$1" "$u" "$(head -c 300 /dev/urandom | tr -dc 'a-km-np-z2-9' | cut -c1-10)" >> "$DR_U"
}

# Macs that may open at least one drive.
dr_all_macs() { dr_list | cut -f3 | tr ',' '\n' | cut -d= -f1 | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u; }

# The sharing service's own password list holds exactly the logins in use.
dr_sync_users() {
    local want mac u p have
    want=$(for mac in $(dr_all_macs); do awk -F'\t' -v m="$mac" '$1 == m { print $2 "\t" $3; exit }' "$DR_U"; done | sort)
    [ "$(printf '%s' "$want" | md5sum)" = "$(cat "$DR_RUN/users.sum" 2>/dev/null)" ] && [ -s /etc/ksmbd/ksmbdpwd.db ] && return 0
    # take away logins that are no longer switched on anywhere
    for have in $(cut -d: -f1 /etc/ksmbd/ksmbdpwd.db 2>/dev/null); do
        printf '%s\n' "$want" | cut -f1 | grep -qxF "$have" || ksmbd.adduser -C "$1" -d "$have" >/dev/null 2>&1
    done
    printf '%s\n' "$want" | while IFS='	' read -r u p; do
        [ -n "$u" ] || continue
        ksmbd.adduser -C "$1" -a "$u" -p "$p" >/dev/null 2>&1 || ksmbd.adduser -C "$1" -u "$u" -p "$p" >/dev/null 2>&1
    done
    printf '%s' "$want" | md5sum > "$DR_RUN/users.sum"
}

# ---- mounting --------------------------------------------------------------
dr_mounted_dev() { awk -v m="$1" '$2 == m { print $1; exit }' /proc/mounts; }

dr_mount() {   # dev id type
    local mp="$DR_MNT/$2" have
    have=$(dr_mounted_dev "$mp")
    [ "$have" = "$1" ] && return 0
    [ -n "$have" ] && umount -l "$mp" 2>/dev/null
    [ -f "$DR_RUN/ejected-$2" ] && return 1
    mkdir -p "$mp"
    case "$3" in
        # Mac disks: Linux can't safely write to a journaled HFS+ disk, so
        # these are always view-and-copy only
        hfsplus) mount -t hfsplus -o ro,nls=utf8 "$1" "$mp" ;;
        exfat)   mount -t exfat -o rw,noatime,umask=0 "$1" "$mp" || mount -t exfat -o ro "$1" "$mp" ;;
        ntfs|ntfs3) mount -t ntfs3 -o rw,noatime,umask=0 "$1" "$mp" || mount -t ntfs3 -o ro "$1" "$mp" ;;
        vfat)    mount -t vfat -o rw,noatime,umask=0,utf8 "$1" "$mp" || mount -t vfat -o ro "$1" "$mp" ;;
        *)       mount -o rw,noatime "$1" "$mp" || mount -o ro "$1" "$mp" ;;
    esac 2>/dev/null
}

# Drives that were pulled out: drop their mount points.
dr_tidy() {
    local mp dev f
    for mp in "$DR_MNT"/*; do
        [ -d "$mp" ] || continue
        dev=$(dr_mounted_dev "$mp")
        if [ -n "$dev" ] && [ -b "$dev" ]; then continue; fi
        [ -n "$dev" ] && umount -l "$mp" 2>/dev/null
        rmdir "$mp" 2>/dev/null
    done
    # an ejected drive can be used again once it has been unplugged
    for f in "$DR_RUN"/ejected-*; do
        [ -f "$f" ] || continue
        awk -F'\t' -v i="${f##*ejected-}" '$2 == i { f = 1 } END { exit !f }' "$DR_RUN/scan" 2>/dev/null || rm -f "$f"
    done
}

dr_readonly() { awk -v m="$1" '$2 == m { split($4, o, ","); print (o[1] == "ro") ? 1 : 0; exit }' /proc/mounts; }

# ---- the firewall gate -------------------------------------------------------
# Every address a device is using now: its reservation, its lease, and any
# IPv4/IPv6 address the router has just seen it on.
dr_ips() {
    local mac="$1" s
    for s in $(uci -q show dhcp | grep -i "\.mac='*$mac'*$" | sed -n 's/^dhcp\.\([^.]*\)\.mac=.*/\1/p'); do
        uci -q get "dhcp.$s.ip"
    done
    awk -v m="$mac" 'tolower($2) == m { print $3 }' /tmp/dhcp.leases 2>/dev/null
    ip neigh show 2>/dev/null | awk -v m="$mac" 'index(tolower($0), m) && $0 !~ /FAILED|INCOMPLETE/ && $1 !~ /^fe80/ { print $1 }'
}

dr_gate() {   # macs...
    local mac v4="" v6="" a
    for mac in "$@"; do
        for a in $(dr_ips "$mac"); do
            case "$a" in
                *:*) printf '%s' "$a" | grep -qE '^[0-9a-fA-F:]+$' && v6="$v6 $a" ;;
                *)   printf '%s' "$a" | grep -qE '^[0-9.]+$' && v4="$v4 $a" ;;
            esac
        done
    done
    v4=$(printf '%s\n' $v4 | grep . | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    v6=$(printf '%s\n' $v6 | grep . | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    {
        echo "# written by /usr/lib/mwadmin/drive.sh: only devices switched on for a drive reach file sharing"
        if [ -n "$v4" ]; then echo "set mw_drive4 { type ipv4_addr; elements = { $v4 }; }"; else echo "set mw_drive4 { type ipv4_addr; }"; fi
        if [ -n "$v6" ]; then echo "set mw_drive6 { type ipv6_addr; elements = { $v6 }; }"; else echo "set mw_drive6 { type ipv6_addr; }"; fi
        echo "chain mw_drive_in {"
        echo "    type filter hook input priority filter - 5; policy accept;"
        echo "    iifname \"lo\" accept"
        echo "    tcp dport { 139, 445 } ip saddr @mw_drive4 accept"
        echo "    tcp dport { 139, 445 } ip6 saddr @mw_drive6 accept"
        echo "    tcp dport { 139, 445 } reject with tcp reset"
        echo "    udp dport { 137, 138 } drop"
        echo "}"
    } > "$DR_NFT.new"
    if cmp -s "$DR_NFT.new" "$DR_NFT" && nft list chain inet fw4 mw_drive_in >/dev/null 2>&1; then
        rm -f "$DR_NFT.new"
    else
        mv "$DR_NFT.new" "$DR_NFT"
        fw4 -q reload >/dev/null 2>&1
    fi
}

# ---- the share list --------------------------------------------------------
dr_share_name() { printf '%s' "$1" | tr -d '[]{};%?=#"\\/:<>*|+,' | cut -c1-40; }

dr_write_conf() {
    local out="$1" any=0 dev id type label bytes port speed model mp mac lvl ro name names="" users adders u open=0
    [ -f "$DR_OPEN" ] && open=1
    : > "$out.shares"
    : > "$DR_RUN/gate"
    while IFS='	' read -r dev id type label bytes port speed model; do
        mp="$DR_MNT/$id"
        [ -n "$dev" ] && [ "$(dr_mounted_dev "$mp")" = "$dev" ] || continue
        ro=$(dr_readonly "$mp")
        users=""; adders=""
        while read -r mac lvl; do
            [ -n "$mac" ] || continue
            u=$(dr_user "$mac"); [ -n "$u" ] || continue
            users="$users $u"
            [ "$lvl" = "add" ] && adders="$adders $u"
            echo "$mac" >> "$DR_RUN/gate"
        done <<EOF
$(dr_allow "$id")
EOF
        [ -n "$users" ] || continue
        name=$(dr_share_name "$label"); [ -n "$name" ] || name=$id
        case "|$names|" in *"|$name|"*) name="$name $port" ;; esac
        names="$names|$name"
        {
            printf '\n[%s]\n' "$name"
            printf '\tpath = %s\n' "$mp"
            printf '\tcomment = %s\n' "$(printf '%s, USB port %s' "${model:-USB drive}" "$port" | tr -d '\n')"
            printf '\tbrowseable = yes\n'
            if [ "$open" = "1" ]; then
                # no password: the firewall gate alone decides who gets in, and
                # everyone let in gets the most this drive allows anybody
                printf '\tguest ok = yes\n'
                if [ "$ro" != "1" ] && [ -n "$adders" ]; then printf '\tread only = no\n\twriteable = yes\n'
                else printf '\tread only = yes\n'; fi
            else
                printf '\tguest ok = no\n'
                printf '\tvalid users =%s\n' "$users"
                printf '\tread only = yes\n'
                [ "$ro" != "1" ] && [ -n "$adders" ] && printf '\twrite list =%s\n' "$adders"
            fi
            printf '\tforce user = root\n\tforce group = root\n'
            printf '\tcreate mask = 0666\n\tdirectory mask = 0777\n'
            # Windows attributes and "streams" live in extended attributes;
            # Linux's Mac-disk driver answers those with I/O errors, and a
            # read-only drive can't store them anyway
            printf '\tstore dos attributes = no\n'
            printf '\toplocks = yes\n'
            printf '\thide dot files = yes\n'
            # Mac and Windows housekeeping, not anybody's files
            printf '\tveto files = /.DS_Store/.Trashes/.Spotlight-V100/.fseventsd/.TemporaryItems/.DocumentRevisions-V100/.journal/.journal_info_block/.com.apple.timemachine.donotpresent/$RECYCLE.BIN/System Volume Information/\n'
        } >> "$out.shares"
        any=1
    done < "$DR_RUN/scan"
    {
        printf '[global]\n'
        printf '\tnetbios name = %s\n' "$(sed 's/\..*//' /proc/sys/kernel/hostname | tr -cd 'A-Za-z0-9-' | cut -c1-15)"
        printf '\tserver string = Baytaar router\n'
        printf '\tworkgroup = WORKGROUP\n'
        printf '\tinterfaces = br-lan\n'
        printf '\tbind interfaces only = yes\n'
        printf '\tipc timeout = 20\n'
        printf '\tdeadtime = 15\n'
        if [ "$open" = "1" ]; then printf '\tmap to guest = Bad User\n\tguest account = nobody\n'
        else printf '\tmap to guest = Never\n'; fi
        printf '\tserver signing = auto\n'
        printf '\tsmb2 max read = 1M\n\tsmb2 max write = 1M\n\tsmb2 max trans = 1M\n'
        cat "$out.shares"
    } > "$out"
    rm -f "$out.shares"
    return $((1 - any))
}

dr_sharing() { pidof ksmbd.mountd >/dev/null 2>&1; }

dr_apply() {
    command -v ksmbd.mountd >/dev/null 2>&1 || return 0
    mkdir -p "$DR_RUN" "$DR_MNT" /etc/ksmbd
    lock "$DR_RUN/lock"
    dr_scan > "$DR_RUN/scan.new"; mv "$DR_RUN/scan.new" "$DR_RUN/scan"
    dr_tidy
    local dev id type label bytes port speed model
    while IFS='	' read -r dev id type label bytes port speed model; do
        [ -n "$dev" ] || continue
        dr_remember "$id" "$label"
        dr_mount "$dev" "$id" "$type"
    done < "$DR_RUN/scan"
    # every switched-on device has a login (lists written before logins existed)
    local mac
    for mac in $(dr_all_macs); do
        [ -n "$(dr_user "$mac")" ] || dr_user_make "$mac" "$(dr_name "$mac")"
    done
    if dr_write_conf "$DR_RUN/ksmbd.conf"; then
        dr_gate $(sort -u "$DR_RUN/gate")
        [ -L "$DR_CONF" ] && rm -f "$DR_CONF"
        dr_sync_users "$DR_RUN/ksmbd.conf"
        if ! cmp -s "$DR_RUN/ksmbd.conf" "$DR_CONF" || ! dr_sharing || [ "$(cat "$DR_RUN/users.sum")" != "$(cat "$DR_RUN/users.live" 2>/dev/null)" ]; then
            cp "$DR_RUN/ksmbd.conf" "$DR_CONF"
            /etc/init.d/ksmbd restart >/dev/null 2>&1
            cp "$DR_RUN/users.sum" "$DR_RUN/users.live"
            log "drive sharing: share list updated"
        fi
    else
        dr_gate
        if dr_sharing || [ -s "$DR_CONF" ]; then
            # nothing is switched on for anybody: no sharing at all
            /etc/init.d/ksmbd stop >/dev/null 2>&1
            rm -f "$DR_CONF"
            log "drive sharing: off (no drive is switched on for any device)"
        fi
    fi
    lock -u "$DR_RUN/lock"
}

dr_boot() {
    # drives are mounted here (read-only for Mac disks), not by block-mount
    if [ "$(uci -q get fstab.@global[0].auto_mount)" != "0" ] || [ "$(uci -q get fstab.@global[0].anon_mount)" != "0" ]; then
        uci -q set fstab.@global[0].auto_mount=0
        uci -q set fstab.@global[0].anon_mount=0
        uci -q commit fstab
    fi
    /etc/init.d/ksmbd disable >/dev/null 2>&1
    rm -f "$DR_RUN/users.sum" "$DR_RUN/users.live"
    # the shared login from the first version is gone: every device has its own
    rm -f /etc/mwadmin/drive_pass
    dr_apply
}

# ---- panel API ---------------------------------------------------------------
api_drives_get() {
    mkdir -p "$DR_RUN"
    [ -f "$DR_RUN/scan" ] || dr_scan > "$DR_RUN/scan"
    local out="" first=1 id name macs row dev type label bytes port speed model mp used free ro present mounted ej al f2 m lv logins="" lf=1 u p
    local lanip; lanip=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
    while IFS='	' read -r id name macs; do
        [ -n "$id" ] || continue
        row=$(awk -F'\t' -v i="$id" '$2 == i { print; exit }' "$DR_RUN/scan")
        present=0; mounted=0; used=""; free=""; ro=0; type=""; bytes=""; port=""; speed=""; model=""; ej=0
        if [ -n "$row" ]; then
            present=1
            IFS='	' read -r dev _i type label bytes port speed model <<EOF
$row
EOF
            mp="$DR_MNT/$id"
            if [ "$(dr_mounted_dev "$mp")" = "$dev" ]; then
                mounted=1
                ro=$(dr_readonly "$mp")
                set -- $(df -k "$mp" 2>/dev/null | awk 'NR == 2 { print $3, $4 }')
                used=$(( ${1:-0} * 1024 )); free=$(( ${2:-0} * 1024 ))
            fi
            [ -f "$DR_RUN/ejected-$id" ] && ej=1
        fi
        al=""; f2=1
        while read -r m lv; do
            [ -n "$m" ] || continue
            [ $f2 -eq 0 ] && al="$al,"; f2=0; al="$al{$(jstr mac "$m"),$(jstr level "$lv")}"
        done <<EOF
$(dr_allow "$id")
EOF
        [ $first -eq 0 ] && out="$out,"; first=0
        out="$out{$(jstr id "$id"),$(jstr name "$name"),$(jstr share "$(dr_share_name "$name")"),$(jbool present $present),$(jbool mounted $mounted),$(jbool ejected $ej),$(jbool readonly "$ro"),$(jstr type "$type"),$(jnum bytes "$bytes"),$(jnum used "$used"),$(jnum free "$free"),$(jstr port "$port"),$(jnum speed "$speed"),$(jstr model "$model"),\"allow\":[$al]}"
    done <<EOF
$(dr_list)
EOF
    for m in $(dr_all_macs); do
        u=$(awk -F'\t' -v m="$m" '$1 == m { print $2; exit }' "$DR_U" 2>/dev/null)
        p=$(awk -F'\t' -v m="$m" '$1 == m { print $3; exit }' "$DR_U" 2>/dev/null)
        [ -n "$u" ] || continue
        [ $lf -eq 0 ] && logins="$logins,"; lf=0
        logins="$logins{$(jstr mac "$m"),$(jstr user "$u"),$(jstr pass "$p")}"
    done
    local inst=0; command -v ksmbd.mountd >/dev/null 2>&1 && inst=1
    printf '{"ok":true,%s,%s,%s,%s,%s,"logins":[%s],"drives":[%s]}\n' "$(jbool installed $inst)" "$(jbool sharing "$(dr_sharing && echo 1)")" \
        "$(jbool password "$([ -f "$DR_OPEN" ] || echo 1)")" \
        "$(jstr address "$lanip")" "$(jstr host "$(sed 's/\..*//' /proc/sys/kernel/hostname)")" "$logins" "$out"
}

api_drives_access() {
    local id mac lvl name cur
    id=$(bodyval id | tr -cd 'A-Za-z0-9'); mac=$(bodyval mac | tr 'A-F' 'a-f'); lvl=$(bodyval level); name=$(bodyval name | tr -d '\t\r\n' | cut -c1-40)
    dr_list | awk -F'\t' -v i="$id" '$1 == i { f = 1 } END { exit !f }' || { json_error "That drive is not known."; return; }
    dr_mac_ok "$mac" || { json_error "Choose a device."; return; }
    case "$lvl" in view|add|off) ;; *) json_error "Choose Off, View or Add."; return ;; esac
    cur=$(dr_allow "$id" | awk -v m="$mac" '$1 != m { print $1 "=" $2 }')
    [ "$lvl" = "off" ] || { cur=$(printf '%s\n%s=%s\n' "$cur" "$mac" "$lvl"); dr_user_make "$mac" "$name"; }
    dr_set_allow "$id" "$(printf '%s\n' $cur | grep . | sort -u | tr '\n' ',' | sed 's/,$//')"
    dr_apply
    log "drive $id: $mac ($name) set to $lvl"
    case "$lvl" in
        add)  json_ok "$(jstr message "${name:-The device} can open this drive and add files to it now.")" ;;
        view) json_ok "$(jstr message "${name:-The device} can open this drive and copy files from it, but not change it.")" ;;
        *)    json_ok "$(jstr message "${name:-The device} can no longer open this drive.")" ;;
    esac
}

api_drives_password() {
    case "$(bodyval required)" in
        1|true) rm -f "$DR_OPEN"; log "drive sharing: password required"
                dr_apply; json_ok "$(jstr message 'Each device now needs its own name and password to open a drive.')" ;;
        0|false) mkdir -p /etc/mwadmin; touch "$DR_OPEN"; log "drive sharing: no password"
                dr_apply; json_ok "$(jstr message 'Drives open without a password now, for switched-on devices only.')" ;;
        *) json_error "Choose on or off." ;;
    esac
}

api_drives_eject() {
    local id mp; id=$(bodyval id | tr -cd 'A-Za-z0-9'); mp="$DR_MNT/$id"
    [ -n "$id" ] && [ -n "$(dr_mounted_dev "$mp")" ] || { json_error "That drive is not in use."; return; }
    mkdir -p "$DR_RUN"; touch "$DR_RUN/ejected-$id"
    dr_apply                       # takes its share away first
    sync
    if umount "$mp" 2>/dev/null || { /etc/init.d/ksmbd stop >/dev/null 2>&1; umount "$mp" 2>/dev/null && dr_apply; }; then
        rmdir "$mp" 2>/dev/null
        log "drive $id: ejected"
        json_ok "$(jstr message 'Safe to unplug now. Plug it back in to use it again.')"
    else
        rm -f "$DR_RUN/ejected-$id"; dr_apply
        json_error "The drive is still busy. Close any open files on it and try again."
    fi
}

api_drives_forget() {
    local id; id=$(bodyval id | tr -cd 'A-Za-z0-9')
    [ -f "$DR_RUN/scan" ] && awk -F'\t' -v i="$id" '$2 == i { f = 1 } END { exit !f }' "$DR_RUN/scan" && { json_error "Unplug the drive first."; return; }
    dr_list | awk -F'\t' -v OFS='\t' -v i="$id" '$1 != i { print $1, $2, $3 }' > "$DR_F.new"; mv "$DR_F.new" "$DR_F"
    dr_apply
    json_ok "$(jstr message 'Forgotten.')"
}

case "${0##*/}" in
    drive.sh)
        case "$1" in
            apply) dr_apply ;;
            boot)  dr_boot ;;
        esac ;;
esac
