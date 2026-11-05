#!/bin/sh
# Energy per shown frame on the stand-in game at 1920x1080, from powermetrics: GPU power and
# combined power (CPU + GPU + ANE), divided by the frames that reached the screen. Per base
# rate: off at the base, native at twice the base, and frame generation on. WATTS_THROTTLE=1
# adds a 20 minute run with generation on, one row a minute, to see throttling.
# powermetrics needs root: run "sudo -v" first, the script only uses sudo -n.
# The window goes to the Mac's own screen; with bases over half its refresh, ask for a faster
# one with CARTOUCHE_FRAMEGEN_SCREEN=external.
# Usage: watts.sh <framegen.dylib> <folder with game and winemetal.so> [seconds] [base fps ...]
set -u
lib="$1"
bin="$2"
seconds="${3:-60}"
shift 3 2> /dev/null || shift $#
bases="${*:-40 60}"
game="$bin/game"
stub="$bin/winemetal.so"
load="${WATTS_LOAD:-8}"
work="${WATTS_DIR:-$(mktemp -d)}"
mkdir -p "$work"
# A sleeping display shows no frame: wake it and keep it on while this runs
caffeinate -u -t 2
caffeinate -d -w $$ &

if ! sudo -n /usr/bin/powermetrics -h > /dev/null 2>&1; then
  echo "watts: powermetrics needs root; run 'sudo -v' in this terminal, then this again"
  exit 77
fi

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

# One line per powermetrics sample: GPU mW, combined mW, thermal pressure
samples() {
  awk '/^\*\*\* Sampled system activity/ { if (n++) print g, c, t; g = c = 0; t = "?" }
    /^GPU Power:/ { g = $3 }
    /^Combined Power/ { c = $NF == "mW" ? $(NF - 1) : $NF }
    /^Current pressure level:/ { t = $4 }
    END { if (n) print g, c, t }' "$1"
}

# run <name> <rate> <with library: 0 no, 2 generation on> <seconds>
run() {
  name="$1"; rate="$2"; mode="$3"; span="$4"
  dir="$work/$name"
  mkdir -p "$dir"
  quiet
  total=$((span + 12))
  if [ "$mode" = 2 ]; then
    env DYLD_INSERT_LIBRARIES="$stub:$lib" CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$dir" \
      "$game" "$rate:$total" --load "$load" > "$dir/out" 2> "$dir/log" &
  else
    "$game" "$rate:$total" --load "$load" > "$dir/out" 2> "$dir/log" &
  fi
  pid=$!
  ( while :; do busy && echo seen >> "$dir/busy"; sleep 1; done ) &
  watcher=$!
  sleep 5
  # shellcheck disable=SC2024 # the sampler alone needs sudo; the log file stays user-owned
  sudo -n /usr/bin/powermetrics -i 1000 -n "$span" --samplers cpu_power,gpu_power,thermal > "$dir/power" 2> /dev/null
  wait "$pid"
  kill "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  [ -f "$dir/busy" ] && echo "  $name: something else ran meanwhile, numbers skewed"
  samples "$dir/power" > "$dir/samples"
  csv=$(find "$dir" -name 'framegen-*.csv' | head -1)
  if [ -n "$csv" ]; then
    shown=$(sed '1,6d;$d' "$csv" | awk -F, '{ s += $3; n++ } END { printf "%.1f", n ? s / n : 0 }')
    gpu=$(sed '1,6d;$d' "$csv" | awk -F, '{ s += $4; n++ } END { printf "%.2f", n ? s / n : 0 }')
  else
    read -r _ _ _ count < "$dir/out"
    shown=$(awk -v c="${count:-0}" -v t="$total" 'BEGIN { printf "%.1f", c / t }')
    gpu="-"
  fi
  awk -v name="$name" -v shown="$shown" -v gpu="$gpu" '{ g += $1; c += $2; n++ }
    END { if (!n || shown <= 0) { printf "%-26s no sample\n", name; exit }
      printf "%-26s %6.1f  %7.0f %7.0f   %6.2f %6.2f   %s\n", name, shown, g / n, c / n, g / n / shown, c / n / shown, gpu }' "$dir/samples"
}

echo "work: $work"
quiet
# shellcheck disable=SC2024 # the sampler alone needs sudo; the log file stays user-owned
sudo -n /usr/bin/powermetrics -i 1000 -n 10 --samplers cpu_power,gpu_power,thermal > "$work/idle" 2> /dev/null
samples "$work/idle" | awk '{ g += $1; c += $2; n++ } END { printf "idle: GPU %.0f mW, combined %.0f mW\n", g / n, c / n }'
printf '%-26s %6s  %7s %7s   %6s %6s   %s\n' "configuration" "fps" "GPU mW" "all mW" "GPU mJ" "all mJ" "gpu_ms"
for base in $bases; do
  run "off $base" "$base" 0 "$seconds"
  run "native $((base * 2))" "$((base * 2))" 0 "$seconds"
  run "on 2x, base $base" "$base" 2 "$seconds"
done

if [ "${WATTS_THROTTLE:-0}" = 1 ]; then
  base="${WATTS_THROTTLE_BASE:-60}"
  run "20 min, on 2x, base $base" "$base" 2 1200
  dir="$work/20 min, on 2x, base $base"
  csv=$(find "$dir" -name 'framegen-*.csv' | head -1)
  echo "minute  GPU mW  all mW  pressure  shown fps  gpu_ms"
  awk '{ m = int((NR - 1) / 60); g[m] += $1; c[m] += $2; n[m]++; t[m] = $3 }
    END { for (k = 0; k in n; k++) printf "%d %.0f %.0f %s\n", k + 1, g[k] / n[k], c[k] / n[k], t[k] }' "$dir/samples" > "$dir/minutes"
  sed '1,6d' "$csv" | awk -F, '{ m = int((NR - 1) / 60); s[m] += $3; q[m] += $4; n[m]++ }
    END { for (k = 0; k in n; k++) printf "%.1f %.2f\n", s[k] / n[k], q[k] / n[k] }' > "$dir/rates"
  paste -d' ' "$dir/minutes" "$dir/rates" | awk '{ printf "%6d  %6d  %6d  %-8s  %9s  %6s\n", $1, $2, $3, $4, $5, $6 }'
fi
