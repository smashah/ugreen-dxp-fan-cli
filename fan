#!/usr/bin/env bash
set -euo pipefail

APP_NAME="fan"
DEFAULT_CONFIG_FILE="/etc/ugreen-fan.conf"
CONFIG_FILE="${UGREEN_FAN_CONFIG:-$DEFAULT_CONFIG_FILE}"
LOCK_FILE="${UGREEN_FAN_LOCK:-/run/ugreen-fan.lock}"
DEFAULT_TARGET_C=35
DEFAULT_CHANNELS="pwm2 pwm3"

usage() {
  cat <<'EOF'
Usage:
  fan
  fan status
  fan auto
  fan auto 35c
  fan 35c
  fan full
  fan max
  fan 255
  fan 50%
  fan manual 128
  fan off --yes

Modes:
  auto        Apply the saved hardware auto fan curve.
  35c         Save 35C as the auto target and apply the curve.
  full|max    Run fans at full speed.
  255         Set a raw manual PWM value from 0 to 255.
  50%         Set a manual percentage from 0% to 100%.
  off --yes   Set manual PWM 0. This can overheat the NAS.

Config:
  /etc/ugreen-fan.conf

Defaults target the UGREEN DXP4800 Plus IT8613E fan channels: pwm2 pwm3.
EOF
}

die() {
  printf '%s: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

warn() {
  printf '%s: warning: %s\n' "$APP_NAME" "$*" >&2
}

load_config() {
  AUTO_TARGET_C="$DEFAULT_TARGET_C"
  CHANNELS="$DEFAULT_CHANNELS"

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi

  validate_target "$AUTO_TARGET_C"
  validate_channels "$CHANNELS"
}

save_config() {
  local target_c="$1"
  local dir tmp

  dir="$(dirname "$CONFIG_FILE")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.ugreen-fan.conf.XXXXXX")"
  {
    printf '%s\n' '# UGREEN DXP fan CLI config'
    printf '%s\n' "# AUTO_TARGET_C is used by 'fan auto' and ugreen-fan-auto.service at boot."
    printf 'AUTO_TARGET_C=%s\n' "$target_c"
    printf 'CHANNELS=%q\n' "$CHANNELS"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

validate_target() {
  local target_c="$1"
  [[ "$target_c" =~ ^[0-9]+$ ]] || die "target temperature must be a number ending in c, for example 35c"
  [ "$target_c" -ge 20 ] && [ "$target_c" -le 85 ] || die "target temperature must be from 20c to 85c"
}

validate_pwm() {
  local pwm="$1"
  [[ "$pwm" =~ ^[0-9]+$ ]] || die "PWM value must be a number from 0 to 255"
  [ "$pwm" -ge 0 ] && [ "$pwm" -le 255 ] || die "PWM value must be from 0 to 255"
}

validate_percent() {
  local pct="$1"
  [[ "$pct" =~ ^[0-9]+$ ]] || die "percentage must be a number from 0% to 100%"
  [ "$pct" -ge 0 ] && [ "$pct" -le 100 ] || die "percentage must be from 0% to 100%"
}

validate_channels() {
  local channels="$1"
  local channel

  [ -n "$channels" ] || die "CHANNELS cannot be empty"
  for channel in $channels; do
    case "$channel" in
      pwm[0-9]*) ;;
      *) die "invalid channel name in CHANNELS: $channel" ;;
    esac
  done
}

percent_to_pwm() {
  local pct="$1"
  validate_percent "$pct"
  printf '%s\n' $(((pct * 255 + 50) / 100))
}

temp_arg_to_c() {
  local arg="$1"
  [[ "$arg" =~ ^([0-9]+)[cC]$ ]] || die "temperature must look like 35c"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

find_hwmon_once() {
  local dir name

  if [ -n "${UGREEN_FAN_HWMON:-}" ]; then
    [ -d "$UGREEN_FAN_HWMON" ] || die "UGREEN_FAN_HWMON does not exist: $UGREEN_FAN_HWMON"
    printf '%s\n' "$UGREEN_FAN_HWMON"
    return 0
  fi

  for dir in /sys/class/hwmon/hwmon*; do
    [ -f "$dir/name" ] || continue
    name="$(cat "$dir/name" 2>/dev/null || true)"
    case "$name" in
      it8613|it8613-*|it87)
        printf '%s\n' "$dir"
        return 0
        ;;
    esac
  done

  return 1
}

