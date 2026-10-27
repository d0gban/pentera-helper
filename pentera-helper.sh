#!/usr/bin/env bash
# pentera-helper — ALL-IN-ONE Pentera ops helper.
#   * diagnose why the service / node failed (plain-language verdict)
#   * configure the network (static/DHCP) via wizard or args, seamlessly across
#     subnets / hosts / environments; changes are applied by a REBOOT and verified
#     automatically after boot (gateway unreachable -> old config restored)
#   * keep the management & attack interface roles in sync
#   * keep the clock sane on dual-boot (Windows) laptops so certificates are never
#     minted on a wrong clock, and regenerate them when they were
#
#   pentera-helper diagnose [--net|--iface|--time]
#   pentera-helper status
#   pentera-helper wizard
#   pentera-helper set-static --ip A.B.C.D --cidr N --gw G [--dns "a,b"] [--iface IF] [--apply] [--no-reboot]
#   pentera-helper set-dhcp   [--iface IF] [--dns "a,b"] [--apply] [--no-reboot]
#   pentera-helper sync-iface [--iface IF] [--apply] [--no-reboot]
#   pentera-helper fix-time                  install the clock guardrails
#   pentera-helper regen-certs [--force]     re-mint node/UI certs with the current clock
#   pentera-helper commit | rollback
#   pentera-helper install                   copy to /usr/local/sbin + fix-time
#   pentera-helper help
set -uo pipefail

SVC=pentera
LOGDIR=/var/log/pentera
CLI_LOG=$LOGDIR/deployment/pentera-cli.log
NETPLAN=/etc/netplan/00-installer-config.yaml
NCONF=/etc/pentera/network/network.conf
COMPOSE_DIR=/etc/pentera/compose
SSL_DIR=/etc/ssl/pentera                      # node keystore + UI certs (the CA lives in /etc/ssl/ca)
BKROOT=/etc/pentera/backup/helper
PENDING=$BKROOT/pending.env                   # written by --apply, consumed by verify-boot after the reboot
RESULT=$BKROOT/last-apply.log
SELF=/usr/local/sbin/pentera-helper
VERIFY_UNIT=pentera-helper-verify.service
WAIT_TIME=/usr/local/sbin/pentera-wait-time
DROPIN=/etc/systemd/system/pentera.service.d/10-wait-time-sync.conf
NET_WAIT=${PH_NET_WAIT:-90}                   # seconds verify-boot waits for the gateway after reboot
VERIFY_LIST=""                                # extra hosts to ping after the reboot (space separated, set by --verify-ip / wizard)

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
die(){ printf "${RED}error:${RST} %s\n" "$*" >&2; exit 1; }
sec(){ printf "\n${BLD}== %s ==${RST}\n" "$1"; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "this action needs root — run: sudo pentera-helper $*"; }
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"

