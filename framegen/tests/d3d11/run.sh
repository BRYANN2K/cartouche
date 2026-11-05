#!/bin/sh
# Runs the D3D11 stand-in game in Cartouche's Wine on DXMT or D3DMetal, with or without the
# frame generation library, in a scratch prefix cloned from Cartouche's template. Uses the
# Wine root Cartouche prepared for that backend, as compat_run.sh does.
# Usage: run.sh <scene.exe> <framegen.dylib> <dxmt|d3dmetal> <on|off> [scene arguments...]
# Extra variables (CARTOUCHE_FRAMEGEN_STATS, _DIR, _TUNE, DXMT_*, D3DM_*) pass through.
# FRAMEGEN_ROOT runs another Wine root, as framegen/dxmt/build.sh's patched DXMT.
set -eu
exe="$1"; lib="$2"; backend="$3"; frames="$4"; shift 4
support="$HOME/Library/Application Support/Cartouche"
build="${FRAMEGEN_WINE:-wine-crossover-26.3.0-2}"
root="${FRAMEGEN_ROOT:-$support/runners/.graphics/$build/$backend}"
prefix="${FRAMEGEN_PREFIX:-$HOME/Library/Caches/cartouche-framegen-prefix}"
[ -f "$root/.cartouche-graphics.json" ] || { echo "run.sh: no prepared $backend Wine at $root" >&2; exit 1; }
[ -d "$prefix" ] || cp -cR "$support/prefix-template" "$prefix" 2>/dev/null || cp -R "$support/prefix-template" "$prefix"
if [ "$backend" = d3dmetal ]; then
  for dir in "$support"/runners/gptk-*/lib; do
    [ ! -f "$dir/external/libd3dshared.dylib" ] || export CX_APPLEGPTK_LIBD3DSHARED_PATH="$dir/external/libd3dshared.dylib"
  done
fi
export CX_ROOT="$root" CX_GRAPHICS_BACKEND="$backend" WINEPREFIX="$prefix" WINEDEBUG="${WINEDEBUG:--all}"
export WINESERVER="$root/bin/wineserver" WINELOADER="$root/lib/wine/x86_64-unix/wine"
[ -x "$WINELOADER" ] || WINELOADER="$root/bin/wine"
if [ "$frames" = on ]; then
  export CARTOUCHE_FRAMEGEN=1 DYLD_INSERT_LIBRARIES="$lib"
fi
status=0
"$WINELOADER" "$exe" "$@" || status=$?
"$WINESERVER" -w 2> /dev/null || true
exit "$status"
