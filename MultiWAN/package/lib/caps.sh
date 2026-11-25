#!/bin/sh
# caps.sh - what this router can do, so a website (or app) can match itself to it.
#
#   GET /capabilities  ->  {ok, api_level, software, system, board, website_level, features:[...]}
#
# Each feature: {id, label, level, available, reason, routes:[...]}
#   level      the version of that feature's API (raised when its requests/answers change shape)
#   available  false when this router's software or hardware cannot do it (reason says why)
#
# A website compares this with its own list (portal/caps_lib.php): features both sides know at a
# compatible level are shown and used; anything else is hidden or refused with a message that says
# whether to update the router or the website. Keep this list in step with the routes in api.sh:
# one line per feature, "id|level|label|route prefixes (space separated)|availability check".
#
# The availability check is a shell command that succeeds when the router can do the feature
# (empty = always); on failure its text after "||" in the hardware column is the reason.

. /usr/lib/mwadmin/common.sh

CAPS_API_LEVEL=1        # raise when a change to any route is not backward compatible
CAPS_NEEDS_WEBSITE=1    # the lowest website api level this router's data uploads need

caps_list() {
    cat <<'EOF'
status|1|Live status|/status /site|
lines|1|Internet lines|/lines /mwan /wan|command -v mwan3 >/dev/null 2>&1 || echo "mwan3 is not installed"
force_line|1|Use only one line|/site/force|command -v mwan3 >/dev/null 2>&1 || echo "mwan3 is not installed"
line_exceptions|1|Send an address over one line|/lines/exceptions|command -v mwan3 >/dev/null 2>&1 || echo "mwan3 is not installed"
address_swaps|1|Address swaps (work around an ISP block)|/lines/swaps|
devices|1|Devices and device names|/devices /site/name|
device_limit|1|Device limits|/devices/limit|
nodes|1|Switches and access points|/nodes|
ports|1|LAN ports|/ports|
alerts|1|Outage alerts|/alerts /events|
pause|1|Break times and pausing|/pause|
guests|1|Guest list|/guests|
apps|1|App blocking|/apps|
sites|1|Site blocking|/sites|
exempt|1|Never-blocked list|/exempt|
wifi|1|Wi-Fi settings|/wifi|uci -q get wireless.@wifi-device[0] >/dev/null 2>&1 || echo "this router has no Wi-Fi radio"
drives|1|USB drive sharing|/drives|[ -x /etc/init.d/ksmbd ] || echo "file sharing (ksmbd) is not installed"
quality|1|Line quality test|/quality|
connect|1|Connect to a website|/connect|
software|1|Software update|/software|
EOF
}

api_capabilities() {
    local first=1 out="" line id lvl label routes check reason avail
    while IFS='|' read -r id lvl label routes check; do
        [ -n "$id" ] || continue
        avail=1; reason=""
        if [ -n "$check" ]; then
            reason=$(sh -c "$check" 2>/dev/null)
            [ -n "$reason" ] && avail=0
        fi
        [ "$first" = 1 ] && first=0 || out="$out,"
        out="$out{$(jstr id "$id"),$(jnum level "$lvl"),$(jstr label "$label"),$(jbool available "$avail"),$(jstr reason "$reason"),$(jstr routes "$routes")}"
    done <<EOF
$(caps_list)
EOF
    json_ok "$(jnum api_level "$CAPS_API_LEVEL"),$(jnum needs_website_level "$CAPS_NEEDS_WEBSITE"),$(jnum website_level "$(uget mwadmin.sync.web_level)"),$(jstr software "$(cat /etc/mwadmin/fw_version 2>/dev/null)"),$(jstr board "$(cat /tmp/sysinfo/board_name 2>/dev/null)"),\"features\":[$out]"
}
