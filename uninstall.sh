#!/usr/bin/env bash
set -euo pipefail

KEEP_CONFIG=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./uninstall.sh [--keep-config]

Options:
  --keep-config   Keep /etc/ugreen-fan.conf and it87 module config files.
EOF
}

die() {
  printf 'uninstall.sh: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-config)
      KEEP_CONFIG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root, for example with sudo"

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now ugreen-fan-auto.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ugreen-fan-auto.service
  systemctl daemon-reload || true
fi

rm -f /usr/local/bin/fan /usr/local/sbin/ugreen-fan-mode

if [ "$KEEP_CONFIG" -eq 0 ]; then
  rm -f /etc/ugreen-fan.conf /etc/modules-load.d/it87.conf /etc/modprobe.d/it87.conf
fi

printf '%s\n' 'Uninstalled ugreen-dxp-fan-cli.'
