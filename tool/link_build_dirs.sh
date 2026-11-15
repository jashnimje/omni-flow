#!/bin/bash
# Puts every build output folder outside OneDrive. Each one becomes a link
# to ~/.cache/omniflow/<path>, so Flutter and Gradle find it where they
# expect it, and OneDrive syncs only the link, never gigabytes of build
# files with paths too long to upload.
#
# A folder that already exists as a real folder is left alone and named:
# delete it first (it only holds build output), then run this again.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cache="$HOME/.cache/omniflow"
dirs=(
  packages/omniflow_app/build
  packages/omniflow_app/android/.gradle
  packages/omniflow_app/android/build
  packages/omniflow_app/android/.kotlin
  tv_helper/build
  tv_helper/.gradle
  tv_helper/.kotlin
  firmware/omniflow_node/build
)
for d in "${dirs[@]}"; do
  path="$repo/$d"
  target="$cache/$d"
  mkdir -p "$target"
  if [ -L "$path" ]; then
    echo "linked   $d"
  elif [ -e "$path" ]; then
    echo "REAL     $d (delete it, then run again)"
  else
    mkdir -p "$(dirname "$path")"
    ln -s "$target" "$path"
    echo "made     $d -> $target"
  fi
done
