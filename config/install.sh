#!/bin/sh
# install.sh — run every configuration stage in order, on the router.
#
# Usage (on the router, after copying the config/ directory across):
#     cd /root/multiwan/config && sh install.sh
#
# Safe to re-run: every stage is idempotent.

set -e
cd "$(dirname "$0")"

RED=''; GRN=''; YEL=''; RST=''
if [ -t 1 ]; then
    RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; RST='\033[0m'
fi
step() { printf "\n${GRN}==> %s${RST}\n" "$*"; }
warn() { printf "${YEL}[!] %s${RST}\n" "$*" >&2; }
die()  { printf "${RED}[x] %s${RST}\n" "$*" >&2; exit 1; }

# --- Preflight ----------------------------------------------------------------
[ -f /etc/openwrt_release ] || die "Not an OpenWrt system."
[ -f ./mwan.env ] || die "mwan.env not found. Run this from the config/ directory."

board=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo unknown)
if [ "$board" != "tplink,archer-c6-v3" ]; then
    warn "Board reports '$board', expected 'tplink,archer-c6-v3'."
    warn "These scripts assume DSA port names wan/lan1..lan4 and a 16 MB flash budget."
    printf "Continue anyway? [y/N] "
    read -r ans
    case "$ans" in y|Y) ;; *) die "Aborted." ;; esac
fi

. ./mwan.env

# --- Backup current config before touching anything --------------------------
# Every stage below overwrites UCI sections. This snapshot is what you restore
# if the result is not what you wanted.
BK="/root/multiwan-preinstall-$(date +%Y%m%d-%H%M%S).tar.gz"
step "Backing up current configuration to $BK"
sysupgrade -b "$BK" 2>/dev/null || tar czf "$BK" /etc/config
echo "    Restore later with: sysupgrade -r $BK && reboot"

# --- Lockout warning ----------------------------------------------------------
cur_lan=$(uci -q get network.lan.ipaddr || echo "192.168.1.1")
if [ "$cur_lan" != "$LAN_IPADDR" ]; then
    cat <<EOF

${YEL}The LAN address changes from $cur_lan to $LAN_IPADDR.${RST}

Your SSH session will drop when stage 10 applies. That is expected.
After it drops:
  1. Release/renew DHCP on this computer (or replug the cable).
  2. Reconnect to  ssh root@$LAN_IPADDR
  3. Re-run this script; completed stages are idempotent and will simply reapply.

If you cannot reconnect, the failsafe recovery is:
  - Power cycle, hold Reset for ~5 s during boot to enter failsafe mode
  - The router comes up on 192.168.1.1 with no config applied
  - ssh root@192.168.1.1  then:  sysupgrade -r $BK && reboot

EOF
    printf "Proceed? [y/N] "
    read -r ans
    case "$ans" in y|Y) ;; *) die "Aborted." ;; esac
fi

# --- Stages -------------------------------------------------------------------
run_stage() {
    step "$2"
    sh "./$1" || die "Stage $1 failed. Fix the error above and re-run install.sh."
}

run_stage 00-packages.sh    "Stage 0/5  Packages + flash budget check"
run_stage 10-network.sh     "Stage 1/5  Network: 3 WAN + LAN bridge"
run_stage 20-firewall.sh    "Stage 2/5  Firewall zones + offload policy"
run_stage 50-system-dhcp.sh "Stage 3/5  DHCP, DNS, NTP"
run_stage 40-wireless.sh    "Stage 4/5  Wireless AP + guest"
run_stage 30-mwan3.sh       "Stage 5/5  mwan3 priority failover"

# --- Post-install summary -----------------------------------------------------
# WAN1 can be static, dhcp or pppoe — describe whichever was configured.
case "${WAN1_PROTO:-static}" in
    static) WAN1_DESC="$WAN1_IPADDR (static)" ;;
    dhcp)   WAN1_DESC="DHCP" ;;
    pppoe)  WAN1_DESC="PPPoE as $WAN1_PPPOE_USER" ;;
    *)      WAN1_DESC="${WAN1_PROTO}" ;;
esac

cat <<EOF

${GRN}=========================================================${RST}
${GRN} Base configuration complete${RST}
${GRN}=========================================================${RST}

  LAN address     : $LAN_IPADDR
  WAN1 ($PORT_WAN1)  : $WAN1_DESC (priority 1)
  WAN2 ($PORT_WAN2) : DHCP           (priority 2)
  WAN3 ($PORT_WAN3) : DHCP           (priority 3)
  LAN ports       : $PORTS_LAN
  Free flash      : $(df -h /overlay 2>/dev/null | awk 'NR==2{print $4}')

Check failover state:
  mwan3 status

${YEL}Next: deploy the admin UI.${RST}
  From your workstation:  deploy/deploy.ps1  (Windows)  or  deploy/deploy.sh
  Then browse to:         http://$LAN_IPADDR:$ADMIN_PORT

${YEL}Then work through docs/04-verification-checklist.md.${RST}
Do not consider this done until the failover test in that checklist passes.

EOF
