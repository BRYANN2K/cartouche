#!/bin/sh
# extfps against the stand-in game's own presentedTime: windowed and covering the screen, at 30,
# 60 and 120 fps, a rate that changes, and a run without extfps for its cost. Run from the repo
# root, after make out/extfps out/framegen/game; takes the GPU lock, keeps the display awake.
#   sh fps-counter/tests/extfps.sh [out dir]
set -u
OUT=${1:-/tmp/extfps-runs}
GAME=out/framegen/game
EXT=out/extfps
mkdir -p "$OUT"
while ! mkdir /tmp/cartouche-gpu.lock 2> /dev/null; do sleep 3; done
echo $$ > /tmp/cartouche-gpu.lock/pid
trap 'rm -f /tmp/cartouche-gpu.lock/pid; rmdir /tmp/cartouche-gpu.lock 2> /dev/null' EXIT INT TERM
caffeinate -d -w $$ &
ws=$(pgrep -x WindowServer)

cputime() { ps -o cputime= -p "$1" | awk -F'[:.]' '{ print ($1 * 60 + $2) + $3 / 100 }'; }

# name schedule extfps-arguments|no [game flags...]
run() {
	name=$1 schedule=$2 measure=$3
	shift 3
	w0=$(cputime "$ws")
	"$GAME" "$schedule" --times "$OUT/$name.game" "$@" > "$OUT/$name.out" 2>&1 &
	g=$!
	sleep 1.5
	if [ "$measure" != no ]; then
		# shellcheck disable=SC2086 # measure is a list of arguments
		if ! "$EXT" --pid $g --seconds 10 --times "$OUT/$name.ext" $measure > "$OUT/$name.extfps" 2>&1; then
			kill $g
			cat "$OUT/$name.extfps"
			exit 1
		fi
	fi
	wait $g
	w1=$(cputime "$ws")
	echo "== $name $schedule $* : $(tail -1 "$OUT/$name.out"); WindowServer cpu $(echo "$w0 $w1" | awk '{ printf "%.1f s", $2 - $1 }')"
	if [ "$measure" != no ]; then
		grep -E '^(count|summary)' "$OUT/$name.extfps"
		python3 -I fps-counter/tests/extfps_compare.py "$OUT/$name.game" "$OUT/$name.ext"
	fi
}

run w30 30:12 "--quiet"
run w60 60:12 "--quiet"
run w120 120:12 "--quiet" --no-vsync
run steps 60:3,20:1,60:3,40:4 "--quiet"
run w60-alone 60:12 no
run w60-size64 60:12 "--quiet --size 64"
run w60-size640 60:12 "--quiet --size 640"
run f30 30:12 "--quiet" --cover
run f60 60:12 "--quiet" --cover
run f120 120:12 "--quiet" --cover --no-vsync
run f60-alone 60:12 no --cover
run w60-live 60:12 ""
