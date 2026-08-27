#!/bin/sh
# send_alert.sh — sends one email via msmtp, using SMTP settings stored in
# the mwadmin UCI config. Shared by /etc/mwan3.user (real outage alerts) and
# the admin UI's "send test email" button, so both paths are guaranteed to
# behave identically — no separate test-only code path to drift out of sync
# with what actually fires during a real outage.
#
# Usage: send_alert.sh "<subject>" "<body>"

. /usr/lib/mwadmin/common.sh

SUBJECT="$1"
BODY="$2"

[ "$(uget_d mwadmin.alerts.enabled 0)" = "1" ] || { log "send_alert: alerts disabled, not sending"; exit 0; }

HOST=$(uget mwadmin.alerts.smtp_host)
PORT=$(uget_d mwadmin.alerts.smtp_port 587)
USER=$(uget mwadmin.alerts.smtp_user)
PASS=$(uget mwadmin.alerts.smtp_pass)
FROM=$(uget mwadmin.alerts.smtp_from)
TO=$(uget mwadmin.alerts.alert_to)

[ -n "$HOST" ] && [ -n "$USER" ] && [ -n "$FROM" ] && [ -n "$TO" ] || {
    log "send_alert: SMTP not fully configured, not sending"
    exit 1
}

# Written fresh on every send rather than kept as a standing file: the
# password would otherwise sit in /etc/msmtprc in plaintext indefinitely.
# /tmp is tmpfs — gone on reboot, never touches flash, and this router's
# admin panel is the only thing with shell access to /tmp in the first place.
CONF="/tmp/mwadmin-msmtprc"
umask 077
cat > "$CONF" <<EOF
defaults
auth on
tls on
tls_starttls on
tls_certcheck off
logfile /tmp/msmtp.log

account alert
host $HOST
port $PORT
user $USER
password $PASS
from $FROM

account default : alert
EOF

HOSTNAME_LABEL=$(uget system.@system[0].hostname)
FULL_SUBJECT="[${HOSTNAME_LABEL:-multiwan}] $SUBJECT"

{
    printf 'To: %s\n' "$TO"
    printf 'From: %s\n' "$FROM"
    printf 'Subject: %s\n' "$FULL_SUBJECT"
    printf '\n%s\n\n-- \nSent by the MultiWAN admin panel on %s\n' "$BODY" "$(date)"
} | msmtp -C "$CONF" "$TO" >/tmp/msmtp-lastrun.log 2>&1

RC=$?
rm -f "$CONF"

if [ $RC -eq 0 ]; then
    log "send_alert: sent '$SUBJECT' to $TO"
else
    log "send_alert: FAILED to send '$SUBJECT' — $(cat /tmp/msmtp-lastrun.log 2>/dev/null | tail -1)"
fi
exit $RC