# ---------- discovery ----------
phys_ifaces(){ local n b; for n in /sys/class/net/*; do b=${n##*/}; [ -e "$n/device" ] && printf "%s\n" "$b"; done; return 0; }
is_phys(){ grep -qw "$1" <<<"$(phys_ifaces)"; }
primary_iface(){ local d; d=$(ip route 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'); [ -n "$d" ] && { echo "$d"; return; }; phys_ifaces | head -1; }
default_gw(){ ip route 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
# Is the gateway really there? ICMP first; many gateways drop ping but always answer ARP, so fall back to a fresh ARP check.
gw_ok(){
  local gw=${1:-} ifc=${2:-}
  [ -n "$gw" ] || return 1
  ip neigh flush to "$gw" ${ifc:+dev "$ifc"} >/dev/null 2>&1     # forget stale entries (root only) so the ARP is fresh
  ping -c1 -W2 "$gw" >/dev/null 2>&1 && return 0
  ip neigh show to "$gw" ${ifc:+dev "$ifc"} 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY'
}
get_conf(){ $SUDO awk -F'=' -v k="$1" '$0 ~ "^[[:space:]]*"k {gsub(/[[:space:]]/,"",$2);print $2;exit}' "$NCONF" 2>/dev/null; }
get_compose_if(){ $SUDO grep -rhoE 'NETWORK_INTERFACE=[^[:space:]"]+' "$COMPOSE_DIR"/ 2>/dev/null | head -1 | cut -d= -f2; }
netplan_mode(){ $SUDO grep -qE 'dhcp4:[[:space:]]*true' "$NETPLAN" 2>/dev/null && echo dhcp || { $SUDO grep -qE 'addresses:' "$NETPLAN" 2>/dev/null && echo static || echo unknown; }; }
# timedatectl doesn't track ntpd reliably (says "no" while ntpd is synced), so ask ntpd too
ntp_synced(){ [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] || /usr/sbin/ntp-wait -n 1 -s 1 >/dev/null 2>&1; }
dual_boot(){ $SUDO lsblk -no FSTYPE 2>/dev/null | grep -qiE 'ntfs|bitlocker'; }

# ============================================================
# shared reporting
# ============================================================
net_report(){
  local pif gw state ipv4 dns up b
  pif=$(primary_iface); pif=${pif:-"(none)"}; gw=$(default_gw)
  state=$(cat /sys/class/net/"$pif"/operstate 2>/dev/null || echo "?")
  ipv4=$(ip -4 -o addr show dev "$pif" 2>/dev/null | awk '{print $4}' | paste -sd, -)
  dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)
  printf "uplink iface : %s (operstate=%s)  mac=%s\n" "$pif" "$state" "$(cat /sys/class/net/"$pif"/address 2>/dev/null)"
  printf "IPv4 address : %s   [%s]\n" "${ipv4:-"${RED}(none!)${RST}"}" "$(netplan_mode)"
  printf "default gw   : %s" "${gw:-"${RED}(none!)${RST}"}"
  if [ -n "$gw" ]; then
    if ping -c1 -W2 "$gw" >/dev/null 2>&1; then printf "  ${GRN}[ping OK]${RST}\n"
    elif gw_ok "$gw" "$pif"; then printf "  ${YEL}[ping blocked, ARP OK]${RST}\n"
    else printf "  ${RED}[ping FAIL]${RST}\n"; fi
  else printf "\n"; fi
  [ "$(ip route 2>/dev/null | grep -c '^default')" -gt 1 ] && printf "${YEL}note         : more than one default route present${RST}\n"
  printf "DNS servers  : %s\n" "${dns:-"${RED}(none)${RST}"}"
  if getent hosts "$(hostname)" >/dev/null 2>&1; then printf "DNS resolver : ${GRN}OK${RST} (resolved own hostname)\n"
  else printf "DNS resolver : ${RED}FAIL${RST} (cannot resolve own hostname — resolver down)\n"; fi
  if command -v resolvectl >/dev/null 2>&1; then
    up=$(resolvectl status 2>/dev/null | awk -F': ' '/Current DNS Server|DNS Servers/{print $2; exit}')
    printf "resolved up  : %s\n" "${up:-?}"
  fi
  for b in br_pentera docker0 attack_bridge; do
    [ -e /sys/class/net/$b ] && printf "note         : %s is %s — normal when pentera containers aren't running yet\n" "$b" "$(cat /sys/class/net/$b/operstate 2>/dev/null)"
  done
  b=$($SUDO grep -E '^RESULT:' "$RESULT" 2>/dev/null | tail -1)
  [ -n "$b" ] && printf "last change  : %s   (details: pentera-helper status)\n" "$b"
  return 0
}

MM=""; mgmt_if=""; atk_if=""; comp_if=""
iface_check(){   # prints roles, sets MM (+ mgmt_if/atk_if/comp_if)
  local phys; mgmt_if=$(get_conf management_interface); atk_if=$(get_conf attack_interface); comp_if=$(get_compose_if)
  phys=$(phys_ifaces | paste -sd' ' -)
  printf "network.conf management_interface : %s\n" "${mgmt_if:-?}"
  printf "network.conf attack_interface     : %s\n" "${atk_if:-?}"
  printf "compose  NETWORK_INTERFACE        : %s\n" "${comp_if:-?}"
  printf "real physical NIC(s)              : %s\n" "${phys:-none}"
  MM=""
  [ -n "$mgmt_if" ] && ! is_phys "$mgmt_if" && MM="management_interface '$mgmt_if' is not a real NIC"
  [ -n "$atk_if" ]  && ! is_phys "$atk_if"  && MM="${MM:+$MM; }attack_interface '$atk_if' is not a real NIC"
  [ -n "$comp_if" ] && ! is_phys "$comp_if" && MM="${MM:+$MM; }compose NETWORK_INTERFACE '$comp_if' is not a real NIC"
  [ -n "$comp_if" ] && [ -n "$atk_if" ] && [ "$comp_if" != "$atk_if" ] && MM="${MM:+$MM; }compose '$comp_if' != attack_interface '$atk_if'"
  if [ -n "$MM" ]; then printf "${RED}MISMATCH: %s${RST}\n" "$MM"; else printf "${GRN}roles consistent (all point at the same real NIC)${RST}\n"; fi
}

# certificates dated in the future = minted while the clock was ahead (e.g. boot after Windows)
future_certs(){
  local f nb now; now=$(date -u +%s)
  for f in $($SUDO find "$SSL_DIR" -maxdepth 2 -type f \( -name '*.crt' -o -name '*Cert*.pem' -o -name '*_crt.pem' \) 2>/dev/null); do
    nb=$($SUDO openssl x509 -in "$f" -noout -startdate 2>/dev/null | cut -d= -f2)
    [ -n "$nb" ] && [ "$(date -u -d "$nb" +%s 2>/dev/null || echo 0)" -gt "$now" ] && printf "  %s  (valid from %s)\n" "$f" "$nb"
  done; return 0
}

FUT=""; TIME_BAD=""
time_report(){
  local rtc rtc_s off
  rtc=$($SUDO hwclock -r 2>/dev/null); rtc_s=$(date -u -d "$rtc" +%s 2>/dev/null || echo 0)
  off=0; [ "$rtc_s" -gt 0 ] && off=$(( rtc_s - $(date -u +%s) ))
  printf "system time  : %s  (%s)   NTP synced: %s\n" "$(date -u +%FT%TZ)" "$(date '+%F %T %Z')" "$(ntp_synced && echo yes || echo no)"
  printf "hardware RTC : %s   (offset %+ds vs system)\n" "${rtc:-?}" "$off"
  TIME_BAD=""; [ "${off#-}" -gt 600 ] && TIME_BAD="hardware clock is $(( off / 3600 ))h $(( (${off#-} % 3600) / 60 ))m off from system time"
  [ -n "$TIME_BAD" ] && printf "${RED}%s${RST}\n" "$TIME_BAD"
  printf "RTC mode     : %s   timezone: %s\n" "$([ "$(timedatectl show -p LocalRTC --value 2>/dev/null)" = yes ] && echo LOCAL || echo UTC)" "$(timedatectl show -p Timezone --value 2>/dev/null)"
  if dual_boot; then
    if [ "$(timedatectl show -p LocalRTC --value 2>/dev/null)" = yes ]; then printf "dual-boot    : Windows present — RTC kept in LOCAL time like Windows ${GRN}(OK)${RST}\n"
    else printf "dual-boot    : ${YEL}Windows present but RTC is UTC — each Windows boot shifts Ubuntu's clock${RST}\n               fix: sudo pentera-helper fix-time --tz Asia/Manila --rtc local\n"; fi
  fi
  if [ -f "$DROPIN" ]; then printf "guardrail    : ${GRN}installed${RST} (pentera waits for NTP before starting)\n"
  else printf "guardrail    : ${YEL}NOT installed${RST} — run: sudo pentera-helper fix-time\n"; fi
  FUT=$(future_certs)
  if [ -n "$FUT" ]; then printf "${RED}future-dated certificates:${RST}\n%s\n" "$FUT"; else printf "certificates : ${GRN}none dated in the future${RST}\n"; fi
}

# node health — catches a node going Unavailable even while the service is "active". 0 = issue found
NODE_SIG=""
node_health(){
  NODE_SIG=$(tail -n 400 "$LOGDIR"/mgmt.log 2>/dev/null \
    | grep -hiE "certificate is not yet valid|certificate has expired|CERTIFICATE_VERIFY_FAILED|SSLCertVerificationError" | tail -2 | cut -c1-220)
  [ -z "$NODE_SIG" ] && return 1
  printf "recent node-check TLS errors:\n%s\n" "$NODE_SIG"; return 0
}

FUT_VERDICT="${RED}CERTIFICATES ARE DATED IN THE FUTURE${RST} -> management can't verify the node -> node Unavailable.
They were minted while the clock was ahead (typical after booting Windows: it stores LOCAL time in the
hardware clock, Ubuntu reads it as UTC and boots +8h), then NTP corrected the clock backwards.
${BLD}FIX:${RST} sudo pentera-helper fix-time      (once — stops it from happening again)
     sudo pentera-helper regen-certs   (re-mints the certs with the correct clock)"

# ============================================================
# diagnose
# ============================================================
cmd_diagnose(){
  case "${1:-}" in
    --net)   sec "Network state (uplink)"; net_report; echo; return 0 ;;
    --iface) sec "Interface roles (mgmt vs attack vs real NIC)"; iface_check; echo; return 0 ;;
    --time)  sec "Time & certificates"; time_report; echo; return 0 ;;
  esac
  local active sub result exitc ac bst cap jtail verr_all verr fatal_comp fatal_msg reason=""
  active=$(systemctl is-active "$SVC" 2>/dev/null)
  sub=$(systemctl show -p SubState --value "$SVC" 2>/dev/null)
  result=$(systemctl show -p Result --value "$SVC" 2>/dev/null)
  exitc=$(systemctl show -p ExecMainStatus --value "$SVC" 2>/dev/null)
  sec "Service state"; printf "active=%s  sub=%s  result=%s  last-exit-code=%s\n" "$active" "$sub" "$result" "$exitc"
  # network info is always shown, whatever the service state — most "node failed" cases start here
  sec "Network state (uplink)"; net_report
  sec "Interface roles (mgmt vs attack vs real NIC)"; iface_check
  [ "$active" = "activating" ] && { printf "\n${YEL}Service is STARTING (activating/%s).${RST} Not failed yet — let it settle, then re-run.\n" "$sub"; return 0; }

  sec "Time & certificates"; time_report

  if [ "$active" = "active" ]; then
    sec "Node health"
    if [ -n "$FUT" ]; then sec "VERDICT"; printf "%s\n\n" "$FUT_VERDICT"
    elif node_health; then sec "VERDICT"; printf "${YEL}Service runs but node-checks hit TLS errors.${RST} Check the time/cert lines above; if they are clean, the errors are old.\n\n"
    else printf "${GRN}Service running, certificates valid, no node TLS errors — nothing to interpret.${RST}\n\n"; fi
    return 0
  fi

  ac=$(cat /sys/class/power_supply/ADP0/online 2>/dev/null || echo "?")
  bst=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "?")
  cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")
  sec "Power state"; printf "AC adapter (ADP0) online=%s   BAT0 status=%s   charge=%s%%\n" "$ac" "$bst" "$cap"

  jtail=$($SUDO journalctl -u "$SVC" -n 400 --no-pager 2>/dev/null)
  sec "Actual failing task (from journal)"
  printf "%s\n" "$jtail" | grep -E "fatal:|FAILED!|PLAY RECAP|failed=" | tail -4 | sed 's/^[A-Za-z]* [0-9: ]*[^ ]* [^:]*: //'
  sec "Validation errors (most recent, from pentera-cli.log)"
  verr_all=$($SUDO grep -iE "unexpected result on component|does not meet|Parser .*FAIL" "$CLI_LOG" 2>/dev/null | tail -6)
  verr=$(printf "%s\n" "$verr_all" | grep -viE "ignore errors")
  printf "%s\n" "${verr_all:-"(none found in $CLI_LOG)"}"
  fatal_comp=$(printf "%s\n" "$verr" | grep -oE "component: [A-Z_]+" | tail -1 | awk '{print $2}')
  fatal_msg=$(printf "%s\n"  "$verr" | sed -nE 's/.*message: (.*)$/\1/p' | tail -1)

  netscan(){ { printf "%s\n" "$jtail"; tail -n 400 "$LOGDIR"/orchestrator.log "$LOGDIR"/mgmt.log "$LOGDIR"/genie.log "$LOGDIR"/replicator.log 2>/dev/null; $SUDO tail -n 400 "$CLI_LOG" 2>/dev/null; } | grep -hiE "$1" | tail -3; }

  sec "VERDICT"
  if [ -n "$MM" ]; then
    reason="${RED}INTERFACE ROLE MISMATCH${RST}: $MM
