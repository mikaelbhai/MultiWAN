#!/bin/sh
# history_offload.sh — best-effort: append local WAN/node history onto the
# relay host's home directory over the same SSH key Remote Access already
# uses, then truncate the local copy. Run periodically from cron, only while
# a relay host is actually configured and enabled — see api_remote_set's
# sync_offload_cron() in api.sh for how the cron entry itself is managed.
#
# This is the "offload memory to the internet" half of Remote Access: the
# router only ever needs to hold a small rotating window of history
# on its own tight flash (config/00-packages.sh's whole reason for existing
# is how little of this device is spare), the full record accumulates on the
# relay host instead. Silent-failing on purpose — a relay outage should
# never be allowed to block or spam-log anything on the router itself; it
# just means this run's rows stay queued locally for the next attempt.

. /usr/lib/mwadmin/common.sh

# Deliberately NOT gated on mwadmin.remote.enabled: that flag controls the
# admin-panel relay tunnel specifically, a different concern from offloading
# data to a relay host you've already configured. Requiring host/user/key to
# be set is enough on its own.
host=$(uget mwadmin.remote.host)
user=$(uget mwadmin.remote.user)
port=$(uget_d mwadmin.remote.ssh_port 22)
key="$MW_STATE/remote_id_ed25519"

[ -n "$host" ] && [ -n "$user" ] && [ -f "$key" ] || exit 0

for name in wan nodes; do
    src="$MW_STATE/history/$name.log"
    [ -s "$src" ] || continue
    # No scp/sftp needed: ssh here is dropbear (package/init.d/mwremote's own
    # comment explains why openssh-client was skipped), and dbclient runs a
    # remote command with stdin/stdout piped through the channel like any
    # other ssh client — "cat >> file" over that pipe IS the file transfer.
    if cat "$src" | ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
        "mkdir -p ~/mwadmin-history && cat >> ~/mwadmin-history/${name}.log" \
        >/dev/null 2>&1
    then
        : > "$src"
    fi
done
