#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HWMON="$TMP_DIR/hwmon0"
CONF="$TMP_DIR/ugreen-fan.conf"
LOCK="$TMP_DIR/ugreen-fan.lock"
HISTORY="$TMP_DIR/history.tsv"

mkdir -p "$HWMON"
printf '%s\n' it8613 > "$HWMON/name"

for n in 2 3; do
  printf '%s\n' 1 > "$HWMON/pwm${n}_enable"
  printf '%s\n' 128 > "$HWMON/pwm${n}"
  printf '%s\n' 1900 > "$HWMON/fan${n}_input"
  printf '%s\n' 1 > "$HWMON/pwm${n}_auto_channels_temp"
  printf '%s\n' 100 > "$HWMON/pwm${n}_auto_start"
  printf '%s\n' 16 > "$HWMON/pwm${n}_auto_slope"
  printf '%s\n' 25000 > "$HWMON/pwm${n}_auto_point1_temp"
  printf '%s\n' 35000 > "$HWMON/pwm${n}_auto_point2_temp"
  printf '%s\n' 55000 > "$HWMON/pwm${n}_auto_point3_temp"
done
printf '%s\n' 49000 > "$HWMON/temp1_input"
printf '%s\n' 37000 > "$HWMON/temp2_input"
printf '%s\n' -128000 > "$HWMON/temp3_input"

export UGREEN_FAN_HWMON="$HWMON"
export UGREEN_FAN_CONFIG="$CONF"
export UGREEN_FAN_LOCK="$LOCK"
export UGREEN_FAN_HISTORY="$HISTORY"
export UGREEN_FAN_SKIP_SENSORS=1

"$ROOT_DIR/fan" status >/dev/null

"$ROOT_DIR/fan" 50% >/dev/null
[ "$(cat "$HWMON/pwm2")" = "128" ]
[ "$(cat "$HWMON/pwm2_enable")" = "1" ]
[ "$(cat "$HWMON/pwm3")" = "128" ]
[ "$(cat "$HWMON/pwm3_enable")" = "1" ]

"$ROOT_DIR/fan" 35c >/dev/null
[ "$(cat "$HWMON/pwm2_enable")" = "2" ]
[ "$(cat "$HWMON/pwm3_enable")" = "2" ]
[ "$(cat "$HWMON/pwm2_auto_point2_temp")" = "35000" ]
[ "$(cat "$HWMON/pwm3_auto_point3_temp")" = "42000" ]
grep -q '^AUTO_TARGET_C=35$' "$CONF"
grep -q '^CHANNELS=auto$' "$CONF"
it8613_status="$("$ROOT_DIR/fan" status)"
printf '%s\n' "$it8613_status" | grep -Eq '^pwm2 +2 +128 +1900 *$'

"$ROOT_DIR/fan" full >/dev/null
[ "$(cat "$HWMON/pwm2_enable")" = "0" ]
[ "$(cat "$HWMON/pwm3_enable")" = "0" ]

if "$ROOT_DIR/fan" off >/dev/null 2>&1; then
  printf '%s\n' 'fan off should require --yes' >&2
  exit 1
fi

"$ROOT_DIR/fan" off --yes >/dev/null
[ "$(cat "$HWMON/pwm2")" = "0" ]
[ "$(cat "$HWMON/pwm3")" = "0" ]

export UGREEN_FAN_NOW=100
"$ROOT_DIR/fan" graph collect >/dev/null
grep -q '^100	' "$HISTORY"
if grep -q 'temp3=' "$HISTORY"; then
  printf '%s\n' 'graph history kept invalid temp3 reading' >&2
  exit 1
fi

printf '%s\n' 2600 > "$HWMON/fan2_input"
printf '%s\n' 2100 > "$HWMON/fan3_input"
printf '%s\n' 53000 > "$HWMON/temp1_input"
printf '%s\n' 39000 > "$HWMON/temp2_input"
printf '%s\n' -128000 > "$HWMON/temp3_input"
export UGREEN_FAN_NOW=86501
"$ROOT_DIR/fan" graph collect >/dev/null
if grep -q '^100	' "$HISTORY"; then
  printf '%s\n' 'graph history kept data older than 24h' >&2
  exit 1
