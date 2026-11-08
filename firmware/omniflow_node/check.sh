#!/bin/bash
# Runs the native core tests, then compiles the sketch for every supported
# board. Needs a C++ compiler and arduino-cli with the four cores installed
# (see README.md). Build output goes to ~/.cache/omniflow/firmware.
set -euo pipefail
cd "$(dirname "$0")"
out="${HOME}/.cache/omniflow/firmware"
mkdir -p "$out"

c++ -std=c++11 -Wall -Wextra -Werror -o "$out/core_test" host/core_test.cpp omni_core.cpp
"$out/core_test"
c++ -std=c++11 -Wall -Wextra -Werror -o "$out/host_board" host/host_board.cpp omni_core.cpp

for fqbn in arduino:avr:uno esp8266:esp8266:nodemcuv2 rp2040:rp2040:rpipicow esp32:esp32:esp32; do
  echo "== $fqbn"
  arduino-cli compile --fqbn "$fqbn" --warnings all --build-path "$out/${fqbn//:/_}" . 2>&1 |
    grep -E "error|warning: .*omni|Sketch uses|Global variables" || true
  test -n "$(find "$out/${fqbn//:/_}" -maxdepth 1 -name 'omniflow_node.ino.*' -newer omniflow_node.ino)"
done
echo "all firmware checks passed"
