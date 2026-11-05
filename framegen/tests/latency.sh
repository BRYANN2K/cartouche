#!/bin/sh
# Relative click-to-photon latency on the stand-in game: CGEvent clicks flip a square in the
# middle, and each click's latency runs to the first frame shown with the change. That frame is
# the first real one drawn after the click, or a generated one before it whose centre pixel is
# already past half way to the new colour. No camera: display scan-out is not in the numbers.
# Configurations: off at the display's rate, then per base rate: off capped at the base, off at
# twice the base, the library with generation off (hooks only), the library as Cartouche launches
# it (interpolation off, HUD on), frame generation on, and frame generation on with the library's
# limiter holding an uncapped game at the base.
# Usage: latency.sh <framegen.dylib> <folder with game and winemetal.so> [clicks] [base fps ...]
# The window goes to the Mac's own screen; with bases over half its refresh, ask for a faster
# one with CARTOUCHE_FRAMEGEN_SCREEN=external.
set -u
lib="$1"
bin="$2"
clicks="${3:-100}"
shift 3 2> /dev/null || shift $#
bases="${*:-40 60}"
game="$bin/game"
stub="$bin/winemetal.so"
work="${LATENCY_DIR:-$(mktemp -d)}"
mkdir -p "$work"
# A sleeping display shows no frame: wake it and keep it on while this runs
caffeinate -u -t 2
caffeinate -d -w $$ &

# summary <name> <game output> [probe log]: median and p95 of the real frame's latency, and of
# the first change shown, generated frames included
summary() {
  name="$1"; out="$2"; probe="${3:-}"
  [ -f "$probe" ] || probe=/dev/null
  awk -v name="$name" -v probe="$probe" '
    BEGIN { while ((getline line < probe) > 0) { split(line, f, " "); if (f[1] == "generated" && f[2] > 0) { gt[++g] = f[2]; gv[g] = f[3] } } }
    $1 == "click" && $5 > 0 {
      i = $2; posted = $3; shown = $5
      first = shown
      white = (i % 2 == 0)
      for (k = 1; k <= g; k++)
        if (gt[k] > posted && gt[k] < first && (white ? gv[k] >= 128 : gv[k] < 128))
          first = gt[k]
      n++
      real[n] = (shown - posted) * 1000
      change[n] = (first - posted) * 1000
      event[n] = ($4 - posted) * 1000
      earlier += first < shown
    }
    function sort(a, n,   i, j, t) { for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] > a[j]; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t } }
    function pct(a, n, p,   r) { r = int(p * n + 0.999999); if (r < 1) r = 1; return a[r] }
    END {
      if (n == 0) { printf "%-34s no click measured\n", name; exit }
      sort(real, n); sort(change, n); sort(event, n)
      printf "%-34s %4d  %6.1f %6.1f   %6.1f %6.1f   %4d   %5.2f\n", name, n, pct(real, n, 0.5), pct(real, n, 0.95),
        pct(change, n, 0.5), pct(change, n, 0.95), earlier, pct(event, n, 0.5)
    }' "$out"
}

# run <name> <rate> <with library: 0 no, 1 hooks only, 2 generation on, 3 generation and the
# limiter at LIMIT fps, 4 interpolation off with the HUD>. A run that saw Wine or another test start on the way is made again, up
# to LATENCY_TRIES times. LATENCY_ONLY, an extended regex, keeps the configurations it matches.
run() {
  name="$1"; rate="$2"; mode="$3"
  echo "$name" | grep -Eq "${LATENCY_ONLY:-.}" || return 0
  dir="$work/$name"
  try=0
  while :; do
    rm -rf "$dir"
    mkdir -p "$dir"
    quiet
    ( while :; do busy && echo seen >> "$dir/busy"; sleep 1; done ) &
    watcher=$!
    case "$mode" in
      0) "$game" "$rate:600" --latency "$clicks" > "$dir/out" 2> "$dir/log" ;;
      1) env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$dir" \
           CARTOUCHE_FRAMEGEN_TUNE=enabled=0 "$game" "$rate:600" --latency "$clicks" > "$dir/out" 2> "$dir/log" ;;
      2) env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$dir" \
           CARTOUCHE_FRAMEGEN_PROBE_LOG="$dir/probe" "$game" "$rate:600" --latency "$clicks" > "$dir/out" 2> "$dir/log" ;;
      3) env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$dir" \
           CARTOUCHE_FRAMEGEN_TUNE="limit=$LIMIT" CARTOUCHE_FRAMEGEN_PROBE_LOG="$dir/probe" "$game" "$rate:600" \
           --latency "$clicks" > "$dir/out" 2> "$dir/log" ;;
      4) env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_INTERPOLATE=0 CARTOUCHE_FRAMEGEN_STATS=1 \
           CARTOUCHE_FRAMEGEN_DIR="$dir" CARTOUCHE_OVERLAY=std CARTOUCHE_OVERLAY_POS=tl CARTOUCHE_OVERLAY_CONTROL=1 \
           "$game" "$rate:600" --latency "$clicks" > "$dir/out" 2> "$dir/log" ;;
    esac
    kill "$watcher" 2> /dev/null
    wait "$watcher" 2> /dev/null
    try=$((try + 1))
    [ -f "$dir/busy" ] || break
    echo "  $name: something else ran meanwhile, try $try"
    [ "$try" -lt "${LATENCY_TRIES:-5}" ] || break
  done
  summary "$name" "$dir/out" "$dir/probe"
  csv=$(find "$dir" -name 'framegen-*.csv' | head -1)
  if [ -n "$csv" ]; then
    sed '1,2d;$d' "$csv" | awk -F, -v name="$name" '{ r += $2; p += $3; l += $19; s += $9; n++ }
      END { if (n) printf "%-34s render %.1f fps, shown %.1f fps, library latency %.1f ms, paused %d s\n", "  (" name ")", r / n, p / n, l / n, s }'
  fi
}

# Another Wine or another frame generation test (other agents share this Mac) skews the numbers
busy() {
  pgrep -q wine && return 0
  for p in $(pgrep -f "$others"); do
    [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = "$$" ] || return 0
  done
  return 1
}
others='out/framegen/(game|tune|mfx|pipeline|framegen_test)|scene\.exe'

quiet() {
  while busy; do
    [ -n "${told:-}" ] || echo "  waiting: Wine or another frame generation test is running"; told=1
    sleep 10
  done
}

echo "work: $work"
printf '%-34s %4s  %6s %6s   %6s %6s   %4s   %5s\n' "configuration" "n" "real" "p95" "change" "p95" "gen" "event"
run "off, uncapped" 1000 0
for base in $bases; do
  run "off, capped $base" "$base" 0
  run "off, native $((base * 2))" "$((base * 2))" 0
  run "hooks only, capped $base" "$base" 1
  run "interpolation off + HUD, capped $base" "$base" 4
  run "on 2x, base $base" "$base" 2
  LIMIT=$base run "on 2x, limiter $base, uncapped" 1000 3
done