find_hwmon() {
  local end now hwmon

  if hwmon="$(find_hwmon_once)"; then
    printf '%s\n' "$hwmon"
    return 0
  fi

  end=$((SECONDS + 15))
  while [ "$SECONDS" -lt "$end" ]; do
    sleep 1
    if hwmon="$(find_hwmon_once)"; then
      printf '%s\n' "$hwmon"
      return 0
    fi
  done

  now="$(date +%H:%M:%S 2>/dev/null || true)"
  die "could not find IT8613E hwmon device at $now. Is the it87 module installed and loaded?"
}

read_attr() {
  local path="$1"
  [ -r "$path" ] || {
    printf '?'
    return 0
  }
  tr -d '\n' < "$path"
}

write_attr() {
  local path="$1"
  local value="$2"

  [ -e "$path" ] || die "missing hwmon attribute: $path"
  printf '%s\n' "$value" > "$path"
}

write_if_exists() {
  local path="$1"
  local value="$2"

  [ -e "$path" ] || return 0
  printf '%s\n' "$value" > "$path"
}

require_root_for_write() {
  if [ "$(id -u)" -ne 0 ] && [ -z "${UGREEN_FAN_HWMON:-}" ]; then
    die "run as root, for example with sudo"
  fi
}

check_channels_exist() {
  local hwmon="$1"
  local channel

  for channel in $CHANNELS; do
    [ -e "$hwmon/${channel}_enable" ] || die "$hwmon/${channel}_enable does not exist"
    [ -e "$hwmon/$channel" ] || die "$hwmon/$channel does not exist"
  done
}

mode_for_enable() {
  local enable="$1"

  case "$enable" in
    0) printf 'full' ;;
    1) printf 'manual' ;;
    2) printf 'auto' ;;
    *) printf 'unknown' ;;
  esac
}

print_auto_attr() {
  local hwmon="$1"
  local channel="$2"
  local name path

  for name in auto_channels_temp auto_start auto_slope auto_point1_temp auto_point2_temp auto_point3_temp; do
    path="$hwmon/${channel}_${name}"
    [ -e "$path" ] || continue
    printf '%-28s %s\n' "${channel}_${name}" "$(read_attr "$path")"
  done
}

status() {
  local hwmon="$1"
  local channel enable pwm fan_num fan_input

  printf 'mode: '
  if [ -n "${MODE_LABEL:-}" ]; then
    printf '%s\n' "$MODE_LABEL"
  else
    printf 'status target=%sc\n' "$AUTO_TARGET_C"
  fi
  printf 'hwmon: %s (%s)\n\n' "$hwmon" "$(read_attr "$hwmon/name")"

  printf '%-8s %-7s %-7s %-8s\n' 'channel' 'enable' 'pwm' 'rpm'
  for channel in $CHANNELS; do
    enable="$(read_attr "$hwmon/${channel}_enable")"
    pwm="$(read_attr "$hwmon/$channel")"
    fan_num="${channel#pwm}"
    fan_input="$hwmon/fan${fan_num}_input"
    printf '%-8s %-7s %-7s %-8s\n' "$channel" "$enable" "$pwm" "$(read_attr "$fan_input")"
  done

  printf '\n'
  for channel in $CHANNELS; do
    print_auto_attr "$hwmon" "$channel"
  done

  if [ "${UGREEN_FAN_SKIP_SENSORS:-0}" != "1" ] && command -v sensors >/dev/null 2>&1; then
    printf '\n'
    sensors 2>/dev/null || true
  fi
}

apply_full() {
  local hwmon="$1"
  local channel

  require_root_for_write
  check_channels_exist "$hwmon"
  for channel in $CHANNELS; do
    # For the it87 driver, pwm_enable=0 is full-speed mode.
    write_attr "$hwmon/${channel}_enable" 0
  done
}

apply_manual_pwm() {
  local hwmon="$1"
  local pwm="$2"
  local channel

  validate_pwm "$pwm"
  require_root_for_write
  check_channels_exist "$hwmon"
  for channel in $CHANNELS; do
    write_attr "$hwmon/${channel}_enable" 1
    write_attr "$hwmon/$channel" "$pwm"
  done
}

