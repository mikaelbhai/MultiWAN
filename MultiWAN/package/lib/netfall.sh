#!/bin/sh
# netfall.sh - reach the website over whichever internet line works.
#
# The router's own traffic follows the same line rules as everyone else's
# (mwan3). That is fine while the first line is really dead, because mwan3
# notices and moves over. It is not fine when the first line "works" for
# pings but cannot reach the website (a brown-out, a provider block): the
# upload, the HTTPS channel and the tunnel then just fail, and the website
# thinks the router is gone. curl_any() tries the normal route first and,
# if that fails, each other online line in turn (mwan3 use <line> ...).
#
#   curl_any <curl arguments...>   stdout = what curl printed
#   sets NF_VIA (default | wan1 | wan2 ...) and NF_RC (curl's exit code),
#   and also writes them to $MW_RUN/lastvia and $MW_RUN/lastrc because a
#   $(...) call hides variables.
#
# Call it as a plain command with a redirect, not inside $( ):
#   curl_any -s -m 15 ... "$url" > "$out"; rc=$?

MW_RUN="${MW_RUN:-/tmp/mwadmin}"

# lines mwan3 currently calls online, one per line
nf_online_lines() {
    mwan3 status 2>/dev/null | sed -n 's/^[[:space:]]*interface \(wan[0-9]\) is online.*/\1/p'
}

curl_any() {
    local out l
    NF_VIA=default
    out=$(curl "$@" 2>/dev/null); NF_RC=$?
    if [ "$NF_RC" -ne 0 ] && command -v mwan3 >/dev/null 2>&1; then
        for l in $(nf_online_lines); do
            out=$(mwan3 use "$l" curl "$@" 2>/dev/null); NF_RC=$?
            if [ "$NF_RC" -eq 0 ]; then NF_VIA="$l"; break; fi
        done
    fi
    mkdir -p "$MW_RUN" 2>/dev/null
    echo "$NF_VIA" > "$MW_RUN/lastvia"; echo "$NF_RC" > "$MW_RUN/lastrc"
    printf '%s' "$out"
    return "$NF_RC"
}

# curl's exit code in plain words
curl_why() {
    case "$1" in
        0)  echo "ok" ;;
        6)  echo "could not look up the website's name (DNS)" ;;
        7)  echo "could not connect (refused or no route)" ;;
        28) echo "timed out" ;;
        35|60|58|77) echo "secure connection (TLS) failed" ;;
        52) echo "the website closed the connection without answering" ;;
        56) echo "the connection was reset" ;;
        *)  echo "curl error $1" ;;
    esac
}
