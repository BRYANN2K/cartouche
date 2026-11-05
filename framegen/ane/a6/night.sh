#!/bin/sh
# Cartouche FG 2, unattended: captures and renders the new data, fine-tunes FG 1 on it mixed with the
# old, converts to Core ML, measures latency and quality, writes a report. Built-in screen or none:
# never the external one. Every GPU, window, render and benchmark step takes the shared GPU lock.
# Usage: framegen/ane/a6/night.sh [--smoke]   (from anywhere; CAPTURE_HOURS=3 TRAIN_HOURS=5)
# Sources and licences: framegen/ane/a6/fg2/ATTRIBUTION.md. Everything lands in ~/Downloads/fg-tests/fg2;
# the Godot projects there get our scripts and an override.cfg for the night, removed at the end.
# GPU lock: a lock whose owner is gone is taken after FG2_LOCK_STALE_MIN (30), one without an owner
# after FG2_LOCK_ORPHAN_MIN (120); a step waits at most FG2_LOCK_WAIT_MIN (180), then is skipped.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
fg2=$here/fg2
FG=$HOME/Downloads/fg-tests
SRC=$FG/fg2/src
PY=${FRAMEGEN_PYTHON:-/tmp/fgtool/venv/bin/python}
FG1=${FG1_CHECKPOINT:-$FG/a6/run1/best.pt}
SMOKE=0
[ "${1:-}" = --smoke ] && SMOKE=1
if [ $SMOKE = 1 ]; then
	WORK=$FG/fg2/smoke; CAPTURE_HOURS=${CAPTURE_HOURS:-2}; TRAIN_HOURS=${TRAIN_HOURS:-0.04}
else
	WORK=$FG/fg2/night; CAPTURE_HOURS=${CAPTURE_HOURS:-3}; TRAIN_HOURS=${TRAIN_HOURS:-5}
fi
DS=$WORK/data
RUN=$WORK/run
OUT=$WORK/out
BIN=$WORK/bin
LOG=$WORK/night.log
FLOOR_GB=${FG2_FLOOR_GB:-15}
mkdir -p "$DS" "$RUN" "$OUT" "$BIN" "$WORK/tmp"
export FG2_FLOOR_GB="$FLOOR_GB" FG2_CAP_GB="${FG2_CAP_GB:-9.5}"
# Daytime smoke runs stay in the background (the user works on this Mac); the night run is niced only
[ $SMOKE = 1 ] && LOW="nice -n 15 taskpolicy -b" || LOW="nice -n 10"

say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
free_gb() { df -g "$FG" | awk 'NR == 2 { print $4 }'; }
room() {
	f=$(free_gb)
	[ "$f" -gt "$FLOOR_GB" ] || { say "stop: $f GB free, floor $FLOOR_GB GB"; return 1; }
}
deadline=$(( $(date +%s) + $(echo "$CAPTURE_HOURS * 3600" | bc | cut -d. -f1) ))
time_left() { [ "$(date +%s)" -lt "$deadline" ]; }
GPU_LOCK=/tmp/cartouche-gpu.lock
stale() {
	age=$(( ($(date +%s) - $(stat -f %m "$GPU_LOCK" 2> /dev/null || date +%s)) / 60 ))
	owner=$(cat "$GPU_LOCK/pid" 2> /dev/null)
	if [ -n "$owner" ]; then
		[ "$age" -ge "${FG2_LOCK_STALE_MIN:-30}" ] && ! kill -0 "$owner" 2> /dev/null
	else
		[ "$age" -ge "${FG2_LOCK_ORPHAN_MIN:-120}" ]
	fi
}
lock() {
	until=$(( $(date +%s) + ${FG2_LOCK_WAIT_MIN:-180} * 60 ))
	while ! mkdir "$GPU_LOCK" 2> /dev/null; do
		if stale; then
			say "GPU lock: taken over, $age min old, owner ${owner:-unknown} gone" >&2
			rm -f "$GPU_LOCK/pid"; rmdir "$GPU_LOCK" 2> /dev/null
			continue
		fi
		[ "$(date +%s)" -lt "$until" ] || { say "GPU lock: held by ${owner:-unknown} past the wait limit, step skipped" >&2; return 1; }
		sleep 5
	done
	echo $$ > "$GPU_LOCK/pid"
}
unlock() { rm -f "$GPU_LOCK/pid"; rmdir "$GPU_LOCK" 2> /dev/null; }
locked=0
trap 'unlock_if; pkill -P $$ 2>/dev/null; exit 1' INT TERM
unlock_if() { [ $locked = 1 ] && unlock; locked=0; }
with_lock() { lock || return 1; locked=1; "$@"; rc=$?; unlock; locked=0; return $rc; }
triplets() { $LOW "$PY" -I "$fg2/triplets.py" "$DS" "$@" >> "$LOG" 2>&1; }

