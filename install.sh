#!/usr/bin/env bash
# install.sh — install pentera-helper on a Pentera main node (Ubuntu/Debian, systemd).
#
#   From a clone:  sudo ./install.sh [--tz Asia/Manila]
#   One-liner:     curl -fsSL https://raw.githubusercontent.com/d0gban/pentera-helper/main/install.sh \
#                    | sudo bash -s -- --tz Asia/Manila
#   Remove:        sudo ./install.sh --uninstall
#
# Options:
#   --tz Area/City     set the timezone (e.g. Asia/Manila); default: leave it alone
#   --rtc MODE         hardware-clock mode: auto (default; LOCAL when a Windows partition exists), local, utc
#   --no-fix-time      only install the helper, skip the time guardrails
#   --ref REF          git branch/tag to download (default: main)
#   --uninstall        remove the helper and its systemd bits (timezone/RTC/ntp.conf are left as they are)
#   --force            with --uninstall: continue even if a staged network change is pending
#
# Environment: PH_REPO=owner/repo  PH_REF=branch  GITHUB_TOKEN=<token, only for a private repo>
set -euo pipefail

REPO="${PH_REPO:-d0gban/pentera-helper}"
REF="${PH_REF:-main}"
BIN=/usr/local/sbin/pentera-helper
WAIT=/usr/local/sbin/pentera-wait-time
DROPIN_DIR=/etc/systemd/system/pentera.service.d
DROPIN=$DROPIN_DIR/10-wait-time-sync.conf
VERIFY_UNIT=/etc/systemd/system/pentera-helper-verify.service
PENDING=/etc/pentera/backup/helper/pending.env

TZ_SET=""; RTC=auto; FIX_TIME=1; UNINSTALL=0; FORCE=0
info(){ printf '\033[1m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die(){  printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do case "$1" in
  --tz)          [ $# -ge 2 ] || die "--tz needs a value"; TZ_SET=$2; shift 2 ;;
  --rtc)         [ $# -ge 2 ] || die "--rtc needs a value"; RTC=$2; shift 2 ;;
  --ref)         [ $# -ge 2 ] || die "--ref needs a value"; REF=$2; shift 2 ;;
  --no-fix-time) FIX_TIME=0; shift ;;
  --uninstall)   UNINSTALL=1; shift ;;
  --force)       FORCE=1; shift ;;
  -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac; done

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 ..."
command -v systemctl >/dev/null || die "systemd is required"

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$PENDING" ] && [ "$FORCE" != 1 ]; then
    die "a staged network change is pending ($PENDING). Finish it first (reboot, or: pentera-helper commit), or use --force."
  fi
  info "removing pentera-helper"
  systemctl disable pentera-helper-verify.service >/dev/null 2>&1 || true
  rm -f "$BIN" "$WAIT" "$DROPIN" "$VERIFY_UNIT"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  info "removed. Left in place: timezone / RTC mode, /etc/ntp.conf (backup: /etc/ntp.conf.bak-helper), backups in /etc/pentera/backup/helper"
  exit 0
fi

# ---------------------------------------------------------------- preflight
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *) warn "tested on Ubuntu 22.04 only (this is '${PRETTY_NAME:-unknown}')" ;; esac
[ -d /etc/pentera ] || warn "/etc/pentera not found — is this a Pentera main node? (diagnose and the network commands expect it)"
for c in ip netplan openssl; do command -v "$c" >/dev/null || warn "'$c' not found — some commands will not work"; done
command -v docker >/dev/null || warn "docker not found — node/cert checks will be limited"
[ -x /usr/sbin/ntp-wait ] || warn "ntp is not installed — the time guardrail can only log, not wait for sync (apt-get install ntp)"

# ---------------------------------------------------------------- get the script
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
src=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [ -f "$d/pentera-helper.sh" ] && src="$d/pentera-helper.sh"
fi
if [ -n "$src" ]; then
  info "using $src"; cp "$src" "$tmp"
else
  case "$REPO" in *__*) die "no local pentera-helper.sh next to install.sh and PH_REPO is not set (owner/repo)" ;; esac
  url="https://raw.githubusercontent.com/$REPO/$REF/pentera-helper.sh"
  info "downloading $url"
  auth=(); [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  if   command -v curl >/dev/null; then curl -fsSL ${auth[@]+"${auth[@]}"} "$url" -o "$tmp" || die "download failed ($url)"
  elif command -v wget >/dev/null; then wget -qO "$tmp" ${GITHUB_TOKEN:+--header="Authorization: Bearer $GITHUB_TOKEN"} "$url" || die "download failed ($url)"
  else die "need curl or wget"; fi
fi

head -n1 "$tmp" | grep -q '^#!.*bash' || die "downloaded file is not a bash script (wrong repo/ref, or a login page?)"
grep -q 'pentera-helper' "$tmp"         || die "downloaded file does not look like pentera-helper"
bash -n "$tmp"                          || die "downloaded script has a syntax error — not installing"

# ---------------------------------------------------------------- install
install -m 755 "$tmp" "$BIN"
info "installed $BIN  (sha256 $(sha256sum "$BIN" | cut -c1-16)…)"

if [ "$FIX_TIME" = 1 ]; then
  info "time guardrails"
  args=(fix-time --rtc "$RTC"); [ -n "$TZ_SET" ] && args+=(--tz "$TZ_SET")
  "$BIN" "${args[@]}"
fi

cat <<'EOF'

Done. Try:
  sudo pentera-helper diagnose        why did it fail? (always includes network info)
  sudo pentera-helper status          overview
  sudo pentera-helper wizard          network setup (static/DHCP), applied by reboot, self-verifying
  sudo pentera-helper help
EOF
