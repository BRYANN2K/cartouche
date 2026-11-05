#!/bin/sh
# Apple's Metal HUD log as an outside source of frame times: the stand-in game at 60 then 40 fps
# with MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1; reads the "metal-HUD:" lines from the unified log
# (log stream, as this user) and from the game's stderr, and compares with the game's presentedTime.
#   sh fps-counter/tests/metalhud.sh [out dir]
set -u
OUT=${1:-/tmp/metalhud-runs}
mkdir -p "$OUT"
while ! mkdir /tmp/cartouche-gpu.lock 2> /dev/null; do sleep 3; done
echo $$ > /tmp/cartouche-gpu.lock/pid
trap 'rm -f /tmp/cartouche-gpu.lock/pid; rmdir /tmp/cartouche-gpu.lock 2> /dev/null' EXIT INT TERM
caffeinate -d -w $$ &

for variant in log log-hidden; do
	/usr/bin/log stream --style compact --level debug --predicate 'process == "game" AND eventMessage BEGINSWITH "metal-HUD"' > "$OUT/$variant.log" 2>&1 &
	l=$!
	sleep 1
	extra=""
	[ "$variant" = log-hidden ] && extra="MTL_HUD_OPACITY=0"
	env MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1 MTL_HUD_DISABLE_MENU_BAR=1 $extra out/framegen/game 60:6,40:6 --times "$OUT/$variant.game" > "$OUT/$variant.out" 2> "$OUT/$variant.err" &
	g=$!
	sleep 3
	# Which images the HUD brings into the game's process; lsof, as vmmap would suspend the game
	lsof -p $g 2> /dev/null | grep -i -E 'hud|MetalTool' | awk '{ print $NF }' | sort -u > "$OUT/$variant.images"
	wait $g
	sleep 2
	kill $l
	echo "== $variant: $(tail -1 "$OUT/$variant.out"); unified log lines $(grep -c 'metal-HUD' "$OUT/$variant.log"), stderr lines $(grep -c 'metal-HUD' "$OUT/$variant.err")"
	echo "   images: $(tr '\n' ' ' < "$OUT/$variant.images")"
	grep -m1 'metal-HUD' "$OUT/$variant.log" | cut -c1-300
	echo "   from the unified log:"
	python3 -I fps-counter/tests/metalhud_compare.py "$OUT/$variant.log" "$OUT/$variant.game"
	echo "   from stderr:"
	python3 -I fps-counter/tests/metalhud_compare.py "$OUT/$variant.err" "$OUT/$variant.game"
done
