#!/usr/bin/env bash
set -euo pipefail

APP_NAME="fan"
DEFAULT_CONFIG_FILE="/etc/ugreen-fan.conf"
CONFIG_FILE="${UGREEN_FAN_CONFIG:-$DEFAULT_CONFIG_FILE}"
LOCK_FILE="${UGREEN_FAN_LOCK:-/run/ugreen-fan.lock}"
DEFAULT_TARGET_C=35
DEFAULT_CHANNELS="pwm2 pwm3"
DEFAULT_HISTORY_FILE="/var/lib/ugreen-fan/history.tsv"
DEFAULT_GRAPH_ENABLED=1
DEFAULT_GRAPH_INTERVAL_SEC=10
GRAPH_RETENTION_SEC=86400

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
  fan graph
  fan graph status
  fan graph on
  fan graph off
  fan graph interval 30

Modes:
  auto        Apply the saved hardware auto fan curve.
  35c         Save 35C as the auto target and apply the curve.
  full|max    Run fans at full speed.
  255         Set a raw manual PWM value from 0 to 255.
  50%         Set a manual percentage from 0% to 100%.
  off --yes   Set manual PWM 0. This can overheat the NAS.
  graph       Show the last 24h of collected fan and temperature history.

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
  HISTORY_FILE="$DEFAULT_HISTORY_FILE"
  GRAPH_ENABLED="$DEFAULT_GRAPH_ENABLED"
  GRAPH_INTERVAL_SEC="$DEFAULT_GRAPH_INTERVAL_SEC"

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi

  HISTORY_FILE="${UGREEN_FAN_HISTORY:-$HISTORY_FILE}"

  validate_target "$AUTO_TARGET_C"
  validate_channels "$CHANNELS"
  validate_graph_enabled "$GRAPH_ENABLED"
  validate_graph_interval "$GRAPH_INTERVAL_SEC"
}

save_config() {
  local target_c="$1"

  AUTO_TARGET_C="$target_c"
  save_config_all
}

save_config_all() {
  local dir tmp

  dir="$(dirname "$CONFIG_FILE")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.ugreen-fan.conf.XXXXXX")"
  {
    printf '%s\n' '# UGREEN DXP fan CLI config'
    printf '%s\n' "# AUTO_TARGET_C is used by 'fan auto' and ugreen-fan-auto.service at boot."
    printf 'AUTO_TARGET_C=%s\n' "$AUTO_TARGET_C"
    printf 'CHANNELS=%q\n' "$CHANNELS"
    printf '%s\n' "# Graph history is collected by ugreen-fan-graph.timer."
    printf 'GRAPH_ENABLED=%s\n' "$GRAPH_ENABLED"
    printf 'GRAPH_INTERVAL_SEC=%s\n' "$GRAPH_INTERVAL_SEC"
    printf 'HISTORY_FILE=%q\n' "$HISTORY_FILE"
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

validate_graph_enabled() {
  case "$1" in
    0|1) ;;
    *) die "GRAPH_ENABLED must be 0 or 1" ;;
  esac
}

validate_graph_interval() {
  local interval="$1"

  [[ "$interval" =~ ^[0-9]+$ ]] || die "graph interval must be a number of seconds"
  [ "$interval" -ge 5 ] && [ "$interval" -le 3600 ] || die "graph interval must be from 5 to 3600 seconds"
}

