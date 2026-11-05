#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# The zero-copy D3D11 path on DXMT patched with framegen/dxmt/0001-GetMetalTexture.patch, in
# the D3D11 scene. 1: the Metal textures DXMT hands out for colour, depth, motion and output hold
# the same texels as the scene's D3D11 copies, frame after frame. 2: our MetalFX chain (temporal
# scaler then RCAS) replaces the scene's upscale; frame 90 is scored against a twice-as-big
# reference, next to a plain bilinear upscale, native rendering without anti-aliasing and DXMT's
# own DLSS-to-MetalFX path; then each runs uncapped for frame times.
# Usage: dxmt.sh <scene.exe> <framegen.dylib> <bridge builtin dir> <score> <patched Wine root>
set -u
exe="$1"; lib="$2"; builtin="$3"; score="$4"; root="$5"
here=$(dirname "$0")
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
work=$(mktemp -d "$HOME/Library/Caches/cartouche-dxmt.XXXXXX")
trap 'rm -rf "$work"' EXIT
export FRAMEGEN_ROOT="$root" FRAMEGEN_PREFIX="$work/prefix" WINEDLLPATH="$builtin" \
  WINEDLLOVERRIDES="cartouche_bridge=b;nvapi64=n;nvngx=b" DXMT_ENABLE_NVEXT=1 \
  CARTOUCHE_FRAMEGEN_TUNE=enabled=0 CARTOUCHE_FRAMEGEN_FRONT=1
scene() { name="$1"; shift; sh "$here/run.sh" "$exe" "$lib" dxmt on "$@" > "$work/$name.out" 2> "$work/$name.log"; }
# value <name> <run> [line prefix]
value() { grep "^${3:-}" "$work/$2.out" | sed -n "s/.* $1=\([0-9.x-]*\).*/\1/p" | head -1; }

sh "$here/run.sh" wineboot "$lib" dxmt off -u > "$work/boot.log" 2>&1

echo "== GetMetalTexture: the Metal texture behind each D3D11 resource =="
scene probe 30 3 0 probe:60
grep "^metal texture [0-9] [0-9]" "$work/probe.out"
[ "$(value color probe "metal probe")" = 60 ] && ok "colour: 60 frames of 60 the same" || bad colour 60 "$(grep "metal probe" "$work/probe.out")"
[ "$(value depth probe "metal probe")" = 60 ] && ok "depth: 60 the same" || bad depth 60 "$(value depth probe "metal probe")"
[ "$(value motion probe "metal probe")" = 60 ] && ok "motion: 60 the same" || bad motion 60 "$(value motion probe "metal probe")"
[ "$(value output probe "metal probe")" = 60 ] && ok "output: 60 the same" || bad output 60 "$(value output probe "metal probe")"
grep -q "buffer=0x80070057/0" "$work/probe.out" && ok "a buffer is refused" || bad "buffer refused" "0x80070057/0" "$(grep handles "$work/probe.out")"

echo "== MetalFX chain in place of the upscale, frame 90 against the reference =="
scene ref 30 3.4 0 ss capture:90:"$work/ref"
scene native 30 3.4 0 capture:90:"$work/native"
scene mfx 30 3.4 0 mfx capture:90:"$work/mfx"
scene dlss 30 3.4 0 dlss halton capture:90:"$work/dlss"
for name in native mfx mfx-low dlss; do
  if [ -f "$work/$name.ppm" ] && [ -f "$work/ref.ppm" ]; then
    printf '  %-8s %s\n' "$name" "$("$score" "$work/ref.ppm" "$work/$name.ppm")" | tee "$work/$name.score"
  else
    bad "capture $name" "$name.ppm" "$(tail -2 "$work/${name%-low}.log" | tr '\n' ' ')"
  fi
done
[ -n "${DXMT_KEEP:-}" ] && cp "$work"/*.ppm "$DXMT_KEEP"/ 2>/dev/null
ssim() { sed -n 's/.*ssim=\([0-9.]*\).*/\1/p' "$work/$1.score" 2>/dev/null; }
awk -v a="$(ssim mfx)" -v b="$(ssim mfx-low)" 'BEGIN { exit !(a > b) }' && ok "ours beats bilinear" \
  || bad "ours beats bilinear" "ssim > $(ssim mfx-low)" "$(ssim mfx)"
awk -v a="$(ssim mfx)" -v b="$(ssim native)" 'BEGIN { exit !(a >= b - 0.01) }' && ok "ours matches native (SSIM within 0.01 or above)" \
  || bad "ours matches native" "ssim >= $(ssim native) - 0.01" "$(ssim mfx)"

# light: the scene as is, held by presentation near 8.5 ms; heavy: about 2000 extra sin() per
# pixel, as a game's shading would cost, so the GPU sets the pace
echo "== frame time, uncapped, 6 s each =="
for load in 0 20; do
  for mode in native mfx dlss; do
    arg=$mode; [ "$mode" = native ] && arg=""; [ "$mode" = dlss ] && arg="dlss halton"
    # shellcheck disable=SC2086 # arg is a list of the scene's words
    scene "time-$mode-$load" 1000 6 "$load" $arg
    printf '  load=%s %-7s frame_ms=%s %s\n' "$load" "$mode" "$(value frame_ms "time-$mode-$load")" \
      "$(grep "metal upscale" "$work/time-$mode-$load.out")"
  done
done
grep -q "failed=0" "$work/time-mfx-0.out" && ok "every upscale went through" || bad "upscale" "failed=0" "$(grep "metal upscale" "$work/time-mfx-0.out")"
awk -v a="$(value frame_ms time-mfx-20)" -v b="$(value frame_ms time-native-20)" 'BEGIN { exit !(a < b) }' \
  && ok "heavy shading: ours is faster than native" || bad "heavy: faster than native" "< $(value frame_ms time-native-20)" "$(value frame_ms time-mfx-20)"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
