#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl'
printf ' %s' "$@"
printf '\n'
printf 'systemctl' >> "$SYSTEMCTL_LOG"
printf ' %s' "$@" >> "$SYSTEMCTL_LOG"
printf '\n' >> "$SYSTEMCTL_LOG"

if [ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ]; then
  exit 1
fi

exit 0
EOF

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$output" ] || exit 2
cp "$FAKE_CURL_SOURCE" "$output"
EOF

chmod +x "$FAKE_BIN/systemctl" "$FAKE_BIN/curl"

run_env() {
  local root="$1"
  shift

  env \
    PATH="$FAKE_BIN:$PATH" \
    SYSTEMCTL_LOG="$root/systemctl.log" \
    FAKE_CURL_SOURCE="$ROOT_DIR/fan" \
    UGREEN_FAN_ALLOW_NONROOT=1 \
    UGREEN_FAN_PREFIX="$root/usr/local" \
    UGREEN_FAN_ETC_DIR="$root/etc" \
    UGREEN_FAN_VAR_LIB_DIR="$root/var/lib/ugreen-fan" \
    "$@"
}

assert_file() {
  [ -f "$1" ] || {
    printf 'missing file: %s\n' "$1" >&2
    exit 1
  }
}

assert_no_file() {
  [ ! -e "$1" ] || {
    printf 'expected file to be removed: %s\n' "$1" >&2
    exit 1
  }
}

assert_grep() {
  local pattern="$1"
  local file="$2"

  grep -q -- "$pattern" "$file" || {
    printf 'missing pattern %s in %s\n' "$pattern" "$file" >&2
    exit 1
  }
}

install_root="$TMP_DIR/install-root"
mkdir -p "$install_root"

run_env "$install_root" bash "$ROOT_DIR/install.sh" --target 40 --graph-interval 15 >/dev/null

assert_file "$install_root/usr/local/bin/fan"
[ -x "$install_root/usr/local/bin/fan" ]
[ -L "$install_root/usr/local/sbin/ugreen-fan-mode" ]
assert_file "$install_root/etc/ugreen-fan.conf"
assert_file "$install_root/etc/modules-load.d/it87.conf"
assert_file "$install_root/etc/modprobe.d/it87.conf"
assert_file "$install_root/etc/systemd/system/ugreen-fan-auto.service"
assert_file "$install_root/etc/systemd/system/ugreen-fan-graph.service"
assert_file "$install_root/etc/systemd/system/ugreen-fan-graph.timer"

assert_grep '^AUTO_TARGET_C=40$' "$install_root/etc/ugreen-fan.conf"
assert_grep '^GRAPH_ENABLED=1$' "$install_root/etc/ugreen-fan.conf"
assert_grep '^GRAPH_INTERVAL_SEC=15$' "$install_root/etc/ugreen-fan.conf"
assert_grep "HISTORY_FILE=\"$install_root/var/lib/ugreen-fan/history.tsv\"" "$install_root/etc/ugreen-fan.conf"
assert_grep "ConditionPathExists=$install_root/usr/local/bin/fan" "$install_root/etc/systemd/system/ugreen-fan-auto.service"
assert_grep "ExecStart=$install_root/usr/local/bin/fan auto" "$install_root/etc/systemd/system/ugreen-fan-auto.service"
assert_grep "ExecStart=$install_root/usr/local/bin/fan graph collect" "$install_root/etc/systemd/system/ugreen-fan-graph.service"
assert_grep '^OnUnitActiveSec=15s$' "$install_root/etc/systemd/system/ugreen-fan-graph.timer"
assert_grep 'systemctl enable ugreen-fan-auto.service' "$install_root/systemctl.log"
assert_grep 'systemctl enable ugreen-fan-graph.timer' "$install_root/systemctl.log"
assert_grep 'systemctl restart ugreen-fan-auto.service' "$install_root/systemctl.log"
assert_grep 'systemctl restart ugreen-fan-graph.timer' "$install_root/systemctl.log"

: > "$install_root/systemctl.log"
run_env "$install_root" bash "$ROOT_DIR/install.sh" --target 41 --graph-interval 20 --no-start >/dev/null

assert_grep '^AUTO_TARGET_C=41$' "$install_root/etc/ugreen-fan.conf"
assert_grep '^GRAPH_INTERVAL_SEC=20$' "$install_root/etc/ugreen-fan.conf"
[ "$(grep -c '^AUTO_TARGET_C=' "$install_root/etc/ugreen-fan.conf")" -eq 1 ]
[ "$(grep -c '^GRAPH_INTERVAL_SEC=' "$install_root/etc/ugreen-fan.conf")" -eq 1 ]
assert_grep '^OnUnitActiveSec=20s$' "$install_root/etc/systemd/system/ugreen-fan-graph.timer"
if grep -q 'systemctl restart ugreen-fan-auto.service' "$install_root/systemctl.log"; then
  printf 'install --no-start should not restart auto service\n' >&2
  exit 1
fi

stdin_root="$TMP_DIR/stdin-root"
mkdir -p "$stdin_root/work"
(
  cd "$stdin_root/work"
  run_env "$stdin_root" bash -s -- --target 38 --graph-interval 30 --no-start < "$ROOT_DIR/install.sh" >/dev/null
)

assert_file "$stdin_root/usr/local/bin/fan"
assert_grep '^AUTO_TARGET_C=38$' "$stdin_root/etc/ugreen-fan.conf"
assert_grep '^OnUnitActiveSec=30s$' "$stdin_root/etc/systemd/system/ugreen-fan-graph.timer"

mkdir -p "$install_root/var/lib/ugreen-fan"
printf 'sample\n' > "$install_root/var/lib/ugreen-fan/history.tsv"
: > "$install_root/systemctl.log"
run_env "$install_root" bash "$ROOT_DIR/uninstall.sh" >/dev/null

assert_no_file "$install_root/usr/local/bin/fan"
assert_no_file "$install_root/usr/local/sbin/ugreen-fan-mode"
assert_no_file "$install_root/etc/ugreen-fan.conf"
assert_no_file "$install_root/etc/modules-load.d/it87.conf"
assert_no_file "$install_root/etc/modprobe.d/it87.conf"
assert_no_file "$install_root/etc/systemd/system/ugreen-fan-auto.service"
assert_no_file "$install_root/etc/systemd/system/ugreen-fan-graph.service"
assert_no_file "$install_root/etc/systemd/system/ugreen-fan-graph.timer"
assert_no_file "$install_root/var/lib/ugreen-fan"
assert_grep 'systemctl disable --now ugreen-fan-graph.timer' "$install_root/systemctl.log"
assert_grep 'systemctl disable --now ugreen-fan-auto.service' "$install_root/systemctl.log"

printf '%s\n' 'install tests passed'