interval_arg_to_sec() {
  local arg="$1"

  arg="${arg%s}"
  arg="${arg%sec}"
  validate_graph_interval "$arg"
  printf '%s\n' "$arg"
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

current_epoch() {
  if [ -n "${UGREEN_FAN_NOW:-}" ]; then
    printf '%s\n' "$UGREEN_FAN_NOW"
  else
    date +%s
  fi
}

require_root_for_write() {
  if [ "$(id -u)" -ne 0 ] && [ -z "${UGREEN_FAN_HWMON:-}" ]; then
    die "run as root, for example with sudo"
  fi
}

require_root_for_graph_config() {
  if [ "$(id -u)" -ne 0 ] && [ -z "${UGREEN_FAN_CONFIG:-}" ]; then
    die "run as root, for example with sudo"
  fi
}

require_history_write() {
  if [ "$(id -u)" -ne 0 ] && [ -z "${UGREEN_FAN_HISTORY:-}" ]; then
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

prune_graph_history() {
  local epoch="$1"
  local cutoff dir tmp

  [ -f "$HISTORY_FILE" ] || return 0

  cutoff=$((epoch - GRAPH_RETENTION_SEC))
  dir="$(dirname "$HISTORY_FILE")"
  tmp="$(mktemp "$dir/.history.XXXXXX")"
  awk -v cutoff="$cutoff" '
    BEGIN { FS = "\t"; OFS = "\t" }
    $1 ~ /^[0-9]+$/ && $1 >= cutoff { print }
  ' "$HISTORY_FILE" > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$HISTORY_FILE"
}

collect_graph_sample() {
  local hwmon="$1"
  local epoch dir file label value

  [ "$GRAPH_ENABLED" -eq 1 ] || exit 0

  require_history_write
  dir="$(dirname "$HISTORY_FILE")"
  mkdir -p "$dir"

  epoch="$(current_epoch)"
  {
    printf '%s' "$epoch"
    for file in "$hwmon"/fan*_input "$hwmon"/temp*_input; do
      [ -e "$file" ] || continue
      label="$(basename "$file" _input)"
      value="$(read_attr "$file")"
      case "$value" in
        ''|*[!0-9-]*) continue ;;
      esac
      printf '\t%s=%s' "$label" "$value"
    done
    printf '\n'
  } >> "$HISTORY_FILE"

  prune_graph_history "$epoch"
  chmod 0644 "$HISTORY_FILE" 2>/dev/null || true
  printf 'collected graph sample at %s\n' "$epoch"
}

print_graph() {
  local now width

  now="$(current_epoch)"
  width="${UGREEN_FAN_GRAPH_WIDTH:-72}"
  [[ "$width" =~ ^[0-9]+$ ]] || die "UGREEN_FAN_GRAPH_WIDTH must be a number"
  [ "$width" -ge 20 ] && [ "$width" -le 160 ] || die "graph width must be from 20 to 160"

  [ -s "$HISTORY_FILE" ] || die "no graph history yet. Check 'fan graph status' or wait for the timer to collect samples."

  printf 'fan graph: last 24h, %ss poll interval, history %s\n' "$GRAPH_INTERVAL_SEC" "$HISTORY_FILE"
  awk -v now="$now" -v retention="$GRAPH_RETENTION_SEC" -v width="$width" '
    BEGIN {
      FS = "\t"
      palette = " .:-=+*#%@"
      plen = length(palette)
      since = now - retention
    }
    $1 !~ /^[0-9]+$/ { next }
    $1 < since { next }
    {
      rows++
      epoch = $1 + 0
      if (epoch > max_epoch) {
        max_epoch = epoch
      }
      bin = int((epoch - since) * width / retention)
      if (bin < 0) {
        bin = 0
      }
      if (bin >= width) {
        bin = width - 1
      }

      for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        key = kv[1]
        val = kv[2] + 0
        if (key !~ /^(fan|temp)[0-9]+$/) {
          continue
        }
        if (key ~ /^temp/) {
          val = val / 1000
        }
        if (!(key in seen)) {
          seen[key] = 1
          keys[++nkeys] = key
          min[key] = val
          max[key] = val
        }
        if (val < min[key]) {
          min[key] = val
        }
        if (val > max[key]) {
          max[key] = val
        }
        id = key SUBSEP bin
        sum[id] += val
        count[id]++
        latest[key] = val
      }
    }
    END {
      if (rows == 0) {
        print "no graph data for the last 24h"
        exit 2
      }
      printf "samples: %d, latest age: %ds\n\n", rows, now - max_epoch
      printf "%-6s %10s %-4s %10s %10s  %s\n", "series", "latest", "unit", "min", "max", "trend"
      for (k = 1; k <= nkeys; k++) {
        key = keys[k]
        unit = (key ~ /^temp/) ? "C" : "RPM"
        printf "%-6s %10.1f %-4s %10.1f %10.1f  |", key, latest[key], unit, min[key], max[key]
        for (b = 0; b < width; b++) {
          id = key SUBSEP b
          if (!(id in count)) {
            printf " "
            continue
          }
          val = sum[id] / count[id]
          if (max[key] == min[key]) {
            idx = plen
          } else {
            idx = int((val - min[key]) * (plen - 1) / (max[key] - min[key])) + 1
          }
          if (idx < 1) {
            idx = 1
          }
          if (idx > plen) {
            idx = plen
          }
          printf "%s", substr(palette, idx, 1)
        }
        printf "|\n"
      }
    }
  ' "$HISTORY_FILE"
}

