#!/bin/sh
# The frame counter in a real Metal app, for each slice: a scene locked at 60 fps is
# counted at 60, a background app is marked, nothing is written without a session
# folder, the run script's probe sees the library, and a hardened binary refuses it
# while still running. Usage: counter.sh <fps-counter.dylib> <folder with fps-present.*>
set -u
counter="$1"
bin="$2"

fails=0
ran=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
runs() {
  if [ "$2" -eq 0 ] && [ "$3" -gt 0 ] 2>/dev/null; then ok "$1";
  else bad "$1" "exit 0 and presented frames" "$2 $3"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Data lines only, without the first and last second, which are partial
middle() { grep -v '^#' "$1" | sed '1d;$d'; }

for arch in arm64 x86_64; do
  app="$bin/fps-present.$arch"
  if ! "$app" locked 60 0 > /dev/null 2>&1; then
    echo "  $arch skipped: the test app does not run here (no Rosetta or no Metal device)"
    continue
  fi
  ran=$((ran + 1))
  echo "== $arch =="

  dir="$work/$arch/locked"
  mkdir -p "$dir"
  presented=$(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" locked 60 6)
  set -- "$dir"/samples-*
  is "$arch: one samples file for the one process that presents" 1 "$#"
  file="$1"
  is "$arch: the header names the slice" "arch=$arch" "$(sed -n 1p "$file" | tr ' ' '\n' | grep '^arch=')"
  lines=$(grep -vc '^#' "$file")
  [ "$lines" -ge 5 ] && ok "$arch: a line per second ($lines)" || bad "$arch: a line per second" ">= 5" "$lines"
  outside=$(middle "$file" | awk '$2 < 59 || $2 > 61' | wc -l | tr -d ' ')
  is "$arch: every whole second counts 60 +- 1" 0 "$outside"
  average=$(middle "$file" | awk '{ s += $2; n++ } END { printf "%.1f", s / n }')
  awk -v a="$average" 'BEGIN { exit !(a >= 59 && a <= 61) }' \
    && ok "$arch: average $average fps" || bad "$arch: average within 60 +- 1" "59..61" "$average"
  counted=$(grep -v '^#' "$file" | awk '{ s += $2 } END { print s }')
  # Frames after the last whole second are not written yet when the app exits
  [ "$counted" -le "$presented" ] && [ "$counted" -ge $((presented - 61)) ] \
    && ok "$arch: $counted of $presented presented frames counted" \
    || bad "$arch: counted frames match presented ones" "$presented - 61 .. $presented" "$counted"
  is "$arch: frontmost without AppKit" 0 "$(grep -v '^#' "$file" | awk '$3 != 1' | wc -l | tr -d ' ')"
  is "$arch: the drawable size" "1280 720" "$(grep -v '^#' "$file" | sed -n 2p | cut -d' ' -f4,5)"

  dir="$work/$arch/background"
  mkdir -p "$dir"
  DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" locked 60 3 --appkit > /dev/null
  set -- "$dir"/samples-*
  is "$arch: an app that is not active is marked as background" 0 \
    "$(grep -v '^#' "$1" | awk '$3 != 0' | wc -l | tr -d ' ')"

  dir="$work/$arch/none"
  mkdir -p "$dir"
  out=$(DYLD_INSERT_LIBRARIES="$counter" "$app" locked 60 1)
  runs "$arch: without a session folder the app still presents" "$?" "$out"
  is "$arch: without a session folder nothing is written" "" "$(ls "$dir")"
  out=$(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" locked 60 0)
  is "$arch: a process that presents nothing writes nothing" "0|" "$out|$(ls "$dir")"

  marker="$work/$arch/probe"
  DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_PROBE="$marker" "$app" locked 60 0 > /dev/null
  is "$arch: the probe marker names the slice" "$arch" "$(cat "$marker" 2>/dev/null)"

  hardened="$work/$arch/hardened"
  cp "$app" "$hardened"
  codesign -fs - -o runtime "$hardened" 2> /dev/null
  rm -f "$marker"
  dir="$work/$arch/refused"
  mkdir -p "$dir"
  out=$(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_PROBE="$marker" CARTOUCHE_FPS_DIR="$dir" "$hardened" locked 60 1)
  rc=$?
  runs "$arch: a hardened binary still runs" "$rc" "$out"
  is "$arch: and refuses the library: no marker, no samples" "no|" "$([ -f "$marker" ] && echo yes || echo no)|$(ls "$dir")"
done

if [ "$ran" -eq 0 ]; then
  echo "==> fps counter: no slice could run, so nothing was checked"
  exit 1
fi
if [ "$fails" -eq 0 ]; then
  echo "==> fps counter: all assertions hold on $ran slice(s)"
else
  echo "==> fps counter: $fails failed"
  exit 1
fi
