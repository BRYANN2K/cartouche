#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# Upscaling in the stand-in game: the game renders at half the window's pixels, the library
# shows it at the screen's size in a layer of its own. Clicks land where the game draws them,
# the layers keep their size, frame generation still doubles the rate, and a failure takes the
# layer down. Then the same in Wine on DXMT and D3DMetal, with clicks the library posts to Wine's
# window from inside the process (the window keeps ignoring the real mouse).
# Usage: upscale.sh <framegen.dylib> <folder with game, winemetal.so, mouse, scene.exe>
set -u
lib="$1"
bin="$2"
game="$bin/game"
stub="$bin/winemetal.so"
mouse="$bin/mouse"
here=$(dirname "$0")

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
has() { if grep -q "$2" "$3"; then ok "$1"; else bad "$1" "$2" "$(grep framegen: "$3" | head -3 | tr '\n' ' ')"; fi; }
in_range() { awk -v v="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }' && ok "$1 $2" || bad "$1" "$3..$4" "$2"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

hz=$("$game" --hz)
base=$((hz >= 80 ? 40 : hz / 2))
scaled() { awk -v b="$base" -v f="$1" 'BEGIN { print b * f }'; }
echo "test screen ${hz} Hz, base ${base} fps"

run() {
  name="$1"; vars="$2"; shift 2
  mkdir -p "$work/$name"
  # shellcheck disable=SC2086 # vars is a list of assignments
  env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN_DIR="$work/$name" CARTOUCHE_FRAMEGEN_FRONT=1 $vars "$game" "$@" \
    > "$work/$name/out" 2> "$work/$name/log"
}
csv() { find "$work/$1" -name 'framegen-*.csv' | head -1; }
middle() { sed '1,2d;$d' "$1"; }
mean() { middle "$1" | awk -F, -v c="$2" '{ s += $c; n++ } END { printf "%.1f", s / n }'; }

# marks_match <name> <frame.ppm> <clicks file>: each click's mark sits where the click was, at
# the frame's density, within one point: the game sees whole pixels of its own (Wine: points)
marks_match() {
  "$mouse" marks "$2" > "$work/marks" 2>&1
  width=$(awk '$1 == "size" { print $2 }' "$work/marks")
  points=$(awk '$1 == "points" { print $2 }' "$3")
  clicks=$(grep -c '^click' "$3")
  found=$(grep -c '^mark' "$work/marks")
  if [ "$clicks" -lt 3 ] || [ -z "$width" ]; then
    bad "$1: clicks and a frame" ">= 3 clicks, a frame" "$clicks clicks, $(head -1 "$work/marks")"
    return
  fi
  worst=$(awk -v w="$width" -v p="$points" '
    FNR == NR { if ($1 == "mark") { mx[++m] = $2; my[m] = $3 } next }
    $1 == "click" { s = w / p; x = $2 * s; y = $3 * s; best = 1e9
      for (i = 1; i <= m; i++) { d = sqrt((mx[i] - x) ^ 2 + (my[i] - y) ^ 2); if (d < best) best = d }
      if (best > worst) worst = best }
    END { printf "%.2f", worst }' "$work/marks" "$3")
  tolerance=$(awk -v w="$width" -v p="$points" 'BEGIN { printf "%.2f", w / p }')
  awk -v d="$worst" -v t="$tolerance" 'BEGIN { exit !(d <= t) }' && [ "$found" -eq "$clicks" ] \
    && ok "$1: $clicks clicks, each mark within $worst px of its click on a ${width}-wide frame (one point: $tolerance px)" \
    || bad "$1: marks where the clicks were" "$clicks marks within $tolerance px" "$found marks, worst $worst px"
}

frame=$((base * 7))
echo "== mouse, native stand-in at half resolution =="
for method in off bilinear chain; do
  vars="CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DUMP=$work/$method.ppm:$frame"
  [ "$method" = off ] || vars="$vars CARTOUCHE_FRAMEGEN_UPSCALE=$method"
  run "$method" "$vars" "$base:8" --render-scale 0.5 --clicks 3
  log="$work/$method/log"
  points=$(sed -n 's/^game: render .* in \([0-9]*\)x[0-9]* points.*/\1/p' "$log")
  { echo "points $points"; grep '^click' "$work/$method/out"; } > "$work/$method/clicks"
  if [ "$method" = off ]; then
    grep -q 'framegen: upscale' "$log" && bad "off: no layer of ours" "" "$(grep upscale "$log")" || ok "off: no layer of ours"
  else
    has "$method: our layer is up" "framegen: upscale [0-9]*x[0-9]* -> [0-9]*x[0-9]* " "$log"
    sizes=$(grep 'framegen: upscale [0-9]' "$log" | awk '{ print $3, $5 }' | sort -u | wc -l | tr -d ' ')
    [ "$sizes" = 1 ] && ok "$method: one size all along ($(grep 'framegen: upscale [0-9]' "$log" | head -1 | awk '{ print $3 " -> " $5 }'))" \
      || bad "$method: one size all along" "1" "$sizes: $(grep 'framegen: upscale' "$log" | tr '\n' ' ')"
  fi
  grep -q 'framegen: \(disabled\|resized\)' "$log" && bad "$method: never disabled nor resized" "" "$(grep 'disabled\|resized' "$log")" \
    || ok "$method: never disabled nor resized"
  marks_match "$method" "$work/$method.ppm" "$work/$method/clicks"
  file=$(csv "$method")
  [ -n "$file" ] && in_range "$method: shown rate doubled:" "$(mean "$file" 3)" "$(scaled 1.8)" "$(scaled 2.2)"
  [ -n "$file" ] && echo "  info  $method: our GPU per generated frame $(mean "$file" 4) ms"
done

echo "== upscale alone, MTL4 path, failure =="
run alone "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_UPSCALE=chain CARTOUCHE_FRAMEGEN_TUNE=enabled=0" "$base:5" --render-scale 0.5
has "generation off, upscale still on" "framegen: upscale [0-9]" "$work/alone/log"
file=$(csv alone)
[ -n "$file" ] && in_range "every real frame shown once:" "$(mean "$file" 3)" "$(scaled 0.95)" "$(scaled 1.05)"
run mtl4 "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_UPSCALE=chain" "$base:6" --mtl4 --render-scale 0.5
has "MTL4 path upscaled" "framegen: upscale [0-9]" "$work/mtl4/log"
grep -q 'framegen: disabled' "$work/mtl4/log" && bad "MTL4 never disabled" "" "$(grep disabled "$work/mtl4/log")" || ok "MTL4 never disabled"
file=$(csv mtl4)
[ -n "$file" ] && in_range "MTL4 shown rate doubled:" "$(mean "$file" 3)" "$(scaled 1.8)" "$(scaled 2.2)"
run fail "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_UPSCALE=chain CARTOUCHE_FRAMEGEN_FAIL=drawable" "$base:4" --render-scale 0.5
has "a failure disables" "framegen: disabled forced failure: drawable" "$work/fail/log"
has "and takes our layer down" "framegen: upscale off: stopped" "$work/fail/log"
read -r _ rendered _ shown < "$work/fail/out"
[ "${shown:-0}" -ge $((${rendered:-0} - 10)) ] && ok "the game's frames still show ($shown of $rendered)" || bad "frames shown" ">= rendered - 10" "$(cat "$work/fail/out")"
run native "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_UPSCALE=chain" "$base:2"
has "a game at the screen's size is left alone" "framegen: upscale off: the game renders at the screen's size" "$work/native/log"

# In Wine, games render in points (Retina mode off): on a Retina screen ours is the upscale
scene="$bin/scene.exe"
for backend in dxmt d3dmetal; do
  echo "== $backend in Wine, clicks posted to Wine =="
  dir="$work/wine-$backend"
  mkdir -p "$dir"
  before=$("$mouse" front)
  CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$dir" CARTOUCHE_FRAMEGEN_UPSCALE=chain \
    CARTOUCHE_FRAMEGEN_DUMP="$dir/shown.ppm:$((base * 10))" CARTOUCHE_FRAMEGEN_CLICKS="0.25,0.3;0.7,0.62;0.5,0.85" \
    sh "$here/d3d11/run.sh" "$scene" "$lib" "$backend" on "$base" 13 0 mouse > "$dir/out" 2> "$dir/log"
  if grep -q "run.sh: no prepared" "$dir/log"; then
    echo "  skip  Cartouche has no $backend Wine on this Mac"; continue
  fi
  line=$(grep 'framegen: upscale [0-9]' "$dir/log" | head -1)
  if [ -z "$line" ]; then
    bad "$backend: our layer is up" "framegen: upscale WxH -> WxH" "$(grep framegen: "$dir/log" | head -4 | tr '\n' ' ')"; continue
  fi
  ok "$backend: our layer is up ($(echo "$line" | awk '{ print $3 " -> " $5 }'))"
  [ "$("$mouse" front)" = "$before" ] && ok "$backend: the front app kept the focus ($before)" || bad "$backend: focus" "$before" "$("$mouse" front)"
  lw=$(echo "$line" | sed 's/.* \([0-9.]*\)x[0-9.]* points.*/\1/')
  { echo "points $lw"; sed -n 's/^framegen: click posted at \(.*\)/click \1/p' "$dir/log"; } > "$dir/clicks"
  landed=$(grep -c '^click' "$dir/out")
  [ "$landed" -ge 3 ] && ok "$backend: Wine got the 3 clicks ($(grep '^click' "$dir/out" | tr '\n' ' '))" || bad "$backend: Wine got the clicks" "3 click lines" "$landed"
  marks_match "$backend" "$dir/shown.ppm" "$dir/clicks"
  sizes=$(grep 'framegen: upscale [0-9]' "$dir/log" | awk '{ print $3, $5 }' | sort -u | wc -l | tr -d ' ')
  [ "$sizes" = 1 ] && ok "$backend: one size all along" || bad "$backend: one size all along" 1 "$(grep 'framegen: upscale' "$dir/log" | tr '\n' ' ')"
  grep -q 'framegen: disabled' "$dir/log" && bad "$backend: never disabled" "" "$(grep disabled "$dir/log")" || ok "$backend: never disabled"
  file=$(find "$dir" -name 'framegen-*.csv' | head -1)
  [ -n "$file" ] && in_range "$backend: shown rate doubled:" "$(mean "$file" 3)" "$(scaled 1.8)" "$(scaled 2.2)"
  [ -n "$file" ] && echo "  info  $backend: our GPU per generated frame $(mean "$file" 4) ms"
done

if [ "$fails" -eq 0 ]; then
  echo "==> framegen upscale: all assertions hold"
else
  echo "==> framegen upscale: $fails failed"
  exit 1
fi