graph_history_summary() {
  local now

  now="$(current_epoch)"
  if [ ! -s "$HISTORY_FILE" ]; then
    printf 'samples: 0\n'
    return 0
  fi

  awk -v now="$now" -v retention="$GRAPH_RETENTION_SEC" '
    BEGIN { FS = "\t"; since = now - retention }
    $1 ~ /^[0-9]+$/ && $1 >= since {
      rows++
      if (first == 0 || $1 < first) {
        first = $1
      }
      if ($1 > last) {
        last = $1
      }
    }
    END {
      printf "samples: %d\n", rows
      if (rows > 0) {
        printf "oldest_age_sec: %d\n", now - first
        printf "latest_age_sec: %d\n", now - last
      }
    }
  ' "$HISTORY_FILE"
}

write_graph_units() {
  require_root_for_graph_config
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

  cat > /etc/systemd/system/ugreen-fan-graph.service <<'EOF'
[Unit]
Description=Collect UGREEN DXP fan and temperature graph sample
After=systemd-modules-load.service
ConditionPathExists=/usr/local/bin/fan

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/bin/fan graph collect
EOF

  cat > /etc/systemd/system/ugreen-fan-graph.timer <<EOF
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
}

graph_status() {
  printf 'enabled: %s\n' "$GRAPH_ENABLED"
  printf 'interval_sec: %s\n' "$GRAPH_INTERVAL_SEC"
  printf 'retention_sec: %s\n' "$GRAPH_RETENTION_SEC"
  printf 'history: %s\n' "$HISTORY_FILE"
  graph_history_summary

  if command -v systemctl >/dev/null 2>&1; then
    printf 'timer_enabled: %s\n' "$(systemctl is-enabled ugreen-fan-graph.timer 2>/dev/null || true)"
    printf 'timer_active: %s\n' "$(systemctl is-active ugreen-fan-graph.timer 2>/dev/null || true)"
  fi
}

handle_graph() {
  local subcommand="${1:-show}"
  local value="${2:-}"
  local hwmon

  case "$subcommand" in
    show|"")
      print_graph
      ;;
    status)
      graph_status
      ;;
    collect)
      hwmon="$(find_hwmon)"
      collect_graph_sample "$hwmon"
      ;;
    on|enable)
      require_root_for_graph_config
      GRAPH_ENABLED=1
      save_config_all
      write_graph_units
      systemctl enable --now ugreen-fan-graph.timer >/dev/null
      systemctl start ugreen-fan-graph.service >/dev/null 2>&1 || true
      graph_status
      ;;
    off|disable)
      require_root_for_graph_config
      GRAPH_ENABLED=0
      save_config_all
      if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now ugreen-fan-graph.timer >/dev/null 2>&1 || true
      fi
      graph_status
      ;;
    interval)
      [ -n "$value" ] || die "usage: fan graph interval <seconds>"
      require_root_for_graph_config
      GRAPH_INTERVAL_SEC="$(interval_arg_to_sec "$value")"
      save_config_all
      write_graph_units
      if [ "$GRAPH_ENABLED" -eq 1 ]; then
        systemctl enable --now ugreen-fan-graph.timer >/dev/null
        systemctl restart ugreen-fan-graph.timer >/dev/null
      fi
      graph_status
      ;;
    *)
      die "unknown graph command: $subcommand"
      ;;
  esac
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

  if [ "$command" = "graph" ]; then
    shift || true
    handle_graph "$@"
    exit 0
  fi

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
