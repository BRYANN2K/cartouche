#!/bin/sh
# extfps on the D3D11 stand-in game in Cartouche's Wine, on DXMT and D3DMetal, nothing injected.
# The scene's own count is what it rendered; with hud, Apple's Metal HUD log in the scene's stderr
# is the reference for what it presented. Run from the repo root; takes the GPU lock.
#   sh fps-counter/tests/extfps_wine.sh <scene.exe> [hud] [out dir]
set -u
SCENE=$1 HUD=${2:-} OUT=${3:-/tmp/extfps-wine}
mkdir -p "$OUT"
while ! mkdir /tmp/cartouche-gpu.lock 2> /dev/null; do sleep 3; done
echo $$ > /tmp/cartouche-gpu.lock/pid
trap 'rm -f /tmp/cartouche-gpu.lock/pid; rmdir /tmp/cartouche-gpu.lock 2> /dev/null' EXIT INT TERM
caffeinate -d -w $$ &
TITLE="Frame Gen D3D11 Scene"
for c in "dxmt 30" "dxmt 60" "d3dmetal 60" "dxmt 120"; do
	# shellcheck disable=SC2086 # the "backend seconds" pair is split on purpose
	set -- $c
	name=$1-$2
	if [ "$HUD" = hud ]; then
		MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1 MTL_HUD_DISABLE_MENU_BAR=1 \
			sh framegen/tests/d3d11/run.sh "$SCENE" /dev/null "$1" off "$2" 16 > "$OUT/$name.out" 2>&1 &
	else
		sh framegen/tests/d3d11/run.sh "$SCENE" /dev/null "$1" off "$2" 16 > "$OUT/$name.out" 2>&1 &
	fi
	r=$!
	for _ in $(seq 1 30); do out/extfps --title "$TITLE" --seconds 0.1 --quiet > /dev/null 2>&1 && break; sleep 0.5; done
	out/extfps --title "$TITLE" --seconds 8 > "$OUT/$name.extfps" 2>&1
	wait $r
	echo "== $name: scene $(grep -m1 rendered "$OUT/$name.out") in 16 s"
	grep '^summary' "$OUT/$name.extfps"
	[ "$HUD" = hud ] && python3 -I fps-counter/tests/metalhud_compare.py "$OUT/$name.out" /dev/null
done
