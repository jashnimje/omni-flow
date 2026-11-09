#!/bin/bash
# Runs the native core tests, then compiles the sketch for every supported
# board. Needs a C++ compiler and arduino-cli with the four cores installed
# (see README.md). Build output goes to ~/.cache/omniflow/firmware.
set -euo pipefail
cd "$(dirname "$0")"
out="${HOME}/.cache/omniflow/firmware"
mkdir -p "$out"

flags=(-std=c++11 -Wall -Wextra -Werror)
c++ "${flags[@]}" -o "$out/core_test" host/core_test.cpp omni_core.cpp
"$out/core_test"
# The same tests with the Uno's limits, which are the tightest.
c++ "${flags[@]}" -DOMNI_SMALL -o "$out/core_test_small" host/core_test.cpp omni_core.cpp
"$out/core_test_small"
c++ "${flags[@]}" -o "$out/host_board" host/host_board.cpp omni_core.cpp
# The virtual board keeps the firmware's line limit and records the password.
long_line="$(printf 'x%.0s' {1..250})"
# It also reports RF sends, and an output can start high (an active-low relay).
printf '%s\n' "$long_line" '{"cmd":"sim.set"}' \
  '{"cmd":"wifi.set","ssid":"net","password":"password1","id":1}' '{"cmd":"wifi.status","id":2}' \
  '{"cmd":"pin.mode","pin":4,"mode":"out","value":1,"id":3}' '{"cmd":"rf.send","code":5393,"bits":24,"id":4}' |
  "$out/host_board" --node bench > "$out/host_board.out"
grep -q '"message":"line too long"' "$out/host_board.out"
grep -q '"event":"sim.ack"' "$out/host_board.out"
grep -q '"connected":true,"ip":"127.0.0.1".*"passwordLength":9,"id":2' "$out/host_board.out"
grep -q '"cmd":"pin.mode","pin":4,"value":1,"id":3' "$out/host_board.out"
grep -q '"event":"sim.rf","protocol":1,"code":5393,"bits":24,"repeat":10' "$out/host_board.out"
grep -q '"cmd":"rf.send","id":4' "$out/host_board.out"
echo "host board checks passed"

for fqbn in arduino:avr:uno esp8266:esp8266:nodemcuv2 rp2040:rp2040:rpipicow esp32:esp32:esp32; do
  echo "== $fqbn"
  build="$out/${fqbn//:/_}"
  log="$build.log"
  mkdir -p "$build"
  /bin/rm -f "$build"/omniflow_node.ino.*
  arduino-cli compile --fqbn "$fqbn" --warnings all --build-path "$build" . > "$log" 2>&1 || {
    cat "$log"
    exit 1
  }
  grep -E "Sketch uses|Global variables|IRAM" "$log" || true
  # A warning in the sketch's own files fails the check; the cores' do not.
  if grep -E "(omni_core|omniflow_node)[^ :]*:[0-9]+:[0-9]+: warning:" "$log"; then
    exit 1
  fi
  test -n "$(find "$build" -maxdepth 1 -name 'omniflow_node.ino.*')"
done
echo "all firmware checks passed"
