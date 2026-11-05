#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# The frame generation library in a stand-in game window: off without the variable, double
# the rate with steady pacing on the classic and MTL4 paths, follow an MTL4FX scaler's data and
# give way to an MTL4FX interpolator, take the Neural Engine's flow, pause and resume, fall back on
# forced failures, survive a resize, answer the loader probe, and refuse a hardened binary.
# Runs on the screen test windows go to (the Mac's own, see screen.h): the base rate is 40 fps
# from 80 Hz, half the refresh below, and the expected rates follow it.
# Usage: framegen.sh <framegen.dylib> <folder with game and winemetal.so>
set -u
lib="$1"
bin="$2"
game="$bin/game"
stub="$bin/winemetal.so"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
has() { if grep -q "$2" "$3"; then ok "$1"; else bad "$1" "$2" "$(grep framegen: "$3" | head -3 | tr '\n' ' ')"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! "$game" --version > /dev/null 2>&1; then
  echo "==> framegen: the stand-in game does not run here (no Rosetta?)"
  exit 1
fi
hz=$("$game" --hz)
base=$((hz >= 80 ? 40 : hz / 2))
# scaled <factor>: the base rate times factor
scaled() { awk -v b="$base" -v f="$1" 'BEGIN { print b * f }'; }
echo "test screen ${hz} Hz, base ${base} fps"

# run <name> "<VAR=value ...>" <game arguments...>: the game with the library. Variables go
# through env, as assignments before a function call outlive it in sh. The window comes to the
# front: behind other windows macOS drops its frames.
run() {
  name="$1"; vars="$2"; shift 2
  mkdir -p "$work/$name"
  # shellcheck disable=SC2086 # vars is a list of assignments
  env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN_DIR="$work/$name" CARTOUCHE_FRAMEGEN_FRONT=1 $vars "$game" "$@" \
    > "$work/$name/out" 2> "$work/$name/log"
}
# All real frames reach the screen, but for a few at the window's opening and in flight at exit
all_shown() {
  what="$1"
  read -r _ rendered _ shown < "$work/$2/out"
  if [ "${rendered:-0}" -gt 0 ] && [ "${shown:-0}" -ge $((rendered - 10)) ]; then ok "$what ($shown of $rendered)";
  else bad "$what" "rendered N shown >= N - 10" "$(cat "$work/$2/out")"; fi
}
csv() { find "$work/$1" -name 'framegen-*.csv' | head -1; }
# Whole seconds only: no first row, no last row
middle() { sed '1,2d;$d' "$1"; }

echo "== off =="
run off "" "$base:2"
[ ! -s "$work/off/log" ] && ok "without CARTOUCHE_FRAMEGEN the library says nothing" || bad "silent" "" "$(cat "$work/off/log")"
all_shown "without CARTOUCHE_FRAMEGEN every frame is shown" off

echo "== classic path, $base fps =="
run classic "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1" "$base:30"
log="$work/classic/log"
has "loaded" "framegen: loaded arch=x86_64" "$log"
has "active on the DXMT stand-in" "framegen: active backend=DXMT size=1920x1080" "$log"
grep -q 'framegen: disabled' "$log" && bad "never disabled" "" "$(grep disabled "$log")" || ok "never disabled"
all_shown "every real frame is shown" classic
file=$(csv classic)
[ -n "$file" ] && ok "stats file $(basename "$file")" || bad "stats file" "framegen-*.csv" "none"
rows=$(sed 1d "$file" | wc -l | tr -d ' ')
[ "$rows" -ge 25 ] && ok "a row per second ($rows)" || bad "at least 25 rows" ">= 25" "$rows"
is_range() { awk -v v="$3" -v lo="$4" -v hi="$5" 'BEGIN { exit !(v >= lo && v <= hi) }' && ok "$1 $3" || bad "$1" "$4..$5" "$3"; }
presented=$(middle "$file" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
rendered=$(middle "$file" | awk -F, '{ s += $2; n++ } END { printf "%.1f", s / n }')
is_range "presented rate doubled:" x "$presented" "$(scaled 1.8)" "$(scaled 2.2)"
is_range "render rate kept:" x "$rendered" "$(scaled 0.95)" "$(scaled 1.05)"
# A fixed refresh quantises intervals, and the window server misses some refreshes even for a
# game that presents on its own: compare with the stand-in presenting twice the base itself
run native "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_TUNE=enabled=0" "$((base * 2)):15"
native=$(csv native)
excess() { middle "$1" | awk -F, '{ s += $7 - $11; n++ } END { printf "%.2f", s / n }'; }
hitches() { middle "$1" | awk -F, '{ s += $15 + $16; n++ } END { printf "%.1f", s / n }'; }
fg_excess=$(excess "$file"); native_excess=$(excess "$native")
awk -v a="$fg_excess" -v b="$native_excess" 'BEGIN { exit !(a <= b + 0.5) }' \
  && ok "interval deviation above the refresh floor no worse than a native $((base * 2)) fps game: $fg_excess ms vs $native_excess ms" \
  || bad "interval deviation above the refresh floor" "<= $native_excess + 0.5 ms" "$fg_excess ms"
fg_hitches=$(hitches "$file"); native_hitches=$(hitches "$native")
awk -v a="$fg_hitches" -v b="$native_hitches" 'BEGIN { exit !(a <= b + 0.5) }' \
  && ok "intervals of 3 refreshes or more no more often than a native $((base * 2)) fps game: $fg_hitches/s vs $native_hitches/s" \
  || bad "intervals of 3 refreshes or more" "<= $native_hitches/s + 0.5" "$fg_hitches/s"
echo "  info  shown intervals by refreshes 1/2/3/4+: $(middle "$file" | awk -F, '{ a += $13; b += $14; c += $15; d += $16 } END { print a "/" b "/" c "/" d }'), dropped $(middle "$file" | awk -F, '{ s += $10 } END { print s + 0 }'), longest waits: ours $(middle "$file" | awk -F, '$17 > m { m = $17 } END { print m + 0 }') ms, game $(middle "$file" | awk -F, '$18 > m { m = $18 } END { print m + 0 }') ms"
gpu=$(middle "$file" | awk -F, '{ s += $4; n++ } END { printf "%.2f", s / n }')
echo "  info  library GPU time per generated frame at 1920x1080: $gpu ms"

echo "== interpolation off, as Cartouche launches it =="
# The HUD's variables as the app sets them; the test window's enabled=1 cannot turn generation on
run nointerp "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_INTERPOLATE=0 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_TUNE=enabled=1 \
  CARTOUCHE_OVERLAY=std CARTOUCHE_OVERLAY_POS=tl CARTOUCHE_OVERLAY_CONTROL=1" "$base:10"
log="$work/nointerp/log"
has "says so" "framegen: interpolation off" "$log"
has "takes the presents for the HUD" "framegen: overlay std at tl" "$log"
grep -q 'framegen: \(disabled\|paused\)' "$log" && bad "never disabled or paused" "" "$(grep 'disabled\|paused' "$log")" || ok "never disabled or paused"
all_shown "every real frame is shown" nointerp
presented=$(middle "$(csv nointerp)" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
rendered=$(middle "$(csv nointerp)" | awk -F, '{ s += $2; n++ } END { printf "%.1f", s / n }')
is_range "real frames only, presented at the render rate:" x "$presented" "$(scaled 0.95)" "$(scaled 1.05)"
is_range "render rate kept:" x "$rendered" "$(scaled 0.95)" "$(scaled 1.05)"
admit=$(middle "$(csv nointerp)" | awk -F, '$18 > m { m = $18 } END { print m + 0 }')
is_range "the game never waits on the library, longest wait ms:" x "$admit" 0 0
run nointerp4 "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_INTERPOLATE=0 CARTOUCHE_FRAMEGEN_STATS=1" "$base:6" --mtl4
all_shown "MTL4 path: every real frame is shown" nointerp4
presented=$(middle "$(csv nointerp4)" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
is_range "MTL4 path: presented at the render rate:" x "$presented" "$(scaled 0.95)" "$(scaled 1.05)"
# Without the HUD or stats, only the temporal scaler is hooked
run untouched "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_INTERPOLATE=0" "$base:4" --mtl4 --mtl4fx
log="$work/untouched/log"
has "presents untouched" "framegen: interpolation off, presents untouched" "$log"
grep -q 'framegen: active' "$log" && bad "no present thread" "" "$(grep active "$log")" || ok "no present thread"
has "the MTL4FX scaler is still seen" "framegen: engine data scaler=.* mtl4=1" "$log"
has "and left as made without the opt-in" "temporal: Metal 4 scaler left as made" "$log"
grep -q 'framegen: engine motion in use' "$log" && bad "no motion copies" "" "engine motion in use" || ok "no motion copies"
all_shown "every real frame is shown" untouched

echo "== limiter =="
# Long intervals: longer than the output period rounded up to whole refreshes
longs() { middle "$1" | awk -F, '{ s += $12; n++ } END { printf "%.2f", s / n }'; }
# An uncapped game held at half the refresh: every refresh shows a frame, and no real frame waits
run limit "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_TUNE=limit=auto" 250:20
grep -q 'framegen: paused' "$work/limit/log" && bad "never paused" "" "$(grep paused "$work/limit/log")" || ok "never paused"
all_shown "every real frame is shown" limit
refresh=$(middle "$(csv limit)" | awk -F, '{ s += $8; n++ } END { printf "%.3f", s / n }')
hz=$(awk -v r="$refresh" 'BEGIN { printf "%.0f", (r > 0 ? 1000 / r : 0) }')
rendered=$(middle "$(csv limit)" | awk -F, '{ s += $2; n++ } END { printf "%.1f", s / n }')
presented=$(middle "$(csv limit)" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
is_range "limit=auto holds 250 fps at half of ${hz} Hz:" x "$rendered" "$(awk -v h="$hz" 'BEGIN { print h / 2 * 0.97 }')" "$(awk -v h="$hz" 'BEGIN { print h / 2 * 1.01 }')"
is_range "and shows a frame on every refresh:" x "$presented" "$(awk -v h="$hz" 'BEGIN { print h * 0.95 }')" "$hz"
is_range "long intervals per second:" x "$(longs "$(csv limit)")" 0 0.99
echo "  info  limiter, latency of real frames $(middle "$(csv limit)" | awk -F, '{ s += $19; n++ } END { printf "%.1f", s / n }') ms, longest game wait $(middle "$(csv limit)" | awk -F, '$18 > m { m = $18 } END { print m + 0 }') ms"

echo "== MTL4 path, $base fps =="
run mtl4 "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1" "$base:10" --mtl4
has "active" "framegen: active" "$work/mtl4/log"
grep -q 'framegen: disabled' "$work/mtl4/log" && bad "never disabled" "" "$(grep disabled "$work/mtl4/log")" || ok "never disabled"
all_shown "every real frame is shown" mtl4
presented=$(middle "$(csv mtl4)" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
is_range "presented rate doubled:" x "$presented" "$(scaled 1.8)" "$(scaled 2.2)"

# The helper and the networks sit next to the library: RIFE lean (=1), Cartouche FG 1 (=fg1)
for ane in 1 fg1; do
  [ "$ane" = 1 ] && name=framegen-flow.mlmodelc || name=framegen-flow-$ane.mlmodelc
  echo "== the Neural Engine's flow, $ane =="
  if [ ! -x "$(dirname "$lib")/framegen-ane" ] || [ ! -d "$(dirname "$lib")/$name" ]; then
    echo "  skip  no framegen-ane or $name next to the library"
    continue
  fi
  run "ane-$ane" "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_ANE=$ane" "$base:10"
  has "the helper's flow is in use" "framegen: ane flow in use" "$work/ane-$ane/log"
  all_shown "every real frame is shown" "ane-$ane"
  presented=$(sed '1,3d;$d' "$(csv "ane-$ane")" | awk -F, '{ s += $3; n++ } END { printf "%.1f", s / n }')
  is_range "presented rate doubled:" x "$presented" "$(scaled 1.8)" "$(scaled 2.2)"
  # The helper looks for the game every 200 ms
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "framegen-ane dev.cartouche" > /dev/null || break; sleep 0.2; done
  pgrep -f "framegen-ane dev.cartouche" > /dev/null && bad "helper ends with the game" "no framegen-ane left" "still running" || ok "the helper ends with the game"
done

echo "== MTL4FX temporal scaler and interpolator =="
run mtl4fx "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_TEMPORAL4=1" "$base:6" --mtl4 --mtl4fx
has "the MTL4FX scaler's data is seen" "framegen: engine data scaler=.* motion=960x540 .*jitter=0.25,-0.25 reset=1 mtl4=1" "$work/mtl4fx/log"
has "its motion replaces the estimate" "framegen: engine motion in use 960x540" "$work/mtl4fx/log"
has "our chain takes the MTL4FX scaler" "framegen: temporal: in use output=1920x1080 .*sharpen=1 .*mtl4=1" "$work/mtl4fx/log"
grep -q 'framegen: disabled' "$work/mtl4fx/log" && bad "never disabled" "" "$(grep disabled "$work/mtl4fx/log")" || ok "never disabled"
all_shown "every real frame is shown" mtl4fx
run mtl4fi "CARTOUCHE_FRAMEGEN=1" "$base:2" --mtl4 --mtl4fx-interpolator
has "a runner's MTL4FX interpolator turns ours off" "framegen: disabled runner-fg" "$work/mtl4fi/log"
all_shown "and its frames are shown" mtl4fi

echo "== pause and resume =="
run pause "CARTOUCHE_FRAMEGEN=1" "25:5,$base:6"
has "paused under 30 fps" "framegen: paused (base <30 fps)" "$work/pause/log"
has "resumed at $base fps" "framegen: resumed" "$work/pause/log"
all_shown "every real frame is shown" pause
# A slow start, then faster than the display can double: the second reason is told, and the
# limiter at half the refresh lets generation resume
fast=$((hz * 3 / 4))
run late "CARTOUCHE_FRAMEGEN=1" "20:4,$fast:8"
if [ $((fast * 2 * 10)) -gt $((hz * 11)) ]; then
  has "a slow start then $fast fps on ${hz} Hz says why it stays paused" "framegen: paused (display too slow)" "$work/late/log"
  grep -q 'framegen: resumed' "$work/late/log" && bad "stays paused" "" "resumed" || ok "and stays paused"
else
  has "a slow start then $fast fps on ${hz} Hz resumes" "framegen: resumed" "$work/late/log"
fi
run limited "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_TUNE=limit=auto" "20:4,$fast:8"
has "with limit=auto the same game resumes" "framegen: resumed" "$work/limited/log"

echo "== failures =="
run kernels "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_FAIL=kernels" "$base:3"
has "a kernel failure disables" "framegen: disabled forced failure: kernels" "$work/kernels/log"
all_shown "and the game still shows its frames" kernels
run drawable "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_FAIL=drawable" "$base:4"
has "a drawable timeout disables" "framegen: disabled forced failure: drawable" "$work/drawable/log"
all_shown "and the game still shows its frames" drawable
mkdir -p "$work/nobackend"
DYLD_INSERT_LIBRARIES="$lib" CARTOUCHE_FRAMEGEN=1 "$game" "$base:2" > "$work/nobackend/out" 2> "$work/nobackend/log"
has "an unknown backend is left alone" "framegen: unsupported backend" "$work/nobackend/log"
all_shown "and its frames are shown" nobackend

echo "== resize =="
run resize "CARTOUCHE_FRAMEGEN=1" "$base:6" --resize
has "a smaller drawable rebuilds the pipeline" "framegen: resized 960x540" "$work/resize/log"
grep -q 'framegen: disabled' "$work/resize/log" && bad "never disabled" "" "$(grep disabled "$work/resize/log")" || ok "never disabled"
all_shown "every real frame is shown" resize

echo "== loader =="
marker="$work/probe"
DYLD_INSERT_LIBRARIES="$lib" CARTOUCHE_FRAMEGEN_PROBE="$marker" "$game" --version > /dev/null 2>&1
[ "$(cat "$marker" 2> /dev/null)" = x86_64 ] && ok "the probe marker names the slice" || bad "probe marker" x86_64 "$(cat "$marker" 2> /dev/null)"
hardened="$work/hardened"
cp "$game" "$hardened"
codesign -fs - -o runtime "$hardened" 2> /dev/null
rm -f "$marker"
DYLD_INSERT_LIBRARIES="$lib" CARTOUCHE_FRAMEGEN_PROBE="$marker" "$hardened" --version > /dev/null 2>&1
[ ! -f "$marker" ] && ok "a hardened binary refuses the library and still runs" || bad "hardened refuses" "no marker" "marker"
# Older systems: the library targets macOS 15, and what came with macOS 26 (MetalFX frame
# interpolation, Metal 4) must be weak, so it loads there and stays off; macOS 27's options sit
# behind @available, which the build enforces
# shellcheck disable=SC2016 # the \$ stays literal: the patterns match $_ in ObjC class symbol names
strong=$(nm -m "$lib" | grep '(undefined) external _OBJC_CLASS_\$_MTL\(FX\|4\)' | sed 's/.*_OBJC_CLASS_\$_//' | tr '\n' ' ')
[ -z "$strong" ] && ok "MetalFX interpolation and Metal 4 classes are weak, for systems before macOS 26" \
  || bad "weak MetalFX and Metal 4 classes" "none strong" "$strong"

if [ "$fails" -eq 0 ]; then
  echo "==> framegen: all assertions hold"
else
  echo "==> framegen: $fails failed"
  exit 1
fi
