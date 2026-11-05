#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# Experimental frame generation as the run script injects it. Blocks are cut out of the
# script and run against scratch trees, with the stand-in game answering as Wine's loader:
# the setup file turns it on, a loader that takes the library gets it first in the insert
# list, a hardened one starts the game without it.
# Usage: framegencheck.sh <compat_run.sh> <framegen.dylib> <folder with game>
# shellcheck disable=SC2034,SC2154,SC2016
set -e
SRC="$1"
framegen_build="$2"
bin="$3"
[ -f "$framegen_build" ] && [ -x "$bin/game" ] \
  || { echo "FAIL: framegencheck needs the library and the stand-in game, run: make framegencheck"; exit 1; }

setup=$(sed -n '/^read_game_setup() {$/,/^}$/p' "$SRC")
block=$(sed -n '/^framegen="\$np_support\/framegen.dylib"$/,/^prepare_framegen >> "\$log" 2>&1 || true$/p' "$SRC")
launcher=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC")
open_args=$(sed -n '/^if \[ -n "\$framegen_insert" \]; then$/,/^fi$/p' "$SRC")
[ -n "$setup" ] && [ -n "$block" ] && [ -n "$launcher" ] && [ -n "$open_args" ] \
  || { echo "FAIL: frame generation blocks not found in $SRC"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains $2" "$3" ;; esac; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/Cartouche"
mkdir -p "$np_support/setups"
cp "$framegen_build" "$np_support/framegen.dylib"
log="$work/run.log"
attempt_dir="$work/attempt"
mkdir -p "$attempt_dir"

runner="$work/runner"
mkdir -p "$runner"
cp "$bin/game" "$runner/accepting"
cp "$bin/game" "$runner/hardened"
codesign -fs - -o runtime "$runner/hardened" 2> /dev/null

prepare() {
  WINELOADER="$1"
  : > "$log"
  eval "$block"
}

echo "== The game's setup file =="
app_id=1245620
wine_unix="$work/runners/crossover/lib/wine/x86_64-unix"
printf 'CARTOUCHE_FRAMEGEN=1\nCARTOUCHE_FRAMEGEN_STATS=1\nCARTOUCHE_FRAMEGEN_TEMPORAL=off\nCARTOUCHE_FRAMEGEN_INTERPOLATE=1\nDYLD_INSERT_LIBRARIES=/evil.dylib\n' > "$np_support/setups/$app_id.env"
unset -v CARTOUCHE_FRAMEGEN CARTOUCHE_FRAMEGEN_STATS CARTOUCHE_FRAMEGEN_TEMPORAL CARTOUCHE_FRAMEGEN_INTERPOLATE
eval "$setup"
out=$(read_game_setup)
read_game_setup > /dev/null
is "CARTOUCHE_FRAMEGEN is read" "1" "${CARTOUCHE_FRAMEGEN:-}"
is "CARTOUCHE_FRAMEGEN_STATS is read" "1" "${CARTOUCHE_FRAMEGEN_STATS:-}"
is "CARTOUCHE_FRAMEGEN_TEMPORAL is read" "off" "${CARTOUCHE_FRAMEGEN_TEMPORAL:-}"
has "a setup cannot turn interpolation on" "setup: CARTOUCHE_FRAMEGEN_INTERPOLATE is not a variable Cartouche sets, ignored" "$out"
is "interpolation stays unset until the launch" "" "${CARTOUCHE_FRAMEGEN_INTERPOLATE:-}"
has "DYLD_* is still refused" "setup: DYLD_INSERT_LIBRARIES is not a variable Cartouche sets, ignored" "$out"

echo "== A loader that takes the library =="
prepare "$runner/accepting"
is "inserted" "$np_support/framegen.dylib" "$framegen_insert"
has "the log says so" "framegen: on for this launch" "$(cat "$log")"
is "no probe marker left" "" "$(find "$attempt_dir" -name 'framegen-probe*')"

echo "== A hardened loader ignores it =="
prepare "$runner/hardened"
# A hosted runner has SIP off, so dyld loads the library and the probe passes there
if [ "${CARTOUCHE_CI_HOSTED:-}" = 1 ] && [ -n "$framegen_insert" ]; then
  printf '  SKIP  a hardened loader refuses it\n         why  dyld loads inserted libraries into hardened binaries on this hosted runner (SIP off)\n'
else
  is "nothing inserted" "" "$framegen_insert"
  has "the log names the runner" "framegen: refused by $runner/hardened" "$(cat "$log")"
fi

echo "== Not requested, or not installed =="
unset -v CARTOUCHE_FRAMEGEN
prepare "$runner/accepting"
is "without the variable, nothing" "|" "$framegen_insert|$(cat "$log")"
export CARTOUCHE_FRAMEGEN=1
rm -f "$np_support/framegen.dylib"
prepare "$runner/accepting"
is "not installed: nothing inserted" "" "$framegen_insert"
has "and the log says so" "framegen: requested, but $np_support/framegen.dylib is not installed" "$(cat "$log")"
cp "$framegen_build" "$np_support/framegen.dylib"

echo "== open passes it to the launcher =="
framegen_insert="$np_support/framegen.dylib"
set -- --args game.exe
eval "$open_args"
is "the library, interpolation off, the switches and the log folder" \
  "--env CARTOUCHE_FRAMEGEN_TEMPORAL=off --env CARTOUCHE_FRAMEGEN=1 --env CARTOUCHE_FRAMEGEN_INTERPOLATE=0 --env CARTOUCHE_FRAMEGEN_LIBRARY=$np_support/framegen.dylib --env CARTOUCHE_FRAMEGEN_STATS=1 --env CARTOUCHE_FRAMEGEN_DIR=$attempt_dir --args game.exe" "$*"
framegen_insert=""
set -- --args game.exe
eval "$open_args"
is "a refused runner passes nothing" "--args game.exe" "$*"

echo "== The launcher puts it first =="
loader_root="$work/launchers/order"
loader_macos="$loader_root/Game.app/Contents/MacOS"
mkdir -p "$loader_macos"
WINELOADER="$runner/accepting"
: > "$np_support/overlay-shim.dylib"
eval "$launcher"
sed 's#^"[^"]*" "\$@" || status=\$?$#echo "DYLD=$DYLD_INSERT_LIBRARIES LIBRARY=${CARTOUCHE_FRAMEGEN_LIBRARY:-}"#' "$loader_macos/launcher" > "$loader_macos/launcher.print"
game_log() { grep -v '^Wine launcher exited with status=' "$loader_root/cartouche-wine.log" | sed '/^$/d'; }
STEAM_DYLD_INSERT_LIBRARIES=/steam/gameoverlayrenderer.dylib CARTOUCHE_FPS_COUNTER=/fps.dylib \
  CARTOUCHE_FRAMEGEN_LIBRARY=/fg.dylib sh "$loader_macos/launcher.print"
is "frame generation, overlay shim, Steam's overlay, then the counter" \
  "DYLD=/fg.dylib:$np_support/overlay-shim.dylib:/steam/gameoverlayrenderer.dylib:/fps.dylib LIBRARY=" "$(game_log)"
CARTOUCHE_FRAMEGEN_LIBRARY=/fg.dylib sh "$loader_macos/launcher.print"
is "alone" "DYLD=/fg.dylib LIBRARY=" "$(game_log)"
sh "$loader_macos/launcher.print"
is "a launch without it gets nothing" "DYLD= LIBRARY=" "$(game_log)"

echo "== Order in the run script =="
setup_at=$(grep -n '^read_game_setup >> "\$log" 2>&1 || true$' "$SRC" | cut -d: -f1)
bundle_at=$(grep -n '^install_bundle$' "$SRC" | cut -d: -f1)
block_at=$(grep -n '^prepare_framegen >> "\$log" 2>&1 || true$' "$SRC" | cut -d: -f1)
open_at=$(grep -n '^open -n -W -a "\$loader_app" "\$@"' "$SRC" | cut -d: -f1)
[ "$setup_at" -lt "$block_at" ] && [ "$bundle_at" -lt "$block_at" ] && [ "$block_at" -lt "$open_at" ] \
  && ok "probed after the setup is read and the bundle staged, before the game opens" \
  || bad "setup and bundle < probe < open" "$setup_at, $bundle_at < x < $open_at" "$block_at"

if [ "$fails" -eq 0 ]; then
  echo "==> framegencheck: all assertions hold"
else
  echo "==> framegencheck: $fails failed"
  exit 1
fi