caffeinate -ims -w $$ &
say "start: smoke=$SMOKE capture ${CAPTURE_HOURS} h, training ${TRAIN_HOURS} h, $(free_gb) GB free"
"$PY" -c "import torch, coremltools" 2> /dev/null || { say "no torch/coremltools in $PY (FRAMEGEN_PYTHON)"; exit 1; }
[ -f "$FG1" ] || { say "no FG 1 checkpoint at $FG1"; exit 1; }
# Rebuilt only when the source changes: a new ad hoc signature can make macOS ask for access again
[ "$BIN/wincap" -nt "$fg2/wincap.swift" ] || swiftc -O -target arm64-apple-macos15 "$fg2/wincap.swift" -o "$BIN/wincap" 2>> "$LOG" \
	|| { say "wincap does not build"; exit 1; }
screen=$("$BIN/wincap" --screen)
say "built-in screen index: $screen (window captures need it; renders do not)"
access=$("$BIN/wincap" --check) || { say "window captures off: $access"; screen=-1; }

# Window capture of a game on the built-in screen, streamed into triplets.py
# game <source> <seconds> <time scale> <rates> <pairs> <max> <share kept> -- <command...>
game() {
	src=$1 secs=$2 scale=$3 rates=$4 pairs=$5 max=$6 keep=$7
	shift 8
	[ "$screen" -ge 0 ] || { say "$src: no built-in screen, skipped"; return 0; }
	room && time_left || return 1
	lock || return 1; locked=1
	SDL_MAC_BACKGROUND_APP=1 $LOW "$@" > "$WORK/tmp/$src.log" 2>&1 &
	pid=$!
	caffeinate -d -w $pid &
	{ "$BIN/wincap" $pid "$secs" 960 540 60 32 "$keep" 2>> "$LOG"; echo $? > "$WORK/tmp/wincap.rc"; } \
		| FG2_RATES=$rates FG2_PAIRS=$pairs FG2_MAX=$max FG2_SEED=$src$(date +%s) \
		$LOW "$PY" -I "$fg2/triplets.py" "$DS" "$src" raw 960 540 "$scale" >> "$LOG" 2>&1
	kill $pid 2> /dev/null; sleep 2; kill -9 $pid 2> /dev/null
	unlock; locked=0
	# Two captures in a row without frames: the rest of the window captures are skipped
	if [ "$(cat "$WORK/tmp/wincap.rc")" = 0 ]; then failed=0; else
		failed=$((failed + 1)); say "$src: no frames from its window ($failed in a row)"
		[ $failed -lt 2 ] || { say "window captures off for the night"; screen=-1; }
	fi
}
failed=0

