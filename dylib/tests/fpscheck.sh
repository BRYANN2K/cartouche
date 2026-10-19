#!/bin/sh
# The frame counter as the run script injects it (P8). Blocks are cut out of the script
# and run against scratch trees, with the Metal test app standing in for Wine's loader:
# one that takes the library, a hardened one that ignores it, and one that dyld kills
# when the library cannot load. The game starts in every case.
# Usage: fpscheck.sh <compat_run.sh> <fps-counter.dylib> <folder with fps-present.arm64>
# shellcheck disable=SC2034,SC2154,SC2016
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
counter_build="$2"
bin="$3"
[ -f "$SRC" ] || { echo "fpscheck: $SRC not present, skipped"; exit 0; }
[ -f "$counter_build" ] && [ -x "$bin/fps-present.arm64" ] \
  || { echo "FAIL: fpscheck needs the counter and the test app, run: make fpscheck"; exit 1; }

block=$(sed -n '/^fps_counter="\$np_support\/fps-counter.dylib"$/,/^prepare_fps >> "\$log" 2>&1 || true$/p' "$SRC")
launcher=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC")
open_args=$(sed -n '/^if \[ -n "\$fps_dir" \]; then$/,/^fi$/p' "$SRC")
ended=$(grep '^\[ -z "\$fps_dir" \] || echo "ended=' "$SRC")
[ -n "$block" ] && [ -n "$launcher" ] && [ -n "$open_args" ] && [ -n "$ended" ] \
  || { echo "FAIL: frame counter blocks not found in $SRC"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains $2" "$3" ;; esac; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/Cartouche"
mkdir -p "$np_support"
cp "$counter_build" "$np_support/fps-counter.dylib"
log="$work/run.log"

# Three stand-ins for Wine's loader
runner="$work/runner"
mkdir -p "$runner"
cp "$bin/fps-present.arm64" "$runner/accepting"
cp "$bin/fps-present.arm64" "$runner/hardened"
codesign -fs - -o runtime "$runner/hardened" 2> /dev/null
cp "$bin/fps-present.arm64" "$runner/killed"
# An x86_64-only counter cannot load in an arm64 loader, and dyld then kills the process
x86_counter="$work/x86-only.dylib"
lipo "$counter_build" -thin x86_64 -output "$x86_counter"

# Runs the frame counter block for one launch
prepare() {
  WINELOADER="$1"
  app_id="${2:-1245620}"
  np_build=26.3.0.39832
  np_flavor=""
  np_backend=dxmt
  np_display="CrossOver 26.3 · DXMT"
  wine_unix="$work/runners/crossover-$np_build/CrossOver/lib/wine/x86_64-unix"
  unset -v CX_GRAPHICS_BACKEND
  : > "$log"
  eval "$block"
}

# Writes the launcher the way the run script does, then runs it as `open` would
launch() {
  loader_root="$work/launchers/$app_id"
  loader_macos="$work/launchers/$app_id/Game.app/Contents/MacOS"
  mkdir -p "$loader_macos"
  eval "$launcher"
  shift
  CARTOUCHE_FPS_DIR="$fps_dir" CARTOUCHE_FPS_COUNTER="$fps_insert" sh "$loader_macos/launcher" "$@"
}

session_value() { sed -n "s/^$1=//p" "$fps_dir/session"; }

echo "== A loader that takes the library =="
export MTL_HUD_ENABLED=1
export DXVK_HUD=fps
prepare "$runner/accepting"
is "a folder per launch under performance/incoming" "$np_support/performance/incoming" "$(dirname "$fps_dir")"
case "${fps_dir##*/}" in 1245620-[0-9]*-[0-9]*) ok "named <app>-<time>-<pid>" ;; *) bad "named <app>-<time>-<pid>" "1245620-t-p" "${fps_dir##*/}" ;; esac
is "the probe passes" "on" "$(session_value measure)"
is "the counter is inserted" "$np_support/fps-counter.dylib" "$fps_insert"
is "the setup: runner" "26.3.0.39832" "$(session_value runner)"
is "the setup: translation" "rosetta" "$(session_value flavor)"
is "the setup: backend" "dxmt" "$(session_value backend)"
is "the setup: name" "CrossOver 26.3 · DXMT" "$(session_value display)"
is "the settings, and nothing else from the environment" "DXVK_HUD=fps|MTL_HUD_ENABLED=1" "$(session_value setting | tr '\n' '|' | sed 's/|$//')"
case "$(session_value started)" in [0-9]*) ok "a start time" ;; *) bad "a start time" "seconds" "$(session_value started)" ;; esac
is "no probe marker left" "" "$(find "$fps_dir" -name probe)"
has "the log says so" "fps: ok by $runner/accepting" "$(cat "$log")"
out=$(launch accepting locked 60 5; cat "$loader_root/cartouche-wine.log")
is "the game runs" "300" "$out"
set -- "$fps_dir"/samples-*
[ -f "$1" ] && ok "the game's process wrote its samples" || bad "the game's process wrote its samples" "samples-<pid>" "$(ls "$fps_dir")"
counted=$(grep -v '^#' "$1" | sed '1d;$d' | awk '{ s += $2; n++ } END { if (n) printf "%.0f", s / n }')
is "at 60 fps" "60" "$counted"
eval "$ended"
case "$(session_value ended)" in [0-9]*) ok "the end time is written when the game exits" ;; *) bad "the end time" "seconds" "$(session_value ended)" ;; esac
unset -v MTL_HUD_ENABLED DXVK_HUD

