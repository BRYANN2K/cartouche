#!/bin/sh
# shellcheck disable=SC2015,SC2046 # ok and bad never fail, so A && ok || bad is safe; probe answers two words
# The overlay in the stand-in game: off by default, drawn on every shown frame with generation
# on, real and generated, while the generated frames (the interpolator's output, before the
# overlay) never show the panel; on the upscaled layer too; the metrics block read by a native
# arm64 process while the game runs, read-only, gone when the game ends.
# Usage: overlay.sh <framegen.dylib> <folder with game, winemetal.so, metrics-read>
set -u
lib="$1"
bin="$2"
game="$bin/game"
stub="$bin/winemetal.so"
reader="$bin/metrics-read"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
has() { if grep -q "$2" "$3"; then ok "$1"; else bad "$1" "$2" "$(grep framegen: "$3" | head -3 | tr '\n' ' ')"; fi; }
in_range() { awk -v v="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }' && ok "$1 $2" || bad "$1" "$3..$4" "$2"; }
field() { tr ' ' '\n' < "$1" | sed -n "s/^$2=//p" | head -1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

hz=$("$game" --hz)
base=$((hz >= 80 ? 40 : hz / 2))
scaled() { awk -v b="$base" -v f="$1" 'BEGIN { print b * f }'; }
echo "test screen ${hz} Hz, base ${base} fps"

# start <name> "<VAR=value ...>" <game arguments...>: the game in the background, its pid in pid
start() {
  name="$1"; vars="$2"; shift 2
  mkdir -p "$work/$name"
  # shellcheck disable=SC2086 # vars is a list of assignments
  env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN_DIR="$work/$name" CARTOUCHE_FRAMEGEN_FRONT=1 $vars "$game" "$@" \
    > "$work/$name/out" 2> "$work/$name/log" &
  pid=$!
}
all_shown() {
  read -r _ rendered _ shown < "$work/$2/out"
  if [ "${rendered:-0}" -gt 0 ] && [ "${shown:-0}" -ge $((rendered - 10)) ]; then ok "$1 ($shown of $rendered)";
  else bad "$1" "rendered N shown >= N - 10" "$(cat "$work/$2/out")"; fi
}
csv() { find "$work/$1" -name 'framegen-*.csv' | head -1; }
mean() { sed '1,2d;$d' "$1" | awk -F, -v c="$2" '{ s += $c; n++ } END { printf "%.1f", s / n }'; }
# probe <file> <label>: how many shown frames with that label, and how many of them show the ink
# panel. A dropped frame (time 0) is left out: its pixel may never have been copied.
probe() {
  awk -v l="$2" '{ if ($1 == "overlay") { label = $1 " " $2; t = $3; r = $4; g = $5; b = $6 } else { label = $1; t = $2; r = $3; g = $4; b = $5 } }
    label == l && t > 0 { n++; if (r < 80 && g < 80 && b < 95) ink++ }
    END { printf "%d %d", n, ink }' "$1"
}

echo "== off by default =="
start off "CARTOUCHE_FRAMEGEN=1" "$base:3"
sleep 2
"$reader" "$pid" > "$work/off/read" 2>&1
wait "$pid"
grep -q 'framegen: overlay\|framegen: metrics' "$work/off/log" && bad "no overlay nor block without the variables" "" "$(grep 'overlay\|metrics' "$work/off/log")" \
  || ok "no overlay nor block without the variables"
grep -q '^missing' "$work/off/read" && ok "no shared block" || bad "no shared block" "missing" "$(cat "$work/off/read")"

echo "== full, top left, generation on =="
dump="$work/fg/shown.ppm"
start fg "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_OVERLAY=full CARTOUCHE_OVERLAY_POS=tl \
  CARTOUCHE_FRAMEGEN_PROBE_LOG=$work/fg/probe CARTOUCHE_FRAMEGEN_PROBE_AT=overlay CARTOUCHE_FRAMEGEN_DUMP=$dump:$((base * 6))" "$base:9"
fg_pid=$pid
sleep 6
"$reader" "$fg_pid" > "$work/fg/read" 2>&1
wait "$fg_pid"
"$reader" "$fg_pid" > "$work/fg/after" 2>&1
log="$work/fg/log"
has "the overlay is on" "framegen: overlay full at tl" "$log"
has "the block is published" "framegen: metrics /cartouche-metrics.$fg_pid" "$log"
grep -q 'framegen: disabled' "$log" && bad "never disabled" "" "$(grep disabled "$log")" || ok "never disabled"
all_shown "every real frame is shown" fg
file=$(csv fg)
[ -n "$file" ] && in_range "presented rate still doubled:" "$(mean "$file" 3)" "$(scaled 1.8)" "$(scaled 2.2)"
[ -n "$file" ] && echo "  info  our GPU per generated frame $(mean "$file" 4) ms"
set -- $(probe "$work/fg/probe" generated)
[ "$1" -gt $((base * 3)) ] && [ "$2" -eq 0 ] && ok "the interpolator's output never shows the panel ($1 generated frames, $2 with ink)" \
  || bad "interpolator output without the panel" "> $((base * 3)) frames, 0 with ink" "$1 frames, $2 with ink"
set -- $(probe "$work/fg/probe" "overlay real")
[ "$1" -gt $((base * 3)) ] && [ "$2" -ge $(($1 - 2)) ] && ok "real frames shown with the panel ($2 of $1)" \
  || bad "real frames with the panel" "> $((base * 3)) frames, all with ink" "$2 of $1"
set -- $(probe "$work/fg/probe" "overlay generated")
[ "$1" -gt $((base * 3)) ] && [ "$2" -ge $(($1 - 2)) ] && ok "generated frames shown with the panel ($2 of $1)" \
  || bad "generated frames with the panel" "> $((base * 3)) frames, all with ink" "$2 of $1"
read_ok=$(grep -c '^pid=' "$work/fg/read")
[ "$read_ok" = 1 ] && ok "an arm64 process reads the block: $(cut -c1-150 "$work/fg/read")" || bad "block read" "pid=..." "$(cat "$work/fg/read")"
if [ "$read_ok" = 1 ]; then
  in_range "its presented rate:" "$(field "$work/fg/read" presented)" "$(scaled 1.8)" "$(scaled 2.2)"
  in_range "its real rate:" "$(field "$work/fg/read" real)" "$(scaled 0.95)" "$(scaled 1.05)"
  [ "$(field "$work/fg/read" framegen)" = 1 ] && [ "$(field "$work/fg/read" factor)" = 2 ] && ok "generation on, x2" \
    || bad "generation on, x2" "framegen=1 factor=2" "$(field "$work/fg/read" framegen) $(field "$work/fg/read" factor)"
  [ "$(field "$work/fg/read" frames)" -gt $((base * 6)) ] && ok "frame times written ($(field "$work/fg/read" frames))" \
    || bad "frame times" "> $((base * 6))" "$(field "$work/fg/read" frames)"
  [ "$(field "$work/fg/read" write)" = refused ] && ok "read-only for other processes" || bad "read-only" "write=refused" "$(field "$work/fg/read" write)"
fi
grep -q '^missing' "$work/fg/after" && ok "the block goes with the game" || bad "block removed at exit" "missing" "$(cat "$work/fg/after")"
[ -s "$dump" ] && cp "$dump" "$bin/overlay-game-fg.ppm" && echo "  info  shown frame with the overlay: $bin/overlay-game-fg.ppm"

echo "== std, upscaled layer =="
start up "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_UPSCALE=chain CARTOUCHE_OVERLAY=std CARTOUCHE_OVERLAY_POS=tl \
  CARTOUCHE_FRAMEGEN_PROBE_LOG=$work/up/probe CARTOUCHE_FRAMEGEN_PROBE_AT=overlay CARTOUCHE_FRAMEGEN_DUMP=$work/up/shown.ppm:$((base * 5))" \
  "$base:7" --render-scale 0.5
sleep 5
"$reader" "$pid" > "$work/up/read" 2>&1
wait "$pid"
has "our layer is up" "framegen: upscale [0-9]*x[0-9]* -> [0-9]*x[0-9]* " "$work/up/log"
[ "$(field "$work/up/read" upscale)" = 1 ] && ok "the block names the spatial upscale: $(tr ' ' '\n' < "$work/up/read" | grep -A1 '^upscale=' | tr '\n' ' ')" \
  || bad "spatial upscale in the block" "upscale=1" "$(cat "$work/up/read")"
set -- $(probe "$work/up/probe" "overlay real")
[ "$1" -gt $((base * 2)) ] && [ "$2" -ge $(($1 - 2)) ] && ok "upscaled real frames shown with the panel ($2 of $1)" \
  || bad "upscaled frames with the panel" "> $((base * 2)) frames, all with ink" "$2 of $1"
set -- $(probe "$work/up/probe" generated)
[ "$2" -eq 0 ] && ok "and the interpolator's output never shows it ($1 generated frames)" || bad "interpolator output" "0 with ink" "$2 of $1"
[ -s "$work/up/shown.ppm" ] && cp "$work/up/shown.ppm" "$bin/overlay-game-upscaled.ppm"

echo "== CARTOUCHE_METRICS=1 alone =="
start metrics "CARTOUCHE_FRAMEGEN=1 CARTOUCHE_METRICS=1" "$base:4"
sleep 3
"$reader" "$pid" > "$work/metrics/read" 2>&1
wait "$pid"
grep -q '^pid=' "$work/metrics/read" && ok "the block without the overlay" || bad "block without the overlay" "pid=..." "$(cat "$work/metrics/read")"
grep -q 'framegen: overlay' "$work/metrics/log" && bad "no overlay" "" "$(grep overlay "$work/metrics/log")" || ok "and no overlay"

[ "$fails" -eq 0 ] && echo "overlay game: all ok" || echo "overlay game: $fails FAIL"
[ "$fails" -eq 0 ]