# Godot's movie maker on a project with our camera (fg2/godot/fg2_shot.gd), then triplets.py
# godot_shots <source> <project> <scene> <seconds> <max> [extra shot options]
godot_shots() {
	src=$1 proj=$2 scene=$3 secs=$4 max=$5
	shift 5
	[ -d "$proj" ] || { say "$src: no project at $proj, skipped"; return 0; }
	room && time_left || return 1
	cp "$fg2/godot/fg2_shot.gd" "$fg2/godot/fg2_forest.gd" "$proj/"
	echo "$proj" >> "$WORK/tmp/godot-projects"
	printf '[display]\n\nwindow/size/viewport_width=960\nwindow/size/viewport_height=540\n\n[editor]\n\nmovie_writer/mjpeg_quality=1.0\n' > "$proj/override.cfg"
	# shellcheck disable=SC2086 # LOW is the nice/taskpolicy prefix, split on purpose
	[ -d "$proj/.godot/imported" ] || with_lock $LOW godot --headless --path "$proj" --import >> "$LOG" 2>&1
	clip=$WORK/tmp/$src.avi
	frames=$(( secs * 240 ))
	# shellcheck disable=SC2086 # LOW is the nice/taskpolicy prefix, split on purpose
	with_lock $LOW perl -e 'alarm shift; exec @ARGV' $(( secs * 2 + 600 )) godot --path "$proj" --screen "$screen" \
		--resolution 960x540 --audio-driver Dummy --disable-vsync --script res://fg2_shot.gd --write-movie "$clip" \
		--fixed-fps 240 --quit-after $frames -- scene="$scene" seed="$(date +%s)" "$@" >> "$WORK/tmp/$src.godot.log" 2>&1
	grep -a "frames at 240 FPS" "$WORK/tmp/$src.godot.log" | tail -1 | sed "s/^/$src: /" >> "$LOG"
	[ -s "$clip" ] && FG2_RATES=120,60,30 FG2_MAX=$max triplets "$src" video "$clip" 240
	rm -f "$clip"
}

# Blender EEVEE clip (fg2/blender/render.py), frames deleted once converted
# blender_clip <source> <file.blend> <frames> <max>
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
blender_clip() {
	src=$1 file=$2 n=$3 max=$4
	[ -f "$file" ] || { say "$src: no $file, skipped"; return 0; }
	room && time_left || return 1
	dir=$WORK/tmp/$src.frames
	rm -rf "$dir"
	# shellcheck disable=SC2086 # LOW is the nice/taskpolicy prefix, split on purpose
	with_lock $LOW perl -e 'alarm shift; exec @ARGV' $(( n * 30 + 300 )) "$BLENDER" -b "$file" --python-exit-code 1 \
		-P "$fg2/blender/render.py" -- "$dir" 240 "$n" "$(date +%s)" >> "$WORK/tmp/$src.blender.log" 2>&1
	grep "fg2: rendered" "$WORK/tmp/$src.blender.log" | tail -1 | sed "s/^/$src: /" >> "$LOG"
	# shellcheck disable=SC2012 # f%04d.png names are written here, ls order is exact
	ls "$dir"/f*.png > /dev/null 2>&1 && FG2_RATES=120,60,30 FG2_MAX=$max FG2_EVERY=2 \
		triplets "$src" video "$dir/f%04d.png" 240 -start_number "$(ls "$dir" | head -1 | tr -dc 0-9 | sed 's/^0*//;s/^$/0/')"
	rm -rf "$dir"
}

fetch() { # fetch <url> <file>: each download in its own directory
	[ -s "$2" ] && return 0
	room || return 1
	mkdir -p "$(dirname "$2")"
	curl -sSfL --retry 3 -o "$2.part" "$1" 2>> "$LOG" && mv "$2.part" "$2" && return 0
	rm -f "$2.part"; say "download failed, skipped: $1"; return 1
}

N=https://s3.amazonaws.com/download.opencontent.netflix.com/Nocturne/nocturne_120fps/s01e04/vdm/hdr/p3d65_pq/20180307_02/3840x2160/nocturne_120fps_s01e04_vdm_hdr_p3d65_pq_20180307_02_3840x2160_dovi_4000nit
nd=$WORK/tmp/nocturne
nocturne() {
	for first in $([ $SMOKE = 1 ] && echo 3000 || echo 2000 3000 4000 5000); do
		mkdir -p "$nd/b$first"
		for i in $(seq "$first" $((first + (SMOKE == 1 ? 4 : 23)))); do
			room || return
			n=$(printf %07d "$i")
			curl -sfL --retry 3 -o "$nd/f.exr" "${N}_$n.exr" && "$PY" -I "$fg2/pq_png.py" "$nd/f.exr" "$nd/b$first/f$n.png"
			rm -f "$nd/f.exr"
		done
	done
}
# In the day (smoke), one download at a time: it runs later, alone
nocturne_pid=
[ $SMOKE = 0 ] && { nocturne >> "$LOG" 2>&1 & nocturne_pid=$!; }

