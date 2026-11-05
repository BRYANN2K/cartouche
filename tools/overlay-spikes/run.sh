#!/bin/sh
# One spike run: the Wine stand-in on the built-in screen and Spike.app's panel, side by side.
# Usage: run.sh <name> "<standin args>" "<spike panel args>" [native|wine-fullscreen]
#   standin args: x y w h seconds [popup] [capture|aggressive] [activate]
#   native: runs the native stand-in instead (standin args are then "--mode M --seconds S")
# CAPTURE=<png> [CAPTURE_AT=<s>] also screenshots the game and panel windows, nothing else.
# Logs go to $LOGS/<name>.log, merged by time. The frontmost app and the pointer are put back.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../out/overlay-spikes"
spike="$out/Spike.app/Contents/MacOS/spike"
logs="${LOGS:-/tmp/overlay-spikes-logs}"
name="$1"; game_args="$2"; panel_args="$3"; kind="${4:-wine}"
mkdir -p "$logs"
if [ -z "${CARTOUCHE_GPU_LOCK_HELD:-}" ]; then
  while ! mkdir /tmp/cartouche-gpu.lock 2> /dev/null; do sleep 5; done
  trap 'rmdir /tmp/cartouche-gpu.lock 2> /dev/null' EXIT INT TERM
  export CARTOUCHE_GPU_LOCK_HELD=1
fi
support="$HOME/Library/Application Support/Cartouche"
root="$support/runners/.graphics/wine-crossover-26.3.0-2/dxmt"
prefix="$HOME/Library/Caches/cartouche-overlay-spike-prefix"
[ -d "$prefix" ] || cp -cR "$support/prefix-template" "$prefix"
front=$("$spike" frontmost)
pointer=$("$spike" cursor)
: > "$logs/$name.game"; : > "$logs/$name.panel"
if [ "$kind" = native ]; then
  # shellcheck disable=SC2086
  "$spike" native $game_args > "$logs/$name.game" 2>&1 &
  gpid=$!
  else
  export CX_ROOT="$root" CX_GRAPHICS_BACKEND=dxmt WINEPREFIX="$prefix" WINEDEBUG=-all
  export WINESERVER="$root/bin/wineserver" WINELOADER="$root/lib/wine/x86_64-unix/wine"
  [ -x "$WINELOADER" ] || WINELOADER="$root/bin/wine"
  # shellcheck disable=SC2086
  "$WINELOADER" "$out/standin.exe" $game_args > "$logs/$name.game" 2>&1 &
  gpid=$!
  fi
caffeinate -d -w "$gpid" &
( sleep 60; kill "$gpid" 2> /dev/null; [ "$kind" = native ] || "$WINESERVER" -k 2> /dev/null ) &
watchdog=$!
# Wine can take several seconds to start: the panel waits for the game's first line
i=0; while [ $i -lt 120 ] && ! grep -q 'start' "$logs/$name.game"; do sleep 0.25; i=$((i + 1)); done
if [ "$kind" = native ]; then wpid=$gpid; else wpid=$(pgrep -f 'standin.exe' | head -1); fi
sleep 0.5
"$spike" activate "$wpid" | sed 's/^\([0-9]*\) /\1 /' >> "$logs/$name.panel"
if [ "$kind" = wine-fullscreen ]; then
  sleep 1
  "$spike" fullscreen "$wpid" >> "$logs/$name.panel" 2>&1
  sleep 2
fi
# CAPTURE=<png> CAPTURE_AT=<s>: a screenshot of the game and panel windows only
if [ -n "${CAPTURE:-}" ]; then
  ( sleep "${CAPTURE_AT:-2}"; "$spike" capture "$CAPTURE" "$wpid" $(pgrep -f 'MacOS/spike panel') >> "$logs/$name.panel" 2>&1 ) &
fi
# shellcheck disable=SC2086
open -g -n -W --stdout "$logs/$name.panel.app" --stderr "$logs/$name.panel.app" "$out/Spike.app" --args panel --game-pid "$wpid" --restore "$front" $panel_args
kill "$gpid" 2> /dev/null
wait "$gpid" 2> /dev/null
[ "$kind" = native ] || "$WINESERVER" -w 2> /dev/null
kill "$watchdog" 2> /dev/null
"$spike" activate "$front" > /dev/null
# shellcheck disable=SC2086
"$spike" warp $pointer
cat "$logs/$name.panel.app" >> "$logs/$name.panel" 2> /dev/null; rm -f "$logs/$name.panel.app"
{ sed 's/^\([0-9]*\) /\1 game  /' "$logs/$name.game"; sed 's/^\([0-9]*\) /\1 panel /' "$logs/$name.panel"; } | grep -E '^[0-9]{13} ' | sort -n > "$logs/$name.log"
echo "== $name (frontmost restored: $("$spike" frontmost), was $front)"
cat "$logs/$name.log"
