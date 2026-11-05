#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# The D3D11 stand-in game in Cartouche's Wine, on DXMT and on D3DMetal: frame generation
# doubles the shown rate, keeps the game's rate, and never disables. Skips a backend that
# Cartouche has not prepared on this Mac. The library puts the window on the test screen (the
# Mac's own): the base rate is 40 fps from 80 Hz, half the refresh below.
# Usage: check.sh <scene.exe> <framegen.dylib>
set -u
exe="$1"
lib="$2"
here=$(dirname "$0")
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
in_range() { awk -v v="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }' && ok "$1 $2" || bad "$1" "$3..$4" "$2"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
hz=$("$(dirname "$exe")/game" --hz)
base=$((hz >= 80 ? 40 : hz / 2))
scaled() { awk -v b="$base" -v f="$1" 'BEGIN { print b * f }'; }
echo "test screen ${hz} Hz, base ${base} fps"

for backend in dxmt d3dmetal; do
  echo "== $backend =="
  mkdir -p "$work/$backend"
  CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$work/$backend" \
    sh "$here/run.sh" "$exe" "$lib" "$backend" on "$base" 15 > "$work/$backend/out" 2> "$work/$backend/log"
  if grep -q "run.sh: no prepared" "$work/$backend/log"; then
    echo "  skip  Cartouche has no $backend Wine on this Mac"
    continue
  fi
  grep -q "framegen: active backend=$(echo "$backend" | sed 's/dxmt/DXMT/;s/d3dmetal/D3DMetal/')" "$work/$backend/log" \
    && ok "active on $backend" || bad "active on $backend" "framegen: active" "$(grep framegen: "$work/$backend/log" | head -2 | tr '\n' ' ')"
  grep -q 'framegen: disabled' "$work/$backend/log" && bad "never disabled" "" "$(grep disabled "$work/$backend/log")" || ok "never disabled"
  file=$(find "$work/$backend" -name 'framegen-*.csv' | head -1)
  if [ -z "$file" ]; then
    bad "stats file" "framegen-*.csv" "none"
    continue
  fi
  rows=$(sed '1,2d;$d' "$file")
  in_range "game rate kept:" "$(echo "$rows" | awk -F, '{ s += $2; n++ } END { printf "%.1f", s / n }')" "$(scaled 0.95)" "$(scaled 1.05)"
  in_range "shown rate doubled:" "$(echo "$rows" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')" "$(scaled 1.8)" "$(scaled 2.2)"
  echo "  info  GPU per generated frame at 1280x720: $(echo "$rows" | awk -F, '{ s += $4; n++ } END { printf "%.2f", s / n }') ms, latency $(echo "$rows" | awk -F, '{ s += $19; n++ } END { printf "%.1f", s / n }') ms, 3+ refresh intervals $(echo "$rows" | awk -F, '{ s += $15 + $16; n++ } END { printf "%.1f", s / n }')/s"
done

echo "== dxmt under GPU jitter, against the scene presenting $((base * 2)) fps itself =="
mkdir -p "$work/jitter" "$work/native"
CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$work/jitter" \
  sh "$here/run.sh" "$exe" "$lib" dxmt on "$base" 15 0.6 > "$work/jitter/out" 2> "$work/jitter/log"
CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$work/native" CARTOUCHE_FRAMEGEN_TUNE=enabled=0 \
  sh "$here/run.sh" "$exe" "$lib" dxmt on "$((base * 2))" 15 0.6 > "$work/native/out" 2> "$work/native/log"
jitter=$(find "$work/jitter" -name 'framegen-*.csv' | head -1)
native=$(find "$work/native" -name 'framegen-*.csv' | head -1)
if [ -n "$jitter" ] && [ -n "$native" ]; then
  hitches() { sed '1,2d;$d' "$1" | awk -F, '{ s += $15 + $16; n++ } END { printf "%.1f", s / n }'; }
  a=$(hitches "$jitter"); b=$(hitches "$native")
  awk -v a="$a" -v b="$b" 'BEGIN { exit !(a <= b + 0.5) }' \
    && ok "intervals of 3 refreshes or more under jitter no more often than native: $a/s vs $b/s" \
    || bad "intervals of 3 refreshes or more under jitter" "<= $b/s + 0.5" "$a/s"
  echo "  info  repaired pixels $(sed '1,2d;$d' "$jitter" | awk -F, '{ s += $21; n++ } END { printf "%.1f", s / n }') %, mean trust $(sed '1,2d;$d' "$jitter" | awk -F, '{ s += $20; n++ } END { printf "%.3f", s / n }')"
else
  echo "  skip  no stats from the jitter runs"
fi

# RIFE lean (CARTOUCHE_FRAMEGEN_ANE=1), then Cartouche FG 1 (=fg1) if it was built
helper="$(dirname "$lib")/framegen-ane"
for ane in 1 fg1; do
  [ "$ane" = 1 ] && name=framegen-flow.mlmodelc || name=framegen-flow-$ane.mlmodelc
  [ "$ane" = 1 ] && echo "== dxmt with the Neural Engine's flow ==" || echo "== dxmt with the Neural Engine's flow, $ane =="
  if [ ! -x "$helper" ] || [ ! -d "$(dirname "$lib")/$name" ]; then
    echo "  skip  no framegen-ane or $name next to the library (make framegen-ane out/$name)"
    continue
  fi
  mkdir -p "$work/ane-$ane"
  CARTOUCHE_FRAMEGEN_ANE=$ane CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$work/ane-$ane" \
    sh "$here/run.sh" "$exe" "$lib" dxmt on "$base" 12 > "$work/ane-$ane/out" 2> "$work/ane-$ane/log"
  grep -q "framegen: ane flow in use" "$work/ane-$ane/log" && ok "the helper's flow is in use" \
    || bad "ane flow" "framegen: ane flow in use" "$(grep framegen: "$work/ane-$ane/log" | grep -v loaded | head -3 | tr '\n' ' ')"
  file=$(find "$work/ane-$ane" -name 'framegen-*.csv' | head -1)
  if [ -n "$file" ]; then
    rows=$(sed '1,3d;$d' "$file")
    in_range "shown rate doubled with the ANE:" "$(echo "$rows" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')" "$(scaled 1.8)" "$(scaled 2.2)"
    echo "  info  frames served by the ANE $(echo "$rows" | awk -F, '{ s += $22; n++ } END { printf "%.0f", s / n }') %, $(echo "$rows" | awk -F, '{ s += $23; n++ } END { printf "%.2f", s / n }') ms each, our GPU $(echo "$rows" | awk -F, '{ s += $4; n++ } END { printf "%.2f", s / n }') ms"
  fi
  pgrep -f "framegen-ane dev.cartouche" > /dev/null && bad "helper ends with the game" "no framegen-ane left" "still running" || ok "the helper ends with the game"
done

echo "== dxmt with DLSS: the game's own motion =="
mkdir -p "$work/dlss"
DXMT_ENABLE_NVEXT=1 WINEDLLOVERRIDES="nvapi64=n;nvngx=b" CARTOUCHE_FRAMEGEN_FRONT=1 \
  sh "$here/run.sh" "$exe" "$lib" dxmt on "$base" 8 0 dlss > "$work/dlss/out" 2> "$work/dlss/log"
if grep -q "run.sh: no prepared" "$work/dlss/log"; then
  echo "  skip  Cartouche has no dxmt Wine on this Mac"
else
  grep -q "scene: DLSS on" "$work/dlss/log" && ok "DXMT's DLSS takes the scene" || bad "DLSS on" "scene: DLSS on" "$(grep scene: "$work/dlss/log" | head -1)"
  grep -q "framegen: engine motion in use" "$work/dlss/log" && ok "the game's motion replaces the estimate" \
    || bad "engine motion" "framegen: engine motion in use" "$(grep framegen: "$work/dlss/log" | grep -v loaded | head -3 | tr '\n' ' ')"
fi

echo "== dxmt with DLSS through our temporal chain, against the scene rendered at full size =="
# Frames 60 to 67 of the same scene time: the full-size render, DXMT's chain, ours. Ours keeps
# the image as good or better and costs at most 0.3 ms more GPU per frame.
score="$(dirname "$exe")/score"
# quality <name> <scene words> <env...>
quality() {
  name=$1 mode=$2; shift 2
  mkdir -p "$work/$name"
  # shellcheck disable=SC2086 # mode is a list of the scene's words
  env "$@" DXMT_ENABLE_NVEXT=1 WINEDLLOVERRIDES="nvapi64=n;nvngx=b" CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 \
    CARTOUCHE_FRAMEGEN_DIR="$work/$name" CARTOUCHE_FRAMEGEN_TUNE=enabled=0 \
    sh "$here/run.sh" "$exe" "$lib" dxmt on "$base" 6 0 $mode "capture:60:8:Z:$work/$name/f" > "$work/$name/out" 2> "$work/$name/log"
}
# Mean PSNR and SSIM of a run's 8 frames against the full-size ones
mean_score() {
  for i in 0 1 2 3 4 5 6 7; do "$score" "$work/full/f-$i.ppm" "$work/$1/f-$i.ppm" || return 1; done \
    | awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); sum[kv[1]] += kv[2] } } END { printf "psnr=%.2f ssim=%.4f\n", sum["psnr_db"] / NR, sum["ssim"] / NR }'
}
quality full "" CARTOUCHE_FRAMEGEN_TEMPORAL=off
quality theirs "dlss halton" CARTOUCHE_FRAMEGEN_TEMPORAL=off
quality ours "dlss halton" CARTOUCHE_FRAMEGEN_TEMPORAL="${FRAMEGEN_TEMPORAL:-}"
if grep -q "run.sh: no prepared" "$work/full/log"; then
  echo "  skip  Cartouche has no dxmt Wine on this Mac"
