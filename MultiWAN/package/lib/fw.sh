#!/bin/sh
# fw.sh — "Upgrade" button: bring this router's Baytaar software up to the
# newest build published on the management website.
#
# The website serves <base>/baytaar-fw.tar.gz: every script and page of the
# router software, plus apply.sh which puts them in place. Which build to
# install, and its SHA-256, arrive with the Upgrade request itself, which
# comes through the router's authenticated link to the website. The download
# is then checked against that checksum, so a tampered or damaged file is
# refused no matter how it was fetched. It is unpacked to RAM and apply.sh is
# run. Settings, the guest list and the block list are not touched. This
# upgrades the Baytaar software, not the OpenWrt system underneath it.
#
# Sourced by api.sh (/fw endpoints); "fw.sh run" does the actual upgrade.

. /usr/lib/mwadmin/common.sh

FW_DIR="$MW_RUN/fw"
FW_STATE="$FW_DIR/state"            # running|ok|failed <TAB> epoch <TAB> message
FW_VERFILE=/etc/mwadmin/fw_version

fw_base()    { uget_d mwadmin.fw.url "https://mikaelbhai.com/router/fw"; }
fw_current() { cat "$FW_VERFILE" 2>/dev/null || echo "unknown"; }

fw_state() { mkdir -p "$FW_DIR"; printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "$2" > "$FW_STATE"; }

fw_run() {       # <version> <sha256>
    local want="$1" sum="$2" got
    mkdir -p "$FW_DIR"
    lock_acquire fw || exit 0
    fw_state running "Downloading version $want."
    rm -rf "$FW_DIR/new" "$FW_DIR/fw.tar.gz"
    # -k: the file is trusted by its checksum, not by the web server's certificate
    if ! curl -kfsS -m 120 -o "$FW_DIR/fw.tar.gz" "$(fw_base)/baytaar-fw.tar.gz" 2>/dev/null; then
        fw_state failed "The download failed. Nothing was changed."; lock_release fw; exit 1
    fi
    got=$(sha256sum "$FW_DIR/fw.tar.gz" | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then
        rm -f "$FW_DIR/fw.tar.gz"
        fw_state failed "The download did not match its checksum. Nothing was changed."; lock_release fw; exit 1
    fi
    mkdir -p "$FW_DIR/new"
    if ! tar -xzf "$FW_DIR/fw.tar.gz" -C "$FW_DIR/new" 2>/dev/null || [ ! -f "$FW_DIR/new/apply.sh" ]; then
        fw_state failed "The package could not be unpacked. Nothing was changed."; lock_release fw; exit 1
    fi
    fw_state running "Installing version $want."
    if ( cd "$FW_DIR/new" && sh ./apply.sh "$want" ) >"$FW_DIR/apply.log" 2>&1; then
        fw_state ok "Now running version $want."
        log "software upgraded to $want"
    else
        fw_state failed "Installing failed part way. Press Upgrade again."
        log "software upgrade to $want FAILED"
    fi
    rm -rf "$FW_DIR/new" "$FW_DIR/fw.tar.gz"
    lock_release fw
}

api_software_get() {
    local st ts msg
    if [ -s "$FW_STATE" ]; then
        IFS='	' read -r st ts msg < "$FW_STATE"
    fi
    # a run that died without finishing must not look "running" for ever
    if [ "$st" = "running" ] && [ ! -d "$MW_RUN/locks/fw.lock" ]; then st="failed"; msg="The upgrade stopped unexpectedly. Press Upgrade again."; fi
    json_ok "$(jstr current "$(fw_current)"),$(jstr state "${st:-idle}"),$(jnum state_ts "$ts"),$(jstr message "$msg"),$(jstr system "$(. /etc/openwrt_release 2>/dev/null; echo "OpenWrt $DISTRIB_RELEASE")")"
}

# The router's own panel asks "is there a newer build?" directly. Unlike an
# upgrade started from the website, nothing vouches for the checksum here, so
# this request verifies the website's certificate properly (no -k).
api_software_check() {
    local b=/tmp/mwadmin-cabundle.pem j ver sum notes cur
    [ -s "$b" ] || cat /etc/ssl/certs/ca-certificates.crt /usr/lib/mwadmin/le-intermediates.pem > "$b" 2>/dev/null
    j=$(curl -fsS -m 15 --cacert "$b" "$(fw_base)/version.json?t=$(date +%s)" 2>/dev/null)
    [ -n "$j" ] || { json_error "Could not reach $(fw_base) to check for updates."; return; }
    ver=$(printf '%s' "$j" | jsonfilter -e '@.version' 2>/dev/null)
    sum=$(printf '%s' "$j" | jsonfilter -e '@.sha256' 2>/dev/null)
    notes=$(printf '%s' "$j" | jsonfilter -e '@.notes' 2>/dev/null)
    case "$ver" in ''|*[!0-9.]*) json_error "The update server sent no valid version."; return ;; esac
    cur=$(fw_current)
    # versions end in YYYYMMDDHHMM; only a NEWER build counts as an update
    local newer=0
    [ "$cur" = "unknown" ] && newer=1
    [ "$cur" != "unknown" ] && [ "$(printf '%s\n%s\n' "$cur" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n1)" = "$ver" ] && [ "$ver" != "$cur" ] && newer=1
    json_ok "$(jstr current "$cur"),$(jstr latest "$ver"),$(jstr sha256 "$sum"),$(jstr notes "$notes"),$(jbool update_available "$newer"),$(jstr source "$(fw_base)")"
}

api_software_upgrade() {
    local ver sum
    ver=$(bodyval version); sum=$(bodyval sha256)
    case "$ver" in ''|*[!0-9.]*) json_error "Missing version."; return ;; esac
    printf '%s' "$sum" | grep -qE '^[0-9a-f]{64}$' || { json_error "Missing checksum."; return; }
    [ -d "$MW_RUN/locks/fw.lock" ] && { json_ok "$(jstr message 'An upgrade is already running.')"; return; }
    mkdir -p "$FW_DIR"
    fw_state running "Starting."
    ( setsid sh /usr/lib/mwadmin/fw.sh run "$ver" "$sum" >/dev/null 2>&1 & ) &
    json_ok "$(jstr message 'Upgrade started. It takes about a minute. The router stays online.')"
}

case "${0##*/}" in
    fw.sh)
        case "$1" in
            run)   fw_run "$2" "$3" ;;
        esac ;;
esac