Pentera's configured NIC name doesn't match the real hardware (or network.conf and compose drifted).
The attack bridge can't bind to a NIC that isn't there -> nodes fail. Usual cause after moving the
appliance to a different VM/host/subnet.
${BLD}FIX:${RST} sudo pentera-helper sync-iface --apply"
  elif [ -n "$FUT" ]; then reason="$FUT_VERDICT"
  elif [ -z "$(default_gw)" ]; then
    reason="${RED}NO DEFAULT ROUTE${RST} and Pentera is not running — the likely cause. Pentera's start fails at its host-id/settings
step when the box has no default gateway.
Usual reason: a gateway the OS refuses (the network/broadcast address, or outside the subnet), or none configured.
${BLD}FIX:${RST} sudo pentera-helper wizard   (or set-static with a valid --gw). On an isolated VLAN with no real router,
     still give an unused address of the subnet as the gateway; --verify-ip covers the connectivity check."
  fi
  if [ -z "$reason" ]; then case "$fatal_comp" in
    BATTERY)
      if [ "$ac" = "0" ] || [ "$bst" = "Discharging" ]; then
        reason="${RED}AC POWER IS DISCONNECTED.${RST} ADP0 online=$ac, battery ${bst} (${cap}%).
Pre-flight refuses to start off mains power. ${BLD}FIX:${RST} plug in AC; confirm ADP0 online=1 / BAT0 Charging; restart."
      else reason="${YEL}Battery FAILED pre-flight while AC present.${RST} Likely worn battery — reseat/replace, then restart."; fi ;;
    DISK) reason="${RED}DISK SPACE too low${RST}: \"$fatal_msg\".
${BLD}FIX:${RST} df -h / /opt /var ; sudo du -xh /var/log/pentera | sort -rh | head ; clear old logs / old /opt/pentera-versions, then restart." ;;
    FILE) reason="${YEL}A required FILE is missing${RST}: \"$fatal_msg\".
Usually a first-boot/migration step that didn't finish. CHECK: $LOGDIR/migration.log , $LOGDIR/restful-installer.log" ;;
    HARDWARE) reason="${CYN}Only HARDWARE flagged (\"$fatal_msg\") — marked '(ignore errors)', NOT fatal.${RST} Look at the failing task above for the real blocker." ;;
    NETWORK|CONNECTIVITY|DNS|INTERFACE|GATEWAY) reason="${RED}Pre-flight ${fatal_comp} check failed${RST}: \"$fatal_msg\". See 'Network state' above." ;;
  esac; fi
  if [ -z "$reason" ]; then
    if [ -n "$(netscan 'Temporary failure in name resolution|socket\.gaierror|\[Errno -[0-9]+\]|Name or service not known|could not resolve|Try again')" ]; then
      reason="${RED}DNS / NAME RESOLUTION failing.${RST} A component can't resolve a hostname it needs.
