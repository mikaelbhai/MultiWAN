#!/bin/sh
# bandwidth_offload.sh — ships per-device bandwidth deltas to the relay
# host's bandwidth_totals.py (package/remote-app/bandwidth_totals.py,
# deployed there once by hand), which holds the only durable running total.
# The router itself keeps only a transient snapshot on tmpfs for diffing
# against next run — wiped on every reboot, never a real history — same
# "offload memory to the internet" posture as history_offload.sh, just for
# per-device byte counters instead of WAN/node events.
#
# Run frequently (every few minutes, not every 30 like history_offload.sh):
# nlbwmon's own counters live only in RAM and reset on reboot, so a crash
# between offloads loses whatever hasn't shipped yet — shorter intervals
# bound how much a crash can cost, matching this device's demonstrated
# instability under load.

. /usr/lib/mwadmin/common.sh

[ "$(uget_d mwadmin.remote.enabled 0)" = "1" ] || exit 0

host=$(uget mwadmin.remote.host)
user=$(uget mwadmin.remote.user)
port=$(uget_d mwadmin.remote.ssh_port 22)
key="$MW_STATE/remote_id_ed25519"

[ -n "$host" ] && [ -n "$user" ] && [ -f "$key" ] || exit 0

PREV="$MW_RUN/bwoffload_prev"   # tmpfs only — a diffing aid, not a log
CUR="$MW_RUN/bwoffload_cur"

# CSV, not JSON: nlbw ships no JSON parser-friendly shell tooling on this
# device (no jq), but its CSV output is tab-separated and trivial to read
# with awk — "mac" \t conns \t rx_bytes \t rx_pkts \t tx_bytes \t tx_pkts,
# one quoted value per field.
nlbw -c csv -g mac 2>/dev/null | tail -n +2 | \
    awk -F'\t' '{gsub(/"/,"",$1); gsub(/"/,"",$3); gsub(/"/,"",$5); print $1"\t"$3"\t"$5}' \
    > "$CUR"
[ -s "$CUR" ] || exit 0

name_for_mac() {
    local mac s hostmac
    mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    for s in $(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([a-z0-9_]*\)=host$/\1/p"); do
        hostmac=$(printf '%s' "$(uget dhcp.$s.mac)" | tr 'A-Z' 'a-z')
        [ "$hostmac" = "$mac" ] && { uget dhcp.$s.name; return; }
    done
    awk -v m="$mac" 'tolower($2)==m && $4!="*" {print $4; exit}' /tmp/dhcp.leases 2>/dev/null
}

payload=""
first=1
while IFS='	' read -r mac rx tx; do
    [ -z "$mac" ] && continue
    prx=0; ptx=0
    if [ -f "$PREV" ]; then
        prevline=$(awk -F'\t' -v m="$mac" '$1==m{print $2"\t"$3; found=1} END{if(!found) print "0\t0"}' "$PREV")
        prx=$(printf '%s' "$prevline" | cut -f1)
        ptx=$(printf '%s' "$prevline" | cut -f2)
    fi
    # A lower current-vs-previous value means nlbwmon rotated/reset since the
    # last run (its own 24h commit_interval, or a reboot) — treat the whole
    # current value as new traffic rather than going negative.
    drx=$rx; dtx=$tx
    [ "$prx" -le "$rx" ] 2>/dev/null && drx=$((rx - prx))
    [ "$ptx" -le "$tx" ] 2>/dev/null && dtx=$((tx - ptx))
    [ "$drx" -gt 0 ] || [ "$dtx" -gt 0 ] || continue

    name=$(name_for_mac "$mac")
    [ $first -eq 0 ] && payload="$payload,"
    first=0
    payload="$payload{\"mac\":\"$(json_escape "$mac")\",\"name\":\"$(json_escape "$name")\",\"rx_bytes\":$drx,\"tx_bytes\":$dtx}"
done < "$CUR"

[ -n "$payload" ] || { mv "$CUR" "$PREV"; exit 0; }

if printf '[%s]' "$payload" | ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
    "python3 ~/bandwidth_totals.py add" >/dev/null 2>&1
then
    mv "$CUR" "$PREV"
fi
# On failure, leave $PREV untouched (and discard $CUR) — the next run's
# diff against the same older baseline naturally covers the missed
# interval too, so a single failed shipment never loses data, just delays it.
rm -f "$CUR"