apply_auto_channel() {
  local hwmon="$1"
  local channel="$2"
  local temp_channel="$3"
  local point1="$4"
  local point2="$5"
  local point3="$6"
  local start_pwm="$7"
  local slope="$8"

  write_if_exists "$hwmon/${channel}_auto_channels_temp" "$temp_channel"
  write_if_exists "$hwmon/${channel}_auto_start" "$start_pwm"
  write_if_exists "$hwmon/${channel}_auto_slope" "$slope"
  write_if_exists "$hwmon/${channel}_auto_point1_temp" "$point1"
  write_if_exists "$hwmon/${channel}_auto_point2_temp" "$point2"
  write_if_exists "$hwmon/${channel}_auto_point3_temp" "$point3"
  write_attr "$hwmon/${channel}_enable" 2
}

apply_auto() {
  local hwmon="$1"
  local target_c="$2"
  local cpu_point1 cpu_point2 cpu_point3 case_point1 case_point2 case_point3
  local channel idx

  validate_target "$target_c"
  require_root_for_write
  check_channels_exist "$hwmon"

  cpu_point1=$(((target_c - 5) * 1000))
  cpu_point2=$((target_c * 1000))
  cpu_point3=$(((target_c + 20) * 1000))
  case_point1=$(((target_c - 10) * 1000))
  case_point2=$(((target_c - 3) * 1000))
  case_point3=$(((target_c + 7) * 1000))

  idx=0
  for channel in $CHANNELS; do
    idx=$((idx + 1))
    if [ "$idx" -eq 1 ]; then
      apply_auto_channel "$hwmon" "$channel" 1 "$cpu_point1" "$cpu_point2" "$cpu_point3" 180 16
    elif [ "$idx" -eq 2 ]; then
      apply_auto_channel "$hwmon" "$channel" 2 "$case_point1" "$case_point2" "$case_point3" 150 16
    else
      apply_auto_channel "$hwmon" "$channel" 1 "$cpu_point1" "$cpu_point2" "$cpu_point3" 180 16
    fi
  done
}

with_lock() {
  local lock_dir

  lock_dir="$(dirname "$LOCK_FILE")"
  mkdir -p "$lock_dir"
  exec 9>"$LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    flock 9
  else
    warn "flock not found; continuing without process lock"
  fi
  "$@"
}

main() {
  local command="${1:-status}"
  local arg="${2:-}"
  local yes=0
  local hwmon target_c pwm pct

  load_config

  case "$command" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        yes=1
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  hwmon="$(find_hwmon)"

  case "$command" in
    status|"")
      MODE_LABEL="status target=${AUTO_TARGET_C}c" status "$hwmon"
      ;;
    auto)
      if [ -n "$arg" ]; then
        target_c="$(temp_arg_to_c "$arg")"
        validate_target "$target_c"
        save_config "$target_c"
        AUTO_TARGET_C="$target_c"
      fi
      MODE_LABEL="auto target=${AUTO_TARGET_C}c"
      with_lock apply_auto "$hwmon" "$AUTO_TARGET_C"
      status "$hwmon"
      ;;
    full|max)
      MODE_LABEL="full"
      with_lock apply_full "$hwmon"
      status "$hwmon"
      ;;
    manual)
      [ -n "$arg" ] || die "manual mode requires a PWM value from 0 to 255"
      MODE_LABEL="manual pwm=$arg"
      with_lock apply_manual_pwm "$hwmon" "$arg"
      status "$hwmon"
      ;;
    off)
      [ "$yes" -eq 1 ] || die "off mode can overheat the NAS; rerun with --yes if this is intentional"
      MODE_LABEL="manual pwm=0"
      with_lock apply_manual_pwm "$hwmon" 0
      status "$hwmon"
      ;;
    *[cC])
      target_c="$(temp_arg_to_c "$command")"
      validate_target "$target_c"
      save_config "$target_c"
      AUTO_TARGET_C="$target_c"
      MODE_LABEL="auto target=${AUTO_TARGET_C}c"
      with_lock apply_auto "$hwmon" "$AUTO_TARGET_C"
      status "$hwmon"
      ;;
    *%)
      pct="${command%\%}"
      pwm="$(percent_to_pwm "$pct")"
      MODE_LABEL="manual ${pct}% pwm=$pwm"
      with_lock apply_manual_pwm "$hwmon" "$pwm"
      status "$hwmon"
      ;;
    [0-9]*)
      validate_pwm "$command"
      MODE_LABEL="$(if [ "$command" -eq 255 ]; then printf 'full pwm=255'; else printf 'manual pwm=%s' "$command"; fi)"
      with_lock apply_manual_pwm "$hwmon" "$command"
      status "$hwmon"
      ;;
    *)
      usage >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