${BLD}CHECK:${RST} DNS line in 'Network state'; /etc/resolv.conf; resolvectl status; is the DNS server reachable?
Sample: $(netscan 'Temporary failure in name resolution|socket\.gaierror|Try again|could not resolve' | head -1)"
    elif [ -n "$(netscan 'No route to host|Network is unreachable')" ]; then
      reason="${RED}ROUTING / L3 problem${RST} ('No route to host'/'unreachable'). ${BLD}CHECK:${RST} 'Network state' above; ip a ; ip route"
    elif [ -n "$(netscan 'Connection refused|ECONNREFUSED')" ]; then
      reason="${YEL}A dependency refused the connection${RST}. Often transient mid-start; if it persists a container crashed.
${BLD}CHECK:${RST} docker ps -a (Exited?) ; ss -ltnp ; the failing task above for host:port."
    elif [ -n "$(netscan 'pymongo|ServerSelectionTimeout|_receive_data_on_socket')" ]; then
      reason="${YEL}MongoDB connectivity timed out${RST}. ${BLD}CHECK:${RST} docker ps (mongo up?) ; $LOGDIR/mgmt.log ; ss -ltnp."
    fi
  fi
  if [ -z "$reason" ]; then
    if printf "%s" "$jtail" | grep -qiE "No space left on device"; then reason="${RED}DISK FULL${RST} (No space left on device). Free space, then restart."
    elif printf "%s" "$jtail" | grep -qiE "license.*(expired|invalid|not valid|not found|exceeded|missing|unlicensed)"; then reason="${YEL}LICENSE problem${RST} — review $LOGDIR/license-server.log."; fi
  fi
  printf "%s\n" "${reason:-"No known signature matched. Chain: systemd status=$exitc <- ansible rc=2 <- failed task above <- validation line above.
Inspect:  sudo journalctl -u pentera -n 200 --no-pager ; $CLI_LOG ; network deep-dive: pentera-helper diagnose --net"}"
  echo
}

# ============================================================
# status (read-only)
# ============================================================
cmd_status(){
  sec "Physical NICs"
  phys_ifaces | while read -r n; do
    printf "  %-10s state=%-6s ipv4=%s mac=%s\n" "$n" "$(cat /sys/class/net/$n/operstate 2>/dev/null)" \
      "$(ip -4 -o addr show dev $n 2>/dev/null | awk '{print $4}' | paste -sd, -)" "$(cat /sys/class/net/$n/address 2>/dev/null)"
  done
  sec "Interface roles"; iface_check
  sec "Netplan"; printf "  mode=%s  file=%s\n" "$(netplan_mode)" "$NETPLAN"; $SUDO sed 's/^/  | /' "$NETPLAN" 2>/dev/null
  sec "Time & certificates"; time_report
  sec "Service"; printf "  pentera is %s\n" "$(systemctl is-active pentera 2>/dev/null)"
  sec "Network change"
  if $SUDO test -f "$PENDING"; then printf "  ${YEL}staged change waiting for reboot/verification:${RST}\n"; $SUDO sed 's/^/    /' "$PENDING"
  else printf "  nothing staged\n"; fi
  $SUDO test -f "$RESULT" && { printf "  last verification (%s):\n" "$RESULT"; $SUDO tail -n 6 "$RESULT" | sed 's/^/    /'; }
}

# ============================================================
# time guardrails + cert regeneration
# ============================================================
cmd_fix_time(){
  need_root fix-time
  TZ_SET=""; RTC_MODE=auto
  while [ $# -gt 0 ]; do case "$1" in
    --tz) TZ_SET=$2; shift 2;; --rtc) RTC_MODE=$2; shift 2;;
    *) die "unknown option: $1 (fix-time [--tz Area/City] [--rtc local|utc|auto])";; esac; done
  sec "Time guardrails"
  # 1. sync fast after boot (ntpd runs with -g, so it may step even an 8h error)
  if [ -f /etc/ntp.conf ]; then
    if grep -E '^[[:space:]]*(pool|server)[[:space:]]' /etc/ntp.conf | grep -qv iburst; then
      cp -a /etc/ntp.conf /etc/ntp.conf.bak-helper
      sed -i -E '/^[[:space:]]*(pool|server)[[:space:]]/{/iburst/!s/[[:space:]]*$/ iburst/}' /etc/ntp.conf
      systemctl restart ntp 2>/dev/null   # only when changed: a restart drops NTP sync for a while
    fi
    printf "ntp.conf     : iburst on: %s\n" "$(grep -E '^[[:space:]]*(pool|server)[[:space:]]' /etc/ntp.conf | paste -sd';' -)"
  else printf "${YEL}ntp.conf not found — skipped iburst${RST}\n"; fi
  # 2. pentera waits (bounded) for NTP, so certs are never minted on a wrong clock
  cat > "$WAIT_TIME" <<'EOF'
#!/bin/bash
# installed by pentera-helper: hold Pentera's start until NTP has synced the clock (bounded), so
# certificates are never minted on a wrong clock (e.g. after Windows left LOCAL time in the RTC).
MAX=${1:-180}
up(){ cut -d. -f1 /proc/uptime; }
t0=$(up)
echo "pentera-wait-time: waiting up to ${MAX}s for NTP (sys=$(date -u +%FT%TZ) rtc=$(hwclock -r 2>/dev/null))"
if /usr/sbin/ntp-wait -n $(( MAX / 5 )) -s 5 >/dev/null 2>&1; then
  echo "pentera-wait-time: NTP synced after $(( $(up) - t0 ))s (sys=$(date -u +%FT%TZ))"
  hwclock --systohc && echo "pentera-wait-time: hardware clock rewritten from the synced clock ($(hwclock -r))"
else
  echo "pentera-wait-time: WARNING NTP not synced within ${MAX}s (offline?) — starting Pentera anyway (sys=$(date -u +%FT%TZ))"
fi
exit 0
EOF
  chmod 755 "$WAIT_TIME"
  mkdir -p "$(dirname "$DROPIN")"
  cat > "$DROPIN" <<EOF