# 1. Games, through their windows on the built-in screen (kept awake by caffeinate -d during each)
# SuperTuxKart, 0 A.D. and Wesnoth have share-alike (CC BY-SA, GPL) art: off unless FG2_SHAREALIKE=1,
# which needs an ADR first (ATTRIBUTION.md)
FD=$SRC/freedoom/freedoom-0.13.0
if [ $SMOKE = 1 ]; then
	game woof 10 0.25 120,60,30 0 150 1 -- woof -iwad "$FD/freedoom2.wad" -config "$WORK/tmp/woof.cfg" -window -nosound \
		-nomusic -uncapped -speed 25 -playdemo demo1
	[ "${FG2_SHAREALIKE:-0}" = 1 ] && game stk 10 1 30 0.3 40 0.5 -- /Applications/SuperTuxKart.app/Contents/MacOS/supertuxkart -R \
		--aiNP=tux,gnu,nolok,pidgin --track=lighthouse --laps=3 --profile-time=60 --windowed --screensize=1280x720
else
	for wad in freedoom1 freedoom2; do for demo in demo1 demo2 demo3 demo4; do
		game woof 150 0.25 120,60,30 0 250 1 -- woof -iwad "$FD/$wad.wad" -config "$WORK/tmp/woof.cfg" -window -nosound \
			-nomusic -uncapped -speed 25 -playdemo $demo
	done; done
fi
if [ $SMOKE = 0 ] && [ "${FG2_SHAREALIKE:-0}" = 1 ]; then
	for track in lighthouse zengarden hacienda cocoa_temple snowmountain black_forest cornfield_crossing ravenbridge_mansion; do
		game stk 75 1 30 0.3 300 0.5 -- /Applications/SuperTuxKart.app/Contents/MacOS/supertuxkart -R \
			--aiNP=tux,gnu,nolok,pidgin,puffy,kiki,sara_the_racer,konqi --track=$track --laps=3 --profile-time=120 \
			--windowed --screensize=1280x720
	done
	if [ -f "$SRC/0ad/0ad.dmg" ] && hdiutil attach -nobrowse -readonly -noverify -mountpoint "$WORK/tmp/0ad" "$SRC/0ad/0ad.dmg" > /dev/null; then
		for map in acropolis_bay_2p alpine_valleys_2p arabian_oases_2p bactria_2p; do
			game 0ad 150 0.25 60,30 0 300 1 -- "$WORK/tmp/0ad/0 A.D..app/Contents/MacOS/pyrogenesis" \
				-autostart="skirmishes/$map" -autostart-ai=1:petra -autostart-ai=2:petra -autostart-player=-1 \
				-autostart-visibility=revealed -autostart-speed=0.25 -conf=windowed:true -xres=1280 -yres=720 -nosound
		done
		hdiutil detach "$WORK/tmp/0ad" > /dev/null
	fi
	if [ -f "$SRC/wesnoth/wesnoth.dmg" ] && hdiutil attach -nobrowse -readonly -noverify -mountpoint "$WORK/tmp/wesnoth" "$SRC/wesnoth/wesnoth.dmg" > /dev/null; then
		for i in 1 2 3; do
			game wesnoth 120 1 30 0.3 200 1 -- "$WORK/tmp/wesnoth/The Battle for Wesnoth.app/Contents/MacOS/The Battle for Wesnoth" \
				--multiplayer --controller 1:ai --controller 2:ai --exit-at-end --nosound --windowed --resolution 1280x720
		done
		hdiutil detach "$WORK/tmp/wesnoth" > /dev/null
	fi
fi