fi
grep -q '^86501	' "$HISTORY"

graph_status_output="$("$ROOT_DIR/fan" graph status)"
printf '%s\n' "$graph_status_output" | grep -q '^samples: 1$'
graph_output="$(UGREEN_FAN_GRAPH_WIDTH=20 "$ROOT_DIR/fan" graph)"
printf '%s\n' "$graph_output" | grep -q '^fan graph: last 24h'

# iDX6011 Pro: it5571 EC exposes pwm1-4 with enable 1=manual, 2=EC auto.
EC_HWMON="$TMP_DIR/hwmon1"
EC_CONF="$TMP_DIR/ugreen-fan-ec.conf"
mkdir -p "$EC_HWMON"
printf '%s\n' it5571 > "$EC_HWMON/name"
for n in 1 2 3 4; do
  printf '%s\n' 2 > "$EC_HWMON/pwm${n}_enable"
  printf '%s\n' 100 > "$EC_HWMON/pwm${n}"
  printf '%s\n' 1500 > "$EC_HWMON/fan${n}_input"
done
export UGREEN_FAN_HWMON="$EC_HWMON"
export UGREEN_FAN_CONFIG="$EC_CONF"

ec_status="$("$ROOT_DIR/fan" status)"
printf '%s\n' "$ec_status" | grep -q '^pwm4 '

"$ROOT_DIR/fan" 50% >/dev/null
for n in 1 2 3 4; do
  [ "$(cat "$EC_HWMON/pwm${n}_enable")" = "1" ]
  [ "$(cat "$EC_HWMON/pwm${n}")" = "128" ]
done

"$ROOT_DIR/fan" full >/dev/null
for n in 1 2 3 4; do
  [ "$(cat "$EC_HWMON/pwm${n}_enable")" = "1" ]
  [ "$(cat "$EC_HWMON/pwm${n}")" = "255" ]
done
ec_status="$("$ROOT_DIR/fan" status)"
printf '%s\n' "$ec_status" | grep -Eq '^pwm1 +1 +255 +1500 *$'

# Sentinel curve files expose any it8613 curve programming on the EC path.
for n in 1 2 3 4; do
  printf '%s\n' sentinel > "$EC_HWMON/pwm${n}_auto_start"
done
ec_auto_err="$("$ROOT_DIR/fan" 40c 2>&1 >/dev/null)"
printf '%s\n' "$ec_auto_err" | grep -q 'firmware curve'
for n in 1 2 3 4; do
  [ "$(cat "$EC_HWMON/pwm${n}_enable")" = "2" ]
  [ "$(cat "$EC_HWMON/pwm${n}")" = "255" ]
  [ "$(cat "$EC_HWMON/pwm${n}_auto_start")" = "sentinel" ]
done
ec_status="$("$ROOT_DIR/fan" status)"
printf '%s\n' "$ec_status" | grep -Eq '^pwm1 +2 +- +1500 *$'
rm -f "$EC_HWMON"/pwm*_auto_start
grep -q '^AUTO_TARGET_C=40$' "$EC_CONF"
grep -q '^CHANNELS=auto$' "$EC_CONF"

# A failed hand-back on one channel still releases the others.
"$ROOT_DIR/fan" 0% >/dev/null
rm "$EC_HWMON/pwm2_enable"
mkdir "$EC_HWMON/pwm2_enable"
if "$ROOT_DIR/fan" auto >/dev/null 2>&1; then
  printf '%s\n' 'fan auto should fail when a channel cannot be released' >&2
  exit 1
fi
for n in 1 3 4; do
  [ "$(cat "$EC_HWMON/pwm${n}_enable")" = "2" ]
done
rmdir "$EC_HWMON/pwm2_enable"
printf '%s\n' 2 > "$EC_HWMON/pwm2_enable"

printf 'CHANNELS="pwm1 pwm2"\n' > "$EC_CONF"
printf '%s\n' 2 > "$EC_HWMON/pwm3_enable"
"$ROOT_DIR/fan" 30% >/dev/null
[ "$(cat "$EC_HWMON/pwm1_enable")" = "1" ]
[ "$(cat "$EC_HWMON/pwm3_enable")" = "2" ]

printf '%s\n' 'smoke tests passed'
