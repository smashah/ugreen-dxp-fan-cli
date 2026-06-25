#!/usr/bin/env bash
set -euo pipefail

PREFIX="/usr/local"
TARGET_C=35
ENABLE_SERVICE=1
START_NOW=1
WRITE_MODULE_CONFIG=1
DISABLE_EMPTY_FANCONTROL=1
RAW_BASE_URL="${UGREEN_FAN_RAW_BASE_URL:-https://raw.githubusercontent.com/smashah/ugreen-dxp-fan-cli/main}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --target 35          Default auto target in Celsius. Default: 35.
  --no-enable          Install files but do not enable the boot service.
  --no-start           Do not apply auto mode immediately.
  --no-module-config   Do not write it87 modprobe/modules-load config.
  --keep-fancontrol    Do not disable fancontrol even if it has no config.
  -h, --help           Show this help.

This installer does not install the out-of-tree it87 driver. Install/load that
driver first, then run this installer.
EOF
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || die "--target requires a value"
      TARGET_C="$2"
      shift 2
      ;;
    --no-enable)
      ENABLE_SERVICE=0
      shift
      ;;
    --no-start)
      START_NOW=0
      shift
      ;;
    --no-module-config)
      WRITE_MODULE_CONFIG=0
      shift
      ;;
    --keep-fancontrol)
      DISABLE_EMPTY_FANCONTROL=0
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

[[ "$TARGET_C" =~ ^[0-9]+$ ]] || die "--target must be a number"
[ "$TARGET_C" -ge 20 ] && [ "$TARGET_C" -le 85 ] || die "--target must be from 20 to 85"

[ "$(id -u)" -eq 0 ] || die "run as root, for example with sudo"
command -v install >/dev/null 2>&1 || die "install command not found"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=""
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    die "curl or wget is required for one-line install"
  fi
}

if [ -f "$SCRIPT_DIR/fan" ]; then
  FAN_SOURCE="$SCRIPT_DIR/fan"
else
  info "Downloading fan CLI"
  TMP_DIR="$(mktemp -d)"
  FAN_SOURCE="$TMP_DIR/fan"
  download "$RAW_BASE_URL/fan" "$FAN_SOURCE"
fi

info "Installing fan CLI"
install -d "$PREFIX/bin" "$PREFIX/sbin"
install -m 0755 "$FAN_SOURCE" "$PREFIX/bin/fan"
ln -sfn "$PREFIX/bin/fan" "$PREFIX/sbin/ugreen-fan-mode"

info "Writing /etc/ugreen-fan.conf"
if [ ! -f /etc/ugreen-fan.conf ]; then
  cat > /etc/ugreen-fan.conf <<EOF
# UGREEN DXP fan CLI config
# AUTO_TARGET_C is used by 'fan auto' and ugreen-fan-auto.service at boot.
AUTO_TARGET_C=$TARGET_C
CHANNELS="pwm2 pwm3"
EOF
  chmod 0644 /etc/ugreen-fan.conf
else
  if grep -q '^AUTO_TARGET_C=' /etc/ugreen-fan.conf; then
    sed -i "s/^AUTO_TARGET_C=.*/AUTO_TARGET_C=$TARGET_C/" /etc/ugreen-fan.conf
  else
    printf 'AUTO_TARGET_C=%s\n' "$TARGET_C" >> /etc/ugreen-fan.conf
  fi
  if ! grep -q '^CHANNELS=' /etc/ugreen-fan.conf; then
    printf '%s\n' 'CHANNELS="pwm2 pwm3"' >> /etc/ugreen-fan.conf
  fi
fi

if [ "$WRITE_MODULE_CONFIG" -eq 1 ]; then
  info "Writing it87 module config"
  install -d /etc/modules-load.d /etc/modprobe.d
  cat > /etc/modules-load.d/it87.conf <<'EOF'
# Load UGREEN DXP IT8613E hwmon driver at boot.
it87
EOF
  cat > /etc/modprobe.d/it87.conf <<'EOF'
# UGREEN DXP NAS boards can have ACPI claiming the IT8613E I/O region.
options it87 ignore_resource_conflict=1
EOF
fi

info "Writing systemd service"
cat > /etc/systemd/system/ugreen-fan-auto.service <<'EOF'
[Unit]
Description=Apply UGREEN DXP automatic fan curve
After=systemd-modules-load.service coolercontrold.service
Before=fancontrol.service
ConditionPathExists=/usr/local/bin/fan

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'command -v modprobe >/dev/null 2>&1 && modprobe it87 ignore_resource_conflict=1 || true'
ExecStart=/usr/local/bin/fan auto

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if [ "$DISABLE_EMPTY_FANCONTROL" -eq 1 ] &&
   systemctl list-unit-files fancontrol.service >/dev/null 2>&1 &&
   [ ! -s /etc/fancontrol ]; then
  info "Disabling empty fancontrol.service"
  systemctl disable --now fancontrol.service >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet coolercontrold.service 2>/dev/null; then
  printf '%s\n' "install.sh: warning: coolercontrold.service is active. If it controls these fans, it can override fan settings." >&2
fi

if [ "$ENABLE_SERVICE" -eq 1 ]; then
  info "Enabling ugreen-fan-auto.service"
  systemctl enable ugreen-fan-auto.service >/dev/null
fi

if [ "$START_NOW" -eq 1 ]; then
  info "Applying auto mode now"
  systemctl start ugreen-fan-auto.service
fi

info "Installed. Try: fan status"
