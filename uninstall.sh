#!/usr/bin/env bash
set -euo pipefail

PREFIX="${UGREEN_FAN_PREFIX:-/usr/local}"
ETC_DIR="${UGREEN_FAN_ETC_DIR:-/etc}"
CONFIG_FILE="${UGREEN_FAN_CONFIG:-$ETC_DIR/ugreen-fan.conf}"
SYSTEMD_DIR="${UGREEN_FAN_SYSTEMD_DIR:-$ETC_DIR/systemd/system}"
MODULES_LOAD_DIR="${UGREEN_FAN_MODULES_LOAD_DIR:-$ETC_DIR/modules-load.d}"
MODPROBE_DIR="${UGREEN_FAN_MODPROBE_DIR:-$ETC_DIR/modprobe.d}"
VAR_LIB_DIR="${UGREEN_FAN_VAR_LIB_DIR:-/var/lib/ugreen-fan}"
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

if [ "$(id -u)" -ne 0 ] && [ "${UGREEN_FAN_ALLOW_NONROOT:-0}" != "1" ]; then
  die "run as root, for example with sudo"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now ugreen-fan-graph.timer >/dev/null 2>&1 || true
  systemctl disable --now ugreen-fan-auto.service >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/ugreen-fan-graph.timer"
  rm -f "$SYSTEMD_DIR/ugreen-fan-graph.service"
  rm -f "$SYSTEMD_DIR/ugreen-fan-auto.service"
  systemctl daemon-reload || true
fi

rm -f "$PREFIX/bin/fan" "$PREFIX/sbin/ugreen-fan-mode"

if [ "$KEEP_CONFIG" -eq 0 ]; then
  rm -f "$CONFIG_FILE" "$MODULES_LOAD_DIR/it87.conf" "$MODPROBE_DIR/it87.conf"
  rm -rf "$VAR_LIB_DIR"
fi

printf '%s\n' 'Uninstalled ugreen-dxp-fan-cli.'