# OpenTTD stays out of training: its title game (vehicles, a slowly moving view, the menu on top)
# becomes a test set, frames i, i+3, i+6
if [ "$screen" -ge 0 ] && [ ! -s "$WORK/openttd.npy" ] && [ -d "$SRC/openttd/baseset" ] && lock; then
	locked=1
	(cd "$SRC/openttd" && SDL_MAC_BACKGROUND_APP=1 exec $LOW /Applications/OpenTTD.app/Contents/MacOS/openttd -x \
		-r 1280x720 -s null -m null > "$WORK/tmp/openttd.log" 2>&1) &
	pid=$!
	caffeinate -d -w $pid &
	"$BIN/wincap" "$pid" "$([ $SMOKE = 1 ] && echo 10 || echo 60)" 960 540 2>> "$LOG" \
		| "$PY" -I "$fg2/heldout.py" "$WORK/openttd.npy" 960 540 "$([ $SMOKE = 1 ] && echo 10 || echo 60)" 3 >> "$LOG" 2>&1
	kill "$pid" 2> /dev/null; sleep 2; kill -9 "$pid" 2> /dev/null
	unlock; locked=0
fi

# 2. Godot scenes, offscreen in practice: the movie maker does not need the window to be seen
G=$SRC/godot-demos/godot-demo-projects-master/3d
mkdir -p "$SRC/forest/project"
[ -f "$SRC/forest/project/project.godot" ] || printf 'config_version=5\n\n[application]\n\nconfig/name="fg2 forest"\nconfig/features=PackedStringArray("4.7", "Forward Plus")\n' > "$SRC/forest/project/project.godot"
[ -d "$SRC/forest/assets/models" ] || "$PY" -I "$fg2/godot/fetch_polyhaven.py" "$SRC/forest/assets" >> "$LOG" 2>&1
if [ $SMOKE = 1 ]; then
	godot_shots platformer "$G/platformer" res://game.tscn 2 150 shot=1
else
	round=0
	while time_left && [ $round -lt 4 ]; do
		round=$((round + 1))
		godot_shots bistro "$SRC/bistro/Bistro-Demo-Tweaked-main" res://MainScene.tscn 20 900 shot=4 || break
		godot_shots forest "$SRC/forest/project" forest 20 700 shot=4 assets="$SRC/forest/assets" || break
		godot_shots tps "$SRC/tps/tps-demo-master" res://level/level.tscn 20 700 shot=4 || break
		godot_shots truck_town "$G/truck_town" res://town/town_scene.tscn 15 400 shot=5 speed=12 || break
		godot_shots platformer "$G/platformer" res://game.tscn 10 250 shot=3 || break
		godot_shots volumetric_fog "$G/volumetric_fog" res://volumetric_fog.tscn 10 250 shot=3 || break
	done
fi

# 3. Blender EEVEE, short clips with a camera move; .blend files downloaded once, kept for the night
B=$SRC/blender
[ -f "$B/classroom/classroom/classroom.blend" ] || { fetch https://download.blender.org/demo/test/classroom.zip \
	"$B/classroom/classroom.zip" && unzip -q -o "$B/classroom/classroom.zip" -d "$B/classroom" && rm "$B/classroom/classroom.zip"; }
classroom=$(find "$B/classroom" -name classroom.blend 2> /dev/null | head -1)
if [ $SMOKE = 1 ]; then
	blender_clip classroom "$classroom" 12 20
else
	fetch https://download.blender.org/demo/cycles/flat-archiviz.blend "$B/flat/flat-archiviz.blend"
	fetch https://svn.blender.org/svnroot/bf-blender/trunk/lib/benchmarks/cycles/barbershop_interior/barbershop_interior.blend "$B/barbershop/barbershop_interior.blend"
	# The Cosmos Laundromat demo ships as benchmark/benchmark.blend
	[ -f "$B/cosmos/benchmark/benchmark.blend" ] || { fetch https://download.blender.org/demo/test/benchmark.zip \
		"$B/cosmos/benchmark.zip" && unzip -q -o "$B/cosmos/benchmark.zip" -d "$B/cosmos" && rm "$B/cosmos/benchmark.zip"; }
	cosmos=$B/cosmos/benchmark/benchmark.blend
	for i in 1 2 3; do
		time_left || break
		blender_clip classroom "$classroom" 240 220 || break
		blender_clip flat "$B/flat/flat-archiviz.blend" 240 220 || break
		blender_clip barbershop "$B/barbershop/barbershop_interior.blend" 240 220 || break
		blender_clip cosmos "$cosmos" 240 220 || break
	done
