#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# Our temporal chain on an MTL4FX scaler, as D3DMetal may drive one for DLSS, opt-in through
# CARTOUCHE_FRAMEGEN_TEMPORAL4=1: without it the scaler is left as made, byte for byte. With it,
# frames 60 to 67 against the scene rendered at full size, ours as good as MTL4FX alone or better,
# at most 0.3 ms more GPU per frame (median of 5 runs: a run's two scalers differ by up to
# 0.1 ms); the kill switch leaves the very same bytes. Then with the scaler's fence, and with an
# RGBA16Float output, whose cost is shown, not held to 0.3 ms (RCAS's tone map on twice the bytes).
# Usage: temporal4.sh <temporal4> <score> <logo.svg>
set -u
bench="$1"
score="$2"
logo="$3"
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# mean <dir> <lane>: mean PSNR and SSIM of a lane's 8 frames against the full-size ones
mean() {
  for i in 0 1 2 3 4 5 6 7; do "$score" "$1/full-$i.ppm" "$1/$2-$i.ppm" || return 1; done \
    | awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); sum[kv[1]] += kv[2] } } END { printf "psnr=%.2f ssim=%.4f\n", sum["psnr_db"] / NR, sum["ssim"] / NR }'
}
field() { echo "$1" | sed -n "s/.*$2=\([-0-9.]*\).*/\1/p"; }

# run <name> <settings> <opt> [fence] [16f]: the bench's line, its log in <name>/log; a non-empty
# opt passes CARTOUCHE_FRAMEGEN_TEMPORAL4=1
run() {
  name=$1 settings=$2 opt=$3; shift 3
  mkdir -p "$work/$name"
  env ${opt:+CARTOUCHE_FRAMEGEN_TEMPORAL4=1} "$bench" "$logo" "$work/$name" "$settings" "$@" 2> "$work/$name/log" | tail -1
}

# cost <settings> [fence] [16f]: the median GPU time our chain adds over 5 runs (opted in)
cost() {
  mkdir -p "$work/cost"
  for _ in 1 2 3 4 5; do env CARTOUCHE_FRAMEGEN_TEMPORAL4=1 "$bench" "$logo" "$work/cost" "$@" 2> /dev/null | tail -1; done \
    | sed -n 's/.*added_ms=\([-0-9.]*\).*/\1/p' | sort -n | sed -n 3p
}

gate() {
  name=$1 line=$2; shift 2
  echo "  info  $line"
  grep -q "framegen: temporal: in use .*mtl4=1" "$work/$name/log" && ok "$name: our chain takes the MTL4FX scaler" \
    || bad "$name: our chain" "framegen: temporal: in use ... mtl4=1" "$(grep framegen: "$work/$name/log" | head -3 | tr '\n' ' ')"
  alone=$(mean "$work/$name" alone)
  ours=$(mean "$work/$name" ours)
  echo "  info  MTL4FX alone $alone"
  echo "  info  ours         $ours"
  awk -v a="$(field "$ours" psnr)" -v b="$(field "$alone" psnr)" -v c="$(field "$ours" ssim)" -v d="$(field "$alone" ssim)" \
    'BEGIN { exit !(a != "" && b != "" && a >= b - 0.05 && c >= d - 0.0005) }' \
    && ok "$name: same image as MTL4FX alone or better" || bad "$name: image against the full-size render" "ours >= alone" "ours $ours, alone $alone"
  added=$(cost "" "$@")
  if [ "$name" = hdr ]; then
    echo "  info  $name: our chain adds $added ms, median of 5"
    return
  fi
  awk -v a="$added" 'BEGIN { exit !(a != "" && a <= 0.3) }' && ok "$name: our chain adds 0.3 ms or less ($added ms, median of 5)" \
    || bad "$name: GPU our chain adds, median of 5" "<= 0.3 ms" "$added"
}

echo "== default: without CARTOUCHE_FRAMEGEN_TEMPORAL4 the scaler is left as made =="
line=$(run default "" "")
echo "  info  $line"
echo "$line" | grep -q "identical=8/8" && ok "the same bytes as MTL4FX alone, 8 of 8 frames" \
  || bad "default" "identical=8/8" "$line"
grep -q "framegen: temporal: in use" "$work/default/log" && bad "default" "no chain" "$(grep temporal: "$work/default/log" | head -1)" \
  || ok "no chain in use"
grep -q "temporal: Metal 4 scaler left as made" "$work/default/log" && ok "the log says the scaler is left as made" \
  || bad "default" "temporal: Metal 4 scaler left as made" "$(grep framegen: "$work/default/log" | head -3 | tr '\n' ' ')"

echo "== MTL4FX temporal scaler 853x480 to 1280x720, alone and through our chain =="
gate ours "$(run ours "" 1)"
echo "== the scaler's fence =="
gate fence "$(run fence "" 1 fence)" fence
echo "== RGBA16Float output =="
gate hdr "$(run hdr "" 1 16f)" 16f

echo "== kill switch: CARTOUCHE_FRAMEGEN_TEMPORAL=off wins over the opt-in =="
line=$(run off off 1)
echo "  info  $line"
echo "$line" | grep -q "identical=8/8" && ok "the same bytes as MTL4FX alone, 8 of 8 frames" \
  || bad "kill switch" "identical=8/8" "$line"
grep -q "framegen: temporal: in use" "$work/off/log" && bad "kill switch" "no chain" "$(grep temporal: "$work/off/log" | head -1)" \
  || ok "no chain in use"

if [ "$fails" -eq 0 ]; then
  echo "==> framegen temporal4: all assertions hold"
else
  echo "==> framegen temporal4: $fails failed"
  exit 1
fi
