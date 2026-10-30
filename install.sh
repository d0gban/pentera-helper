#!/bin/sh
# pentera-helper installer — Pentera main node (Ubuntu/Debian, systemd)
#
#   curl -fsSL https://raw.githubusercontent.com/d0gban/pentera-helper/main/install.sh | sudo sh
#   curl -fsSL .../install.sh | sudo sh -s -- --tz Asia/Manila
#
# Installs /usr/local/sbin/pentera-helper and runs `pentera-helper fix-time` (the time guardrails).
#
# Options:
#   --tz Area/City   set the timezone (e.g. Asia/Manila); default: leave it alone
#   --rtc MODE       hardware-clock mode: auto (default; LOCAL when a Windows partition exists), local, utc
#   --no-fix-time    only install the helper, skip the time guardrails
#   --ref REF        git branch/tag to install (default: main; env PH_REF)
#   --uninstall      remove the helper and its systemd bits (timezone/RTC/ntp.conf are left as they are)
#   --force          with --uninstall: continue even if a staged network change is pending
#   -h, --help       show this help
#
# Env: PH_REPO (owner/name), PH_REF, GITHUB_TOKEN (only for a private fork)

set -eu

REPO="${PH_REPO:-d0gban/pentera-helper}"
REF="${PH_REF:-main}"
BIN=/usr/local/sbin/pentera-helper
WAIT=/usr/local/sbin/pentera-wait-time
DROPIN_DIR=/etc/systemd/system/pentera.service.d
DROPIN=$DROPIN_DIR/10-wait-time-sync.conf
VERIFY_UNIT=/etc/systemd/system/pentera-helper-verify.service
PENDING=/etc/pentera/backup/helper/pending.env

TZ_SET=""; RTC=auto; FIX_TIME=1; UNINSTALL=0; FORCE=0

if [ -t 1 ]; then B=$(printf '\033[1m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B=""; Y=""; R=""; N=""; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<USAGE
Usage: curl -fsSL .../install.sh | sudo sh -s -- [options]
  --tz Area/City   set the timezone (e.g. Asia/Manila)
  --rtc MODE       hardware-clock mode: auto (default), local, utc
  --no-fix-time    only install the helper, skip the time guardrails
  --ref REF        git branch/tag (default: main)
  --uninstall      remove the helper and its systemd bits
  --force          with --uninstall: continue even if a network change is staged
Env: PH_REPO, PH_REF, GITHUB_TOKEN
USAGE
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case $1 in
        --tz)          [ $# -ge 2 ] || die "--tz needs a value"; TZ_SET=$2; shift 2 ;;
        --rtc)         [ $# -ge 2 ] || die "--rtc needs a value"; RTC=$2; shift 2 ;;
        --ref)         [ $# -ge 2 ] || die "--ref needs a value"; REF=$2; shift 2 ;;
        --no-fix-time) FIX_TIME=0; shift ;;
        --uninstall)   UNINSTALL=1; shift ;;
        --force)       FORCE=1; shift ;;
        -h|--help)     usage 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root:  curl -fsSL .../install.sh | sudo sh"
have systemctl || die "systemd is required"

# --- uninstall --------------------------------------------------------------
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

# --- preflight --------------------------------------------------------------
ID=""; PRETTY_NAME=""
[ -r /etc/os-release ] && . /etc/os-release
case $ID in ubuntu|debian) ;; *) warn "tested on Ubuntu 22.04 only (this is '${PRETTY_NAME:-unknown}')" ;; esac
[ -d /etc/pentera ] || warn "/etc/pentera not found — is this a Pentera main node? (diagnose and the network commands expect it)"
for c in bash ip netplan openssl; do have "$c" || warn "'$c' not found — some commands will not work"; done
have docker || warn "docker not found — node/cert checks will be limited"
[ -x /usr/sbin/ntp-wait ] || warn "ntp is not installed — the time guardrail can only log, not wait for sync (apt-get install ntp)"

# --- get the script ---------------------------------------------------------
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
src=""
# run from a clone (sh install.sh): use the pentera-helper.sh next to it. Piped, $0 is just "sh".
case $0 in */install.sh|install.sh) d=$(cd "$(dirname "$0")" && pwd); [ -f "$d/pentera-helper.sh" ] && src="$d/pentera-helper.sh" ;; esac
if [ -n "$src" ]; then
    info "using $src"; cp "$src" "$tmp"
else
    url="https://raw.githubusercontent.com/$REPO/$REF/pentera-helper.sh"
    info "downloading $url"
    if have curl; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$url" -o "$tmp" || die "download failed ($url)"
        else curl -fsSL "$url" -o "$tmp" || die "download failed ($url)"; fi
    elif have wget; then
        wget -qO "$tmp" ${GITHUB_TOKEN:+--header="Authorization: Bearer $GITHUB_TOKEN"} "$url" || die "download failed ($url)"
    else die "need curl or wget"; fi
fi

head -n1 "$tmp" | grep -q '^#!.*bash' || die "downloaded file is not a bash script (wrong repo/ref, or a login page?)"
grep -q 'pentera-helper' "$tmp"         || die "downloaded file does not look like pentera-helper"
bash -n "$tmp"                          || die "downloaded script has a syntax error — not installing"

# --- install ----------------------------------------------------------------
install -m 755 "$tmp" "$BIN"
info "installed $BIN  (sha256 $(sha256sum "$BIN" | cut -c1-16)…)"

if [ "$FIX_TIME" = 1 ]; then
    info "time guardrails"
    if [ -n "$TZ_SET" ]; then "$BIN" fix-time --rtc "$RTC" --tz "$TZ_SET"; else "$BIN" fix-time --rtc "$RTC"; fi
fi

cat <<'EOF'

Done. Try:
  sudo pentera-helper diagnose        why did it fail? (always includes network info)
  sudo pentera-helper status          overview
  sudo pentera-helper wizard          network setup (static/DHCP), applied by reboot, self-verifying
  sudo pentera-helper help
EOF