# installed by pentera-helper fix-time
[Unit]
After=ntp.service network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-$WAIT_TIME 180
EOF
  systemctl daemon-reload
  printf "pentera      : waits up to 180s for NTP before starting (%s)\n" "$DROPIN"
  # 3. timezone + hardware-clock mode. On a Windows dual-boot keep the RTC in LOCAL time, the way
  #    Windows writes it, so switching OS never shifts Ubuntu's clock. Linux itself still runs on UTC.
  if [ -n "$TZ_SET" ]; then timedatectl set-timezone "$TZ_SET" || die "unknown timezone '$TZ_SET' (see: timedatectl list-timezones)"; fi
  printf "timezone     : %s\n" "$(timedatectl show -p Timezone --value)"
  [ "$RTC_MODE" = auto ] && { dual_boot && RTC_MODE=local || RTC_MODE=utc; }
  case "$RTC_MODE" in
    local) timedatectl set-local-rtc 1 2>/dev/null; printf "RTC mode     : LOCAL time — same convention as Windows\n" ;;
    utc)   timedatectl set-local-rtc 0 2>/dev/null; printf "RTC mode     : UTC\n" ;;
    *)     die "--rtc must be local, utc or auto" ;;
  esac
  if ntp_synced; then hwclock --systohc && printf "hardware RTC : set from the NTP-synced clock (%s)\n" "$(hwclock -r)"
  else printf "${YEL}hardware RTC : left unchanged (NTP not synced yet)${RST}\n"; fi
  printf "${GRN}Done.${RST}\n"
}

cmd_regen_certs(){
  need_root regen-certs
  [ "${1:-}" = --force ] || ntp_synced || die "clock is not NTP-synced — regenerating now could mint wrong-dated certs again (fix time first, or pass --force)"
  local bk t0 f fut
  bk="$BKROOT/certs-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$bk/keystore" "$bk/ui_certs"
  tar czf "$bk/ssl-pentera.tgz" -C /etc/ssl pentera; printf "backup: %s\n" "$bk"
  systemctl stop "$SVC"
  find "$SSL_DIR/keystore" -maxdepth 1 -type f -exec mv {} "$bk/keystore/" \;
  find "$SSL_DIR/ui_certs" -maxdepth 1 -type f -exec mv {} "$bk/ui_certs/" \;
  t0=$(date -u '+%F %T'); printf "starting pentera (it re-mints the node + UI certs; CA untouched)...\n"
  systemctl start "$SVC"
  if [ "$(systemctl is-active "$SVC")" != active ]; then
    printf "${RED}pentera failed to start — restoring the previous certs${RST}\n"
    systemctl stop "$SVC"; cp -a "$bk/keystore/." "$SSL_DIR/keystore/"; cp -a "$bk/ui_certs/." "$SSL_DIR/ui_certs/"; systemctl start "$SVC"
    return 1
  fi
  sec "New certificates"
  for f in "$SSL_DIR"/keystore/*.crt "$SSL_DIR"/ui_certs/*_crt.pem; do
    [ -f "$f" ] && printf "  %-22s valid from %s\n" "${f##*/}" "$(openssl x509 -in "$f" -noout -startdate 2>/dev/null | cut -d= -f2)"
  done
  fut=$(future_certs); [ -n "$fut" ] && { printf "${RED}still future-dated:${RST}\n%s\n" "$fut"; return 1; }
  printf "${GRN}Certificates regenerated with the current clock.${RST} The node returns to Available within ~1-2 min.\n"
}

# ============================================================
# backup / staging / verify-after-reboot
# ============================================================
make_backup(){ local bk="$BKROOT/net-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$bk"
  [ -f "$NETPLAN" ] && cp -a "$NETPLAN" "$bk/"; [ -f "$NCONF" ] && cp -a "$NCONF" "$bk/"; cp -a "$COMPOSE_DIR" "$bk/compose" 2>/dev/null
  ln -sfn "$bk" "$BKROOT/last"; echo "$bk"; }
restore_backup(){ local bk=$1
  [ -f "$bk/$(basename "$NETPLAN")" ] && cp -a "$bk/$(basename "$NETPLAN")" "$NETPLAN"
  [ -f "$bk/$(basename "$NCONF")" ]   && cp -a "$bk/$(basename "$NCONF")" "$NCONF"
  [ -d "$bk/compose" ] && cp -a "$bk/compose/." "$COMPOSE_DIR/"; return 0; }