fi

# 4. Netflix Nocturne, shot at 120 fps (CC BY 4.0), fetched in the background since the start: 4K
# EXR frames one at a time, each turned into a 1280x720 PNG and deleted
[ -n "$nocturne_pid" ] && wait $nocturne_pid 2> /dev/null
[ $SMOKE = 1 ] && nocturne >> "$LOG" 2>&1
for burst in "$nd"/b*; do
	# shellcheck disable=SC2012 # f%07d.png names are written here, ls order is exact
	[ -d "$burst" ] && FG2_RATES=60,30 FG2_MAX=$([ $SMOKE = 1 ] && echo 2 || echo 60) FG2_EVERY=1 \
		triplets nocturne video "$burst/f%07d.png" 120 -start_number "$(ls "$burst" | head -1 | tr -dc 0-9 | sed 's/^0*//;s/^$/0/')"
done
rm -rf "$nd"
sort -u "$WORK/tmp/godot-projects" 2> /dev/null | while read -r p; do rm -f "$p/fg2_shot.gd" "$p/fg2_forest.gd" "$p/override.cfg"; done
rm -f "$WORK/tmp/godot-projects"
say "dataset: $(du -sh "$DS" | cut -f1), $(find "$DS" -name '*.zip' | wc -l | tr -d ' ') shards, $(free_gb) GB free"

# 5. Fine-tune FG 1 into FG 2, in segments of 30 min (a checkpoint each) so the GPU lock changes hands
cd "$here" || exit 1
while :; do
	# shellcheck disable=SC2086,SC2046 # LOW is the nice prefix and --smoke vanishes when off, both on purpose
	with_lock $LOW "$PY" train.py "$RUN" "$TRAIN_HOURS" --init "$FG1" --fg2 "$DS" --segment $([ $SMOKE = 1 ] && echo --smoke) > "$WORK/tmp/train.out" 2>&1
	tail -1 "$RUN/train.log" | grep -q "^done" && break
	grep -q "segment ends" "$WORK/tmp/train.out" || { say "training failed: $(tail -3 "$WORK/tmp/train.out")"; break; }
done
say "training: $(grep -E '^(start val|new best|done)' "$RUN/train.log" | tail -3 | tr '\n' ' ')"

# 6. Core ML, placement, latency
# best.pt exists only if FG 2 beat FG 1 on the validation sets; otherwise the last checkpoint is
# converted so that the report still compares them
best=$RUN/best.pt
if [ ! -f "$best" ]; then
	# shellcheck disable=SC2012 # step*.pt names are written by the trainer, ls order is exact
	best=$(ls "$RUN"/step*.pt 2> /dev/null | tail -1)
	say "FG 2 never beat FG 1 on validation: converting $best for the comparison"
	[ -n "$best" ] || exit 1
fi
"$PY" convert.py "$best" "$OUT/flow-fg2.mlpackage" >> "$LOG" 2>&1
xcrun coremlcompiler compile "$OUT/flow-fg2.mlpackage" "$OUT" > /dev/null && rm -rf "$OUT/framegen-flow-fg2.mlmodelc" \
	&& mv "$OUT/flow-fg2.mlmodelc" "$OUT/framegen-flow-fg2.mlmodelc"
[ -d "$OUT/flow-fg1.mlpackage" ] || "$PY" convert.py "$FG1" "$OUT/flow-fg1.mlpackage" >> "$LOG" 2>&1
[ -d "$OUT/flow-fg1.mlmodelc" ] || xcrun coremlcompiler compile "$OUT/flow-fg1.mlpackage" "$OUT" > /dev/null
plan=$("$PY" plan.py "$OUT/framegen-flow-fg2.mlmodelc" 2>/dev/null | head -1)
clang -arch arm64 -O2 -fobjc-arc -framework Foundation -framework CoreML anelat.m -o "$BIN/anelat"
lat2=$(with_lock "$BIN/anelat" "$OUT/framegen-flow-fg2.mlmodelc" | grep CPU+ANE)
lat1=$(with_lock "$BIN/anelat" "$OUT/flow-fg1.mlmodelc" | grep CPU+ANE)