echo "== The probe is kept per runner until the loader or the counter changes =="
prepare "$runner/accepting"
has "the second launch reuses it" "fps: ok for this runner, checked before" "$(cat "$log")"
touch -t 202001010000 "$runner/accepting"
prepare "$runner/accepting"
has "a changed loader is tried again" "fps: ok by $runner/accepting" "$(cat "$log")"

echo "== A hardened loader ignores the library =="
prepare "$runner/hardened"
is "refused" "refused" "$(session_value measure)"
is "nothing inserted" "" "$fps_insert"
out=$(launch hardened locked 60 1; cat "$loader_root/cartouche-wine.log")
is "the game runs normally" "60" "$out"
is "and writes no samples" "" "$(find "$fps_dir" -name 'samples-*')"
has "the log names the runner" "fps: refused by $runner/hardened" "$(cat "$log")"

echo "== A loader dyld kills when the library cannot load =="
cp "$x86_counter" "$np_support/fps-counter.dylib"
set +e
# The shell reports the abort on its own stderr, so a second shell runs it
rc=$(sh -c 'DYLD_INSERT_LIBRARIES="$1" "$2" locked 60 0 > /dev/null 2>&1; echo $?' sh \
  "$np_support/fps-counter.dylib" "$runner/killed" 2> /dev/null)
set -e
is "inserted anyway, the game would not start" 134 "$rc"
prepare "$runner/killed"
is "refused" "refused" "$(session_value measure)"
is "nothing inserted" "" "$fps_insert"
out=$(launch killed locked 60 1; cat "$loader_root/cartouche-wine.log")
is "the game runs normally" "60" "$out"
cp "$counter_build" "$np_support/fps-counter.dylib"

echo "== The launcher keeps the overlay and adds the counter last =="
app_id=1245620
fps_dir="$work/scratch-session"
fps_insert="$np_support/fps-counter.dylib"
loader_root="$work/launchers/order"
loader_macos="$loader_root/Game.app/Contents/MacOS"
mkdir -p "$loader_macos" "$fps_dir"
WINELOADER="$runner/accepting"
: > "$np_support/overlay-shim.dylib"
eval "$launcher"
sed 's|^"[^"]*" "\$@"$|echo "DYLD=$DYLD_INSERT_LIBRARIES COUNTER=${CARTOUCHE_FPS_COUNTER:-}"|' "$loader_macos/launcher" > "$loader_macos/launcher.print"
STEAM_DYLD_INSERT_LIBRARIES=/steam/gameoverlayrenderer.dylib CARTOUCHE_FPS_COUNTER="$fps_insert" sh "$loader_macos/launcher.print"
is "overlay shim, Steam's overlay, then the counter" \
  "DYLD=$np_support/overlay-shim.dylib:/steam/gameoverlayrenderer.dylib:$fps_insert COUNTER=" "$(cat "$loader_root/cartouche-wine.log")"
CARTOUCHE_FPS_COUNTER="$fps_insert" sh "$loader_macos/launcher.print"
is "without the overlay, the counter alone" "DYLD=$fps_insert COUNTER=" "$(cat "$loader_root/cartouche-wine.log")"
sh "$loader_macos/launcher.print"
is "a refused runner gets nothing" "DYLD= COUNTER=" "$(cat "$loader_root/cartouche-wine.log")"
rm -f "$np_support/overlay-shim.dylib"

echo "== open passes the folder only when there is one =="
fps_dir=""
set -- --args game.exe
eval "$open_args"
is "no folder, no arguments" "--args game.exe" "$*"
fps_dir="/x/1-2-3"
fps_insert=""
eval "$open_args"
is "a refused runner still records the session" "--env CARTOUCHE_FPS_DIR=/x/1-2-3 --env CARTOUCHE_FPS_COUNTER= --args game.exe" "$*"

echo "== Nothing is measured when =="
export CARTOUCHE_FPS=0
prepare "$runner/accepting"
is "CARTOUCHE_FPS=0 is in the launch options" "|" "$fps_dir|$fps_insert"
has "and the log says so" "fps: off, CARTOUCHE_FPS=0 in the launch options" "$(cat "$log")"
unset -v CARTOUCHE_FPS
prepare "$runner/accepting" 0
is "the app is unknown" "|" "$fps_dir|$fps_insert"
rm -f "$np_support/fps-counter.dylib"
prepare "$runner/accepting"
is "the counter is not installed" "|" "$fps_dir|$fps_insert"

echo "== Order in the run script =="
block_at=$(grep -n '^prepare_fps >> "\$log" 2>&1 || true$' "$SRC" | cut -d: -f1)
bundle_at=$(grep -n '^install_bundle$' "$SRC" | cut -d: -f1)
open_at=$(grep -n '^open -n -W -a "\$loader_app" "\$@"' "$SRC" | cut -d: -f1)
[ "$bundle_at" -lt "$block_at" ] && [ "$block_at" -lt "$open_at" ] \
  && ok "probed with the bundle's loader, before the game opens" \
  || bad "probed after install_bundle, before open" "$bundle_at < x < $open_at" "$block_at"

if [ "$fails" -eq 0 ]; then
  echo "==> fpscheck: all assertions hold"
else
  echo "==> fpscheck: $fails failed"
  exit 1
fi