install_self(){ [ "$(readlink -f "$0")" = "$SELF" ] || install -m 755 "$(readlink -f "$0")" "$SELF"; }
install_verify_unit(){
  cat > /etc/systemd/system/$VERIFY_UNIT <<EOF
# installed by pentera-helper: verifies a staged network change once, after the reboot
[Unit]
Description=pentera-helper: verify staged network change after reboot (auto-rollback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SELF verify-boot

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

stage_reboot(){   # $1 backup dir   $2 expected gateway ("" = take it from DHCP after boot)   $3 iface
  local bk=$1 gw=$2 ifc=$3 oldgw oldok=0
  # Is the OLD network still where we are? (the new config is only written, not live yet, so this still tests the old one.)
  # If its gateway is already silent the box was moved to another network, and restoring that config could not help.
  oldgw=$(default_gw); gw_ok "$oldgw" "$ifc" && oldok=1
  install_self; install_verify_unit
  printf "BK='%s'\nGW='%s'\nIFACE='%s'\nSTAGED='%s'\nOLD_GW='%s'\nOLD_OK='%s'\nTARGETS='%s'\n" "$bk" "$gw" "$ifc" "$(date -u +%FT%TZ)" "$oldgw" "$oldok" "$VERIFY_LIST" > "$PENDING"
  systemctl enable "$VERIFY_UNIT" >/dev/null 2>&1
  sec "Staged"
  printf "  backup  : %s\n  verify  : after boot, within %ss the gateway %s must answer (ping or ARP)%s\n" "$bk" "$NET_WAIT" "${gw:-"(from DHCP)"}" "${VERIFY_LIST:+ — or any of: $VERIFY_LIST}"
  if [ "$oldok" = 1 ]; then
    printf "  on fail : the old config is restored and the box reboots once more (the old gateway %s answers now, so you are still on the old network)\n" "$oldgw"
  else
    printf "  ${YEL}on fail : the NEW config is KEPT, no revert${RST} — the old gateway (%s) does not answer now, so you are on another network\n            and restoring the old config would not help. Fix it at the console:  sudo pentera-helper wizard\n" "${oldgw:-none}"
  fi
  # the next boot reads the hardware clock — make sure it holds correct UTC
  if ntp_synced; then hwclock --systohc && printf "  clock   : hardware clock set from the synced clock (the next boot starts on the right time)\n"
  else printf "  ${YEL}clock   : NTP not synced — hardware clock not touched${RST}\n"; fi
  [ -f "$DROPIN" ] || printf "  ${YEL}tip     : time guardrail not installed (sudo pentera-helper fix-time)${RST}\n"
  if [ "${NO_REBOOT:-0}" = 1 ]; then printf "\nNot rebooting (--no-reboot). The change applies and is verified on the next reboot.\n"; return 0; fi
  printf "\n${BLD}Rebooting in 10s to apply.${RST} Ctrl-C cancels the reboot (the change stays staged for the next one).\n"
  printf "After boot check the result with:  sudo pentera-helper status\n"
  sleep 10; systemctl reboot
}

cmd_verify_boot(){   # run once by pentera-helper-verify.service after the reboot
  # No reboot loop is possible: the unit disables itself FIRST, and $PENDING is removed before any reboot,
  # so one --apply causes at most one automatic revert (2 reboots total) and then nothing runs again.
  systemctl disable "$VERIFY_UNIT" >/dev/null 2>&1
  [ -f "$PENDING" ] || exit 0
  local BK GW IFACE STAGED OLD_GW OLD_OK TARGETS gw i t proof="" ok=0 fut
  . "$PENDING"; OLD_OK=${OLD_OK:-1}; TARGETS=${TARGETS:-}
  exec >>"$RESULT" 2>&1
  echo "=== verify-boot $(date -u +%FT%TZ)  (staged $STAGED, iface $IFACE) ==="
  for i in $(seq 1 $(( NET_WAIT / 3 ))); do
    gw=${GW:-$(default_gw)}
    if gw_ok "$gw" "$IFACE"; then ok=1; proof="gateway $gw reachable"; break; fi
    for t in $TARGETS; do
      if gw_ok "$t" "$IFACE"; then ok=1; proof="gateway ${gw:-none} silent, but test host $t answers"; break 2; fi
    done
    sleep 3
  done
  if [ "$ok" != 1 ]; then
    if [ "$OLD_OK" = 1 ]; then
      echo "network: FAILED — gateway '${gw:-none}'${TARGETS:+ and test hosts ($TARGETS)} unreachable after ${NET_WAIT}s -> restoring $BK and rebooting"
      restore_backup "$BK"; rm -f "$PENDING"; echo "RESULT: REVERTED"; sync; systemctl reboot; exit 0
    fi
    echo "network: FAILED — gateway '${gw:-none}'${TARGETS:+ and test hosts ($TARGETS)} unreachable after ${NET_WAIT}s"
    echo "the old gateway (${OLD_GW:-none}) did not answer when this was staged, so the box was not on the old network;"
    echo "restoring the old config would not help -> KEEPING the new config, no further reboot."
    echo "fix at the console:  sudo pentera-helper wizard      (old config backup: $BK)"
    rm -f "$PENDING"; echo "RESULT: FAILED-KEPT"; exit 0
  fi
  echo "network: OK — $proof, $IFACE = $(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}')"
  for i in $(seq 1 240); do [ "$(systemctl is-active "$SVC")" = active ] && break; sleep 5; done
  echo "pentera: $(systemctl is-active "$SVC")"
  fut=$(future_certs)
  if [ -n "$fut" ]; then
    echo "certificates: future-dated:"; echo "$fut"
    if ntp_synced; then echo "-> regenerating"; ( cmd_regen_certs ) || echo "-> regen-certs failed (see above)"; else echo "-> clock not synced; run 'pentera-helper regen-certs' once time is fixed"; fi
  else echo "certificates: valid"; fi
  rm -f "$PENDING"; echo "RESULT: KEPT"
}

cmd_commit(){ need_root commit
  [ -f "$PENDING" ] || { echo "nothing staged."; return 0; }
  rm -f "$PENDING"; systemctl disable "$VERIFY_UNIT" >/dev/null 2>&1
  printf "${GRN}Kept — staged change accepted without the automatic check.${RST}\n"; }
cmd_rollback(){ need_root rollback
  local bk; bk=$(readlink -f "$BKROOT/last" 2>/dev/null); [ -d "$bk" ] || die "no backup found"
  restore_backup "$bk"; rm -f "$PENDING"; systemctl disable "$VERIFY_UNIT" >/dev/null 2>&1
  printf "Restored %s. Rebooting in 10s to apply (Ctrl-C to cancel).\n" "$bk"; sleep 10; systemctl reboot; }

# ============================================================
# netplan + interface roles (write only; the reboot applies them)
# ============================================================
gen_netplan(){ local mode=$1 ifc=$2 ip=${3:-} cidr=${4:-} gw=${5:-} dns=${6:-}
  if [ "$mode" = dhcp ]; then
    printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: true\n' "$ifc"
    [ -n "$dns" ] && printf '      nameservers:\n        addresses: [%s]\n' "$dns"
  else
    printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: false\n      addresses: [%s/%s]\n' "$ifc" "$ip" "$cidr"
    [ -n "$dns" ] && printf '      nameservers:\n        addresses: [%s]\n' "$dns"
    printf '      routes:\n        - to: default\n          via: %s\n          metric: 50\n' "$gw"
  fi
}
valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local o; for o in ${1//./ }; do [ "$o" -le 255 ] || return 1; done; }
ip2int(){ local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
# Is this a usable ip/prefix/gateway combination? Prints the reason and returns 1 when not.
# (a gateway on the network or broadcast address, or outside the subnet, is silently dropped by the OS -> no default
#  route -> Pentera cannot start)
gw_check(){   # ip prefix gateway
  local ipn gwn mask net bc
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 8 ] && [ "$2" -le 30 ] || { echo "prefix /$2 is not usable (use 8-30)"; return 1; }
  ipn=$(ip2int "$1"); gwn=$(ip2int "$3")
  mask=$(( (0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF )); net=$(( ipn & mask )); bc=$(( net | (~mask & 0xFFFFFFFF) ))
  { [ "$ipn" -ne "$net" ] && [ "$ipn" -ne "$bc" ]; } || { echo "$1 is the network/broadcast address of $1/$2, not a host address"; return 1; }
  [ $(( gwn & mask )) -eq "$net" ] || { echo "gateway $3 is outside the subnet of $1/$2"; return 1; }
  { [ "$gwn" -ne "$net" ] && [ "$gwn" -ne "$bc" ]; } || { echo "gateway $3 is the network/broadcast address of $1/$2 — the OS would drop the route and Pentera could not start"; return 1; }
  [ "$gwn" -ne "$ipn" ] || { echo "gateway $3 is the same as the host IP"; return 1; }
}

plan_netplan(){   # mode iface ip cidr gw dns apply
  local mode=$1 ifc=$2 ip=$3 cidr=$4 gw=$5 dns=$6 apply=$7 yaml
  yaml=$(gen_netplan "$mode" "$ifc" "$ip" "$cidr" "$gw" "$dns")
  sec "Netplan ($mode on $ifc)"; printf "%s\n" "$yaml" | sed 's/^/  | /'
  if command -v python3 >/dev/null; then printf "%s" "$yaml" | python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin)' 2>/dev/null || die "generated YAML failed validation"; fi
  [ "$apply" = 1 ] || return 0
  printf "%s\n" "$yaml" > "$NETPLAN"; chmod 600 "$NETPLAN"
  netplan generate 2>/tmp/ph.err || { restore_backup "$BK"; cat /tmp/ph.err >&2; die "netplan rejected the config — restored, nothing staged"; }
}

plan_roles(){   # iface apply
  local ifc=$1 apply=$2
  is_phys "$ifc" || die "'$ifc' is not a real NIC (have: $(phys_ifaces | paste -sd, -))"
  sec "Interface roles -> $ifc (netplan + network.conf + compose)"
  printf "  management_interface      : %s -> %s\n" "$(get_conf management_interface)" "$ifc"
  printf "  attack_interface          : %s -> %s\n" "$(get_conf attack_interface)" "$ifc"
  printf "  compose NETWORK_INTERFACE : %s -> %s\n" "$(get_compose_if)" "$ifc"
  [ "$apply" = 1 ] || return 0
  sed -i -E "s|^([[:space:]]*management_interface[[:space:]]*=[[:space:]]*).*|\1$ifc|" "$NCONF"
  sed -i -E "s|^([[:space:]]*attack_interface[[:space:]]*=[[:space:]]*).*|\1$ifc|"     "$NCONF"
  grep -rlE 'NETWORK_INTERFACE=' "$COMPOSE_DIR"/ 2>/dev/null | while read -r f; do sed -i -E "s|(NETWORK_INTERFACE=)[^[:space:]\"]+|\1$ifc|g" "$f"; done
}

dry_note(){
  printf "\n  verify after boot: gateway%s\n" "${VERIFY_LIST:+ — or any of: $VERIFY_LIST}"
  printf "${CYN}(dry-run — add --apply to write these and reboot; the box verifies itself after boot)${RST}\n"; }

# ============================================================
# wizard
# ============================================================
cmd_wizard(){
  [ "$(id -u)" -eq 0 ] || die "run the wizard with sudo:  sudo pentera-helper wizard"
  exec 3<>/dev/tty || die "wizard needs an interactive terminal (tty)"
  w(){ printf "%b" "$*" >&3; }
  local def mgmt mode ip="" cidr="" gw="" dns="" atk ans i n bad; declare -a NICS
  w "${BLD}+----------------------------------------------+\n"
  w "|       Pentera Helper — Network Setup          |\n"
  w "+----------------------------------------------+${RST}\n"
  mapfile -t NICS < <(phys_ifaces); def=$(primary_iface)

  w "\n${BLD}1) Management interface${RST}\n"
  i=1; for n in "${NICS[@]}"; do w "   [$i] $n$([ "$n" = "$def" ] && echo '  (detected)')\n"; i=$((i+1)); done
  w "   Select management interface [default $def]: "; read -r -u 3 ans; mgmt=${ans:-$def}
  [[ "$mgmt" =~ ^[0-9]+$ ]] && mgmt=${NICS[$((mgmt-1))]:-}; is_phys "$mgmt" || die "invalid interface: $mgmt"

  w "\n${BLD}2) IP assignment${RST}\n"
  w "   [1] Static   [2] DHCP   -> choose [1]: "; read -r -u 3 ans; ans=${ans:-1}
  if [ "$ans" = 2 ]; then
    mode=dhcp
    w "   Override DNS (comma list, blank = from DHCP): "; read -r -u 3 dns
  else
    mode=static
    while :; do w "   IP address            : "; read -r -u 3 ip; valid_ip "$ip" && break || w "   ${RED}invalid IP, try again${RST}\n"; done
    w "   Prefix / CIDR [24]    : "; read -r -u 3 cidr; cidr=${cidr:-24}
    while :; do
      w "   Gateway               : "; read -r -u 3 gw
      valid_ip "$gw" || { w "   ${RED}invalid gateway, try again${RST}\n"; continue; }
      bad=$(gw_check "$ip" "$cidr" "$gw") && break
      w "   ${RED}$bad${RST}\n   (even on an isolated VLAN give an unused address of the subnet — Pentera needs a default route)\n"
    done
    w "   DNS (comma) [8.8.8.8] : "; read -r -u 3 dns; dns=${dns:-8.8.8.8}
  fi

  w "\n${BLD}3) Attack interface${RST}\n"
  w "   Same as management ($mgmt)? [Y/n]: "; read -r -u 3 ans
  if [[ "${ans:-y}" =~ ^[Nn] ]]; then
    i=1; for n in "${NICS[@]}"; do w "   [$i] $n\n"; i=$((i+1)); done
    w "   Select attack interface: "; read -r -u 3 atk; [[ "$atk" =~ ^[0-9]+$ ]] && atk=${NICS[$((atk-1))]:-}
  else atk=$mgmt; fi
  is_phys "$atk" || die "invalid attack interface: $atk"

  w "\n${BLD}4) Connectivity check after the reboot${RST}\n"
  w "   The gateway is always tested. Add IPs to ping as well: the change is KEPT if the gateway OR any of them answers.\n"
  w "     - isolated VLAN (no internet): a neighbour or server on that VLAN, e.g. 10.20.0.5\n"
  w "     - with internet: public IPs, e.g. 8.8.8.8, 1.1.1.1   (also covers a gateway that blocks ping)\n"
  while :; do
    w "   Extra IPs (comma separated, blank = gateway only): "; read -r -u 3 ans
    VERIFY_LIST=""; bad=""
    for n in ${ans//,/ }; do if valid_ip "$n"; then VERIFY_LIST="${VERIFY_LIST:+$VERIFY_LIST }$n"; else bad="$n"; fi; done
    [ -z "$bad" ] && break
    w "   ${RED}invalid IP: $bad — try again${RST}\n"
  done

  w "\n${BLD}Review${RST}\n"
  w "   management = $mgmt\n   attack     = $atk\n   mode       = $mode\n"
  [ "$mode" = static ] && w "   address    = $ip/$cidr\n   gateway    = $gw\n"
  w "   dns        = ${dns:-auto}\n"
  w "   check      = gateway${VERIFY_LIST:+ or any of: $VERIFY_LIST}\n"
  w "\n   The box will REBOOT to apply, then check itself. Passes -> kept. Fails -> restored if you are still on the old\n"
  w "   network, otherwise kept so you can fix it at the console.\n"
  w "   Apply and reboot now? [y/N]: "; read -r -u 3 ans
  [[ "${ans:-n}" =~ ^[Yy] ]] || { w "aborted.\n"; exec 3>&-; return 0; }
  exec 3>&-

  BK=$(make_backup)
  plan_netplan "$mode" "$mgmt" "$ip" "$cidr" "$gw" "$dns" 1
  plan_roles "$mgmt" 1
  [ "$atk" != "$mgmt" ] && sed -i -E "s|^([[:space:]]*attack_interface[[:space:]]*=[[:space:]]*).*|\1$atk|" "$NCONF"
  stage_reboot "$BK" "$gw" "$mgmt"
}

# ============================================================
# options + help + dispatch
# ============================================================
parse_opts(){ IFACE=""; IP=""; CIDR=""; GW=""; DNS=""; APPLY=0; NO_REBOOT=0; VERIFY_LIST=""
  local vips="" t
  while [ $# -gt 0 ]; do case "$1" in
    --iface) IFACE=$2; shift 2;; --ip) IP=$2; shift 2;; --cidr) CIDR=$2; shift 2;;
    --gw) GW=$2; shift 2;; --dns) DNS=$2; shift 2;; --apply) APPLY=1; shift;;
    --verify-ip) vips=$2; shift 2;;
    --no-reboot) NO_REBOOT=1; shift;;
    *) die "unknown option: $1";; esac; done
  for t in ${vips//,/ }; do valid_ip "$t" || die "bad --verify-ip: '$t'"; VERIFY_LIST="${VERIFY_LIST:+$VERIFY_LIST }$t"; done; }

usage(){ cat <<EOF
${BLD}pentera-helper${RST} — all-in-one: diagnose failures, seamless network setup, sane clock & certs.

${BLD}DIAGNOSE${RST}
  diagnose [--net|--iface|--time]   Why did it fail? service/power/network/interface/time/verdict.
  status                            Read-only overview, incl. staged change + last verification.

${BLD}NETWORK${RST}  (dry-run unless --apply; --apply writes the config and REBOOTS)
  wizard                            Interactive Pentera-style setup (static/DHCP).
  set-static --ip A.B.C.D --cidr N --gw G [--dns "a,b"] [--iface IF] [--verify-ip "a,b"] [--apply] [--no-reboot]
  set-dhcp   [--iface IF] [--dns "a,b"] [--verify-ip "a,b"] [--apply] [--no-reboot]
  sync-iface [--iface IF] [--verify-ip "a,b"] [--apply] [--no-reboot]   Realign management/attack/compose to the NIC.
  Every change also syncs the interface into netplan + network.conf + compose.

${BLD}HOW --apply WORKS${RST}
  1. backs up netplan + network.conf + compose, writes the new config
  2. sets the hardware clock to the current UTC so the next boot starts on the right time
  3. reboots (10s countdown; --no-reboot = apply on the next reboot instead)
  4. after boot it checks itself (ping, or ARP if ping is blocked):
       gateway answers within ${NET_WAIT}s -> change KEPT
       gateway silent, old network still there   -> old config restored + one more reboot (max 1, never a loop)
       gateway silent, you moved networks        -> new config KEPT (the old one could not work here); fix at the console
     --verify-ip 10.20.0.5,8.8.8.8 adds hosts to ping: the change passes if the gateway OR any of them answers.
       isolated VLAN (no internet): give a neighbour on that VLAN.  Internet but the gateway blocks ping: give 8.8.8.8.
     future-dated certificates found after boot -> regenerated automatically
  Result: 'pentera-helper status'.  commit = keep a staged change without the check; rollback = restore last backup.

${BLD}TIME & CERTIFICATES${RST}  (dual-boot: Windows stores LOCAL time in the hardware clock)
  fix-time [--tz Area/City] [--rtc local|utc|auto]
                                    ntp iburst + Pentera waits for NTP before starting + timezone +
                                    RTC mode (auto = LOCAL when a Windows partition exists, so both OSes agree).
                                    e.g.  sudo pentera-helper fix-time --tz Asia/Manila --rtc local
  regen-certs [--force]             Re-mint the node/UI certs with the current clock (CA untouched).

${BLD}SETUP${RST}
  install                           Copy to $SELF and run fix-time.
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
  diagnose|why) cmd_diagnose "$@" ;;
  status)   cmd_status ;;
  wizard)   cmd_wizard ;;
  set-dhcp|set-static|sync-iface)
    parse_opts "$@"; IFACE=${IFACE:-$(primary_iface)}
    if [ "$cmd" = set-static ]; then
      [ -n "$IP" ] && [ -n "$CIDR" ] && [ -n "$GW" ] || die "set-static needs --ip, --cidr and --gw"
      valid_ip "$IP" || die "bad --ip"; valid_ip "$GW" || die "bad --gw"
      why_bad=$(gw_check "$IP" "$CIDR" "$GW") || die "$why_bad"
    fi
    [ "$APPLY" = 1 ] && { need_root "$cmd"; BK=$(make_backup); }
    case "$cmd" in
      set-static) plan_netplan static "$IFACE" "$IP" "$CIDR" "$GW" "$DNS" "$APPLY" ;;
      set-dhcp)   plan_netplan dhcp   "$IFACE" "" "" "" "$DNS" "$APPLY"; GW="" ;;
      sync-iface) GW=$(default_gw) ;;
    esac
    plan_roles "$IFACE" "$APPLY"
    if [ "$APPLY" = 1 ]; then stage_reboot "$BK" "$GW" "$IFACE"; else dry_note; fi ;;
  fix-time)    cmd_fix_time "$@" ;;
  regen-certs) cmd_regen_certs "$@" ;;
  verify-boot) cmd_verify_boot ;;
  commit)   cmd_commit ;;
  rollback) cmd_rollback ;;
  install)  need_root install; install_self; printf "installed %s\n" "$SELF"; cmd_fix_time ;;
  help|-h|--help) usage ;;
  *) die "unknown command '$cmd' (try: pentera-helper help)" ;;
esac
