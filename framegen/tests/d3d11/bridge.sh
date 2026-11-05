#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# The Wine bridge in the D3D11 scene on DXMT. The builtin DLL is found through WINEDLLPATH and
# never copied into the game's folder: a fresh prefix registers it, then it carries 10 000
# frames to the library with no loss and a one-way p99 under 50 us. Then, with a DLL of the
# same name in the game's folder, which one Wine loads for each load order.
# Usage: bridge.sh <scene.exe> <framegen.dylib> <folder with builtin/ and native/>
set -u
exe="$1"
lib="$2"
bridge="$3"
here=$(dirname "$0")
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
work=$(mktemp -d "$HOME/Library/Caches/cartouche-bridge.XXXXXX")
trap 'rm -rf "$work"' EXIT
export FRAMEGEN_PREFIX="$work/prefix" WINEDLLPATH="$bridge/builtin"
# scene <name> "<VAR=value ...>" <exe> <dxmt|...> <on|off> <arguments...>, output in $work/<name>.
# Variables go through env, as assignments before a function call outlive it in sh.
scene() {
  name="$1"; vars="$2"; shift 2
  # shellcheck disable=SC2086 # vars is a list of assignments
  env $vars sh "$here/run.sh" "$@" > "$work/$name.out" 2> "$work/$name.log"
}
value() { sed -n "s/.* $1=\([0-9.x]*\).*/\1/p" "$work/$2.out" | head -1; }

echo "== a fresh prefix registers the builtin =="
scene boot "" wineboot "$lib" dxmt off -u
if grep -q "run.sh: no prepared" "$work/boot.log"; then
  echo "  skip  Cartouche has no dxmt Wine on this Mac"
  exit 0
fi
[ -f "$FRAMEGEN_PREFIX/drive_c/windows/system32/cartouche_bridge.dll" ] && ok "wineboot put a placeholder in system32" \
  || bad "placeholder" "system32/cartouche_bridge.dll" "none"

echo "== 10 000 frames, the DLL in no game folder =="
scene run "CARTOUCHE_FRAMEGEN_TUNE=enabled=0 WINEDLLOVERRIDES=cartouche_bridge=b" "$exe" "$lib" dxmt on 400 120 0 bridge:10000
grep -q "^bridge kind=builtin .*open=0x0" "$work/run.out" && ok "loaded as builtin, unix half attached" \
  || bad "builtin" "bridge kind=builtin ... open=0x0" "$(head -3 "$work/run.out" "$work/run.log" | tr '\n' ' ')"
sent=$(value sent run); received=$(value received run)
[ "${sent:-0}" -eq 10000 ] && [ "${received:-0}" -eq 10000 ] && ok "10000 sent, 10000 received" \
  || bad "every frame received" "10000 / 10000" "${sent:-?} / ${received:-?}"
[ "$(value lost run)" = 0 ] && [ "$(value disordered run)" = 0 ] && [ "$(value full run)" = 0 ] && [ "$(value failed run)" = 0 ] \
  && ok "no loss, no disorder, never full" || bad "no loss" "lost=0 disordered=0 full=0 failed=0" "$(grep '^bridge sent' "$work/run.out")"
p99=$(value one_way_p99_us run)
awk -v v="${p99:-999}" 'BEGIN { exit !(v < 50) }' && ok "one-way p99 $p99 us" || bad "one-way p99" "< 50 us" "${p99:-none}"
echo "  info  one-way p50 $(value one_way_p50_us run) us, max $(value one_way_max_us run) us; the game's call p50 $(value call_p50_us run) us, p99 $(value call_p99_us run) us, max $(value call_max_us run) us"

echo "== without the library =="
scene alone WINEDLLOVERRIDES=cartouche_bridge=b "$exe" "$lib" dxmt off 400 2 0 bridge:10
grep -q "^bridge kind=builtin .*open=0xc0000135" "$work/alone.out" && ok "the bridge says the library is missing" \
  || bad "missing library" "open=0xc0000135" "$(head -2 "$work/alone.out" | tr '\n' ' ')"

echo "== a DLL of the same name in the game's folder =="
mkdir -p "$work/game"
cp "$exe" "$bridge/native/cartouche_bridge.dll" "$work/game/"
scene b WINEDLLOVERRIDES=cartouche_bridge=b "$work/game/scene.exe" "$lib" dxmt on 400 2 0 bridge:100
grep -q "^bridge kind=builtin .*open=0x0" "$work/b.out" && ok "=b loads the builtin" \
  || bad "=b" "kind=builtin open=0x0" "$(head -1 "$work/b.out")"
cmp -s "$bridge/native/cartouche_bridge.dll" "$work/game/cartouche_bridge.dll" && ok "the game's folder is untouched" \
  || bad "untouched" "same file" "changed"
scene n WINEDLLOVERRIDES=cartouche_bridge=n "$work/game/scene.exe" "$lib" dxmt on 400 1 0 bridge:10
grep -q "^bridge kind=native" "$work/n.out" && ok "=n loads the game's own" || bad "=n" "kind=native" "$(head -1 "$work/n.out")"
scene default "" "$work/game/scene.exe" "$lib" dxmt on 400 1 0 bridge:10
echo "  info  with no override Wine loads the $(sed -n 's/^bridge kind=\([a-z]*\).*/\1/p' "$work/default.out") one"

if [ "$fails" -eq 0 ]; then
  echo "==> framegen-bridge: all assertions hold"
else
  echo "==> framegen-bridge: $fails failed"
  exit 1
fi