# 7. Quality: synthesis alone on Sintel (never trained on), the OpenTTD test set and FG 2's own
# validation clips, then tune's 3D scene through eval.sh if tune is built
rife=$FG/a6/eval/rife_lean.mlpackage
sets=$FG/a6/sintel/sintel.npy
[ -s "$WORK/openttd.npy" ] && sets=$sets,$WORK/openttd.npy
models="FG2=$OUT/flow-fg2.mlpackage FG1=$OUT/flow-fg1.mlpackage"
[ -d "$rife" ] && models="$models RIFE=$rife"
[ $SMOKE = 1 ] && "$PY" -c "import numpy as np; a=np.load('$FG/a6/sintel/sintel.npy'); np.save('$WORK/sintel8.npy', a[:8])" && sets=$WORK/sintel8.npy$([ -s "$WORK/openttd.npy" ] && echo ",$WORK/openttd.npy")
# shellcheck disable=SC2086 # models is a space-separated name=path list, split on purpose
scores=$(with_lock "$PY" "$fg2/score_set.py" "$sets" $models 2>> "$LOG")
tune=""
if [ -x "$repo/out/framegen/tune" ] && [ -d "$FG/a6/eval/pairs" ] && [ $SMOKE = 0 ]; then
	tune=$(cd "$repo" && with_lock env FRAMEGEN_PYTHON="$PY" sh framegen/ane/a6/eval.sh "$OUT/flow-fg2.mlpackage" "$FG/a6/eval/pairs" 2>&1)
fi

# 8. Report
{
	echo "# Cartouche FG 2: night report ($(date '+%Y-%m-%d %H:%M'))"
	echo
	[ $SMOKE = 1 ] && echo "Smoke run: tiny captures and a few minutes of training. The numbers only prove the chain." && echo
	echo "## Dataset ($DS)"
	echo
	echo "| Source | Shards | Samples | Size |"
	echo "|---|---:|---:|---:|"
	for d in "$DS"/*/; do
		s=$(basename "$d")
		n=$(for z in "$d"*.zip; do unzip -Z1 "$z"; done 2> /dev/null | wc -l | tr -d ' ')
		# shellcheck disable=SC2012 # shard names are written here, a zip glob can't surprise
		echo "| $s | $(ls "$d"*.zip 2> /dev/null | wc -l | tr -d ' ') | $n | $(du -sh "$d" | cut -f1) |"
	done
	echo
	echo "Free disk at the end: $(free_gb) GB."
	echo
	echo "## Training ($RUN/train.log)"
	echo
	grep -E "^(start val|fg2 samples)" "$RUN/train.log" | head -2 | sed 's/^start val/FG 1, before training: val/; s/^/- /'
	grep -E "^(val step|new best|done)" "$RUN/train.log" | tail -8 | sed 's/^/- /'
	echo
	echo "## Core ML and latency"
	echo
	echo "- FG 2: $OUT/framegen-flow-fg2.mlmodelc. Placement: $plan"
	echo "- FG 2, CPU+ANE: $lat2"
	echo "- FG 1, CPU+ANE: $lat1"
	echo
	echo "## Quality (synthesis alone, 512x256)"
	echo
	echo "$scores"
	echo
	[ -n "$tune" ] && echo "### tune's 3D scene (eval.sh)" && echo && echo '```' && echo "$tune" && echo '```'
	echo
	echo "To try it: CARTOUCHE_FRAMEGEN_ANE=fg1 CARTOUCHE_FRAMEGEN_ANE_MODEL=$OUT/framegen-flow-fg2.mlmodelc"
} > "$WORK/report.md"
say "report: $WORK/report.md"
