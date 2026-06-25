#!/usr/bin/env bash
set -euo pipefail

PREFIX="${UGREEN_FAN_PREFIX:-/usr/local}"
ETC_DIR="${UGREEN_FAN_ETC_DIR:-/etc}"
CONFIG_FILE="${UGREEN_FAN_CONFIG:-$ETC_DIR/ugreen-fan.conf}"
SYSTEMD_DIR="${UGREEN_FAN_SYSTEMD_DIR:-$ETC_DIR/systemd/system}"
MODULES_LOAD_DIR="${UGREEN_FAN_MODULES_LOAD_DIR:-$ETC_DIR/modules-load.d}"
MODPROBE_DIR="${UGREEN_FAN_MODPROBE_DIR:-$ETC_DIR/modprobe.d}"
VAR_LIB_DIR="${UGREEN_FAN_VAR_LIB_DIR:-/var/lib/ugreen-fan}"
HISTORY_FILE="${UGREEN_FAN_HISTORY:-$VAR_LIB_DIR/history.tsv}"
SERVICE_FAN_BIN="${UGREEN_FAN_SERVICE_BIN:-$PREFIX/bin/fan}"
TARGET_C=35
ENABLE_SERVICE=1
START_NOW=1
WRITE_MODULE_CONFIG=1
DISABLE_EMPTY_FANCONTROL=1
GRAPH_ENABLED=1
GRAPH_INTERVAL_SEC=10
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
  --no-graph           Do not enable graph history collection.
  --graph-interval 10  Graph collection interval in seconds. Default: 10.
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
    --no-graph)
      GRAPH_ENABLED=0
      shift
      ;;
    --graph-interval)
      [ "$#" -ge 2 ] || die "--graph-interval requires a value"
      GRAPH_INTERVAL_SEC="$2"
      shift 2
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
[[ "$GRAPH_INTERVAL_SEC" =~ ^[0-9]+$ ]] || die "--graph-interval must be a number"
[ "$GRAPH_INTERVAL_SEC" -ge 5 ] && [ "$GRAPH_INTERVAL_SEC" -le 3600 ] || die "--graph-interval must be from 5 to 3600"

if [ "$(id -u)" -ne 0 ] && [ "${UGREEN_FAN_ALLOW_NONROOT:-0}" != "1" ]; then
  die "run as root, for example with sudo"
fi
command -v install >/dev/null 2>&1 || die "install command not found"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
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

set_config_key() {
  local key="$1"
  local value="$2"
  local tmp

  tmp="$(mktemp "$(dirname "$CONFIG_FILE")/.ugreen-fan.conf.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$CONFIG_FILE" > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
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

info "Writing $CONFIG_FILE"
install -d "$(dirname "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<EOF
# UGREEN DXP fan CLI config
# AUTO_TARGET_C is used by 'fan auto' and ugreen-fan-auto.service at boot.
AUTO_TARGET_C=$TARGET_C
CHANNELS="pwm2 pwm3"
GRAPH_ENABLED=$GRAPH_ENABLED
GRAPH_INTERVAL_SEC=$GRAPH_INTERVAL_SEC
HISTORY_FILE="$HISTORY_FILE"
EOF
  chmod 0644 "$CONFIG_FILE"
else
  set_config_key AUTO_TARGET_C "$TARGET_C"
  if ! grep -q '^CHANNELS=' "$CONFIG_FILE"; then
    printf '%s\n' 'CHANNELS="pwm2 pwm3"' >> "$CONFIG_FILE"
  fi
  set_config_key GRAPH_ENABLED "$GRAPH_ENABLED"
  set_config_key GRAPH_INTERVAL_SEC "$GRAPH_INTERVAL_SEC"
  set_config_key HISTORY_FILE "\"$HISTORY_FILE\""
fi

if [ "$WRITE_MODULE_CONFIG" -eq 1 ]; then
  info "Writing it87 module config"
  install -d "$MODULES_LOAD_DIR" "$MODPROBE_DIR"
  cat > "$MODULES_LOAD_DIR/it87.conf" <<'EOF'
# Load UGREEN DXP IT8613E hwmon driver at boot.
it87
EOF
  cat > "$MODPROBE_DIR/it87.conf" <<'EOF'
# UGREEN DXP NAS boards can have ACPI claiming the IT8613E I/O region.
options it87 ignore_resource_conflict=1
EOF
fi

info "Writing systemd service"
install -d "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/ugreen-fan-auto.service" <<EOF
[Unit]
Description=Apply UGREEN DXP automatic fan curve
After=systemd-modules-load.service coolercontrold.service
Before=fancontrol.service
ConditionPathExists=$SERVICE_FAN_BIN

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'command -v modprobe >/dev/null 2>&1 && modprobe it87 ignore_resource_conflict=1 || true'
ExecStart=$SERVICE_FAN_BIN auto

[Install]
WantedBy=multi-user.target
EOF

info "Writing graph collection service"
cat > "$SYSTEMD_DIR/ugreen-fan-graph.service" <<EOF
[Unit]
Description=Collect UGREEN DXP fan and temperature graph sample
After=systemd-modules-load.service
ConditionPathExists=$SERVICE_FAN_BIN

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=$SERVICE_FAN_BIN graph collect
EOF

cat > "$SYSTEMD_DIR/ugreen-fan-graph.timer" <<EOF
[Unit]
Description=Collect UGREEN DXP fan and temperature graph history

[Timer]
OnBootSec=30s
OnUnitActiveSec=${GRAPH_INTERVAL_SEC}s
AccuracySec=1s
Persistent=false
Unit=ugreen-fan-graph.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

if [ "$DISABLE_EMPTY_FANCONTROL" -eq 1 ] &&
   systemctl list-unit-files fancontrol.service >/dev/null 2>&1 &&
   [ ! -s "$ETC_DIR/fancontrol" ]; then
  info "Disabling empty fancontrol.service"
  systemctl disable --now fancontrol.service >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet coolercontrold.service 2>/dev/null; then
  printf '%s\n' "install.sh: warning: coolercontrold.service is active. If it controls these fans, it can override fan settings." >&2
fi

if [ "$ENABLE_SERVICE" -eq 1 ]; then
  info "Enabling ugreen-fan-auto.service"
  systemctl enable ugreen-fan-auto.service >/dev/null
  if [ "$GRAPH_ENABLED" -eq 1 ]; then
    info "Enabling ugreen-fan-graph.timer"
    systemctl enable ugreen-fan-graph.timer >/dev/null
  fi
fi

if [ "$START_NOW" -eq 1 ]; then
  info "Applying auto mode now"
  systemctl restart ugreen-fan-auto.service
  if [ "$GRAPH_ENABLED" -eq 1 ]; then
    info "Starting graph collection"
    systemctl restart ugreen-fan-graph.timer
    systemctl start ugreen-fan-graph.service >/dev/null 2>&1 || true
  fi
fi

info "Installed. Try: fan status"