elif [ ! -x "$score" ]; then
  echo "  skip  no score next to the scene (make out/framegen/score)"
else
  grep -q "framegen: temporal: in use" "$work/ours/log" && ok "our chain takes DXMT's scaler" \
    || bad "our chain" "framegen: temporal: in use" "$(grep temporal: "$work/ours/log" | head -3 | tr '\n' ' ')"
  theirs=$(mean_score theirs)
  ours=$(mean_score ours)
  echo "  info  DXMT $theirs"
  echo "  info  ours $ours"
  field() { echo "$1" | sed -n "s/.*$2=\([0-9.]*\).*/\1/p"; }
  awk -v a="$(field "$ours" psnr)" -v b="$(field "$theirs" psnr)" -v c="$(field "$ours" ssim)" -v d="$(field "$theirs" ssim)" \
    'BEGIN { exit !(a != "" && b != "" && a >= b - 0.05 && c >= d - 0.0005) }' \
    && ok "same image as DXMT's chain or better" || bad "image against the full-size render" "ours >= DXMT's" "ours $ours, DXMT $theirs"
  cost() { grep "temporal: buffer gpu" "$work/$1/log" | tail -1 | sed -n 's/.*p50=\([0-9.]*\).*/\1/p'; }
  echo "  info  GPU of the game's command buffer holding the scaler: ours $(cost ours) ms, DXMT's $(cost theirs) ms (other GPU work shows here)"
  # The cost itself from frames of both chains interleaved, which other GPU work slows alike
  bench="$(dirname "$exe")/temporal"
  if [ -x "$bench" ]; then
    line=$("$bench" 300 "${FRAMEGEN_TEMPORAL:-}" 2> /dev/null)
    added=$(echo "$line" | sed -n 's/.*added_ms=\([-0-9.]*\).*/\1/p')
    awk -v a="$added" 'BEGIN { exit !(a != "" && a <= 0.3) }' && ok "our chain adds 0.3 ms or less: $line" \
      || bad "GPU our chain adds" "<= 0.3 ms" "$line"
  else
    echo "  skip  no temporal bench next to the scene (make out/framegen/temporal)"
  fi
fi

if [ "$fails" -eq 0 ]; then
  echo "==> framegen wine: all assertions hold"
else
  echo "==> framegen wine: $fails failed"
  exit 1
fi
