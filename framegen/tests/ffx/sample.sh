#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail, so A && ok || bad is safe
# AMD's FSR sample (D3D12) in Cartouche's Wine on D3DMetal, with the FFX proxy as a Wine builtin
# found through WINEDLLPATH. 3.1: the sample runs the same without and with the proxy, the proxy
# logs the five calls, and the sample's folder is the same before and after. 3.2: with
# CARTOUCHE_FFX_COPY=2, depth, motion and the upscaled frame reach the library each frame, on a
# copy of the scene that pans (moving_sponza.py); then score.m rates our frame generation on those
# frames, with our motion and with the game's.
# The library runs in every run, generation off but for the copy run, to count frames per second.
# The sample's -benchmark mode is not used: under D3DMetal it slows down a little more each frame.
# Every run holds the shared GPU lock. Windows stay on the Mac's own screen, without focus.
# fg: the game's frame generation turned on (forced, as the sample only has a button for it), and
# the library standing down; the proxy between AMD's swapchain and the game's present callback.
# ui: the game's frame without and with its UI, from its present callback, dumped with the
# vectors, then scored: final frames alone against the frame without UI plus the final one as
# MetalFX's composited UI (3.3).
# FFX_STAGES picks among "ab copy score fg ui" (all by default).
# Usage: sample.sh <sample folder> <framegen.dylib> <proxy folder> <quiet.dylib> [seconds]
set -u
sample="$1"; lib="$2"; proxy="$3"; quiet="$4"; seconds="${5:-${FFX_SECONDS:-25}}"
here=$(dirname "$0")
score="$(dirname "$quiet")/ffx-score"
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
info() { printf '  info  %s\n' "$1"; }
# CARTOUCHE_GPU_LOCK_HELD=1: a caller already holds the lock, taking it again would wait forever
gpu_take() { [ "${CARTOUCHE_GPU_LOCK_HELD:-0}" = 1 ] || while ! mkdir /tmp/cartouche-gpu.lock 2>/dev/null; do sleep 5; done; }
gpu_free() { [ "${CARTOUCHE_GPU_LOCK_HELD:-0}" = 1 ] || rmdir /tmp/cartouche-gpu.lock; }
support="$HOME/Library/Application Support/Cartouche"
root="$support/runners/.graphics/${FRAMEGEN_WINE:-wine-crossover-26.3.0-2}/d3dmetal"
[ -f "$root/.cartouche-graphics.json" ] || { echo "  skip  Cartouche has no d3dmetal Wine on this Mac"; exit 0; }
[ -f "$sample/FidelityFX_FSR.exe" ] || { echo "  skip  no FSR sample at $sample"; exit 0; }
work="${FFX_WORK:-$(mktemp -d "$HOME/Library/Caches/cartouche-ffx.XXXXXX")}"
mkdir -p "$work"
[ -n "${FFX_WORK:-}" ] || trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
[ -d "$prefix" ] || cp -cR "$support/prefix-template" "$prefix" 2>/dev/null || cp -R "$support/prefix-template" "$prefix"
for dir in "$support"/runners/gptk-*/lib; do
  [ ! -f "$dir/external/libd3dshared.dylib" ] || d3dshared="$dir/external/libd3dshared.dylib"
done
wine="$root/lib/wine/x86_64-unix/wine"
[ -x "$wine" ] || wine="$root/bin/wine"
windows() { echo "Z:$1" | tr / "\\"; }

# Everything in the sample's folder but what the sample writes there itself
fingerprint() {
  (cd "$sample" && find . -type f ! -name Cauldron.log ! -name imgui.ini ! -name '*-perf*' | LC_ALL=C sort \
    | while read -r f; do shasum -a 256 "$f"; done) | shasum -a 256 | cut -c1-16
}

# run <name> <insert> "<VAR=value ...>" [sample arguments...]: the sample for $seconds seconds,
# with the library counting frames, output in $work/<name>.*
run() {
  name="$1"; insert="$2"; vars="$3"; shift 3
  mkdir -p "$work/$name"
  gpu_take
  started=$(date +%T)
  # shellcheck disable=SC2086 # vars is a list of assignments
  (cd "$sample" && env CX_ROOT="$root" CX_GRAPHICS_BACKEND=d3dmetal WINEPREFIX="$prefix" WINEDEBUG=-all \
    WINESERVER="$root/bin/wineserver" CX_APPLEGPTK_LIBD3DSHARED_PATH="${d3dshared:-}" DYLD_INSERT_LIBRARIES="$insert" \
    CARTOUCHE_FRAMEGEN=1 CARTOUCHE_FRAMEGEN_FRONT=1 CARTOUCHE_FRAMEGEN_STATS=1 CARTOUCHE_FRAMEGEN_DIR="$work/$name" $vars \
    "$wine" FidelityFX_FSR.exe "$@" > "$work/$name.out" 2> "$work/$name.log") &
  pid=$!
  waited=0
  while kill -0 "$pid" 2> /dev/null && [ "$waited" -lt "$seconds" ]; do sleep 1; waited=$((waited + 1)); done
  WINEPREFIX="$prefix" "$root/bin/wineserver" -k 2> /dev/null
  wait "$pid" 2> /dev/null
  gpu_free
  cp "$sample/Cauldron.log" "$work/$name.cauldron.log" 2> /dev/null
  info "$name: $started-$(date +%T), ${waited} s"
}
# Frames per second the game rendered, median of the whole seconds after the first three
# shellcheck disable=SC2012 # newest csv by name: the run writes them itself, ls -t is exact
fps() { f=$(ls -t "$work/$1"/*.csv 2> /dev/null | head -1); [ -n "$f" ] && sed -n '5,$p' "$f" | cut -d, -f2 | median; }
# The sample's own lines about FSR, without times
fsr_lines() { grep -E "Upscaler|Swapchain Query|FrameGeneration" "$work/$1.cauldron.log" | sed 's/^\[[0-9:]*\]//' | LC_ALL=C sort -u; }

median() { LC_ALL=C sort -n | awk '{ v[NR] = $1 } END { print NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }
proxied="WINEDLLPATH=$proxy WINEDLLOVERRIDES=amd_fidelityfx_loader_dx12=b"
off="CARTOUCHE_FRAMEGEN_TUNE=enabled=0"
ran() { grep -q "Content loading took" "$work/$1.cauldron.log" && [ -n "$(fps "$1")" ]; }

stages=" ${FFX_STAGES:-ab copy score fg ui} "
stage() { case "$stages" in *" $1 "*) return 0 ;; esac; return 1; }
before=$(fingerprint)
if stage ab; then
echo "== AMD's DLL alone, then through the proxy, ${FFX_ROUNDS:-2} times each =="
: > "$work/fps"
round=1
while [ "$round" -le "${FFX_ROUNDS:-2}" ]; do
  run "plain$round" "$quiet:$lib" "$off"
  run "proxy$round" "$quiet:$lib" "$off $proxied"
  echo "plain $(fps "plain$round")" >> "$work/fps"
  echo "proxy $(fps "proxy$round")" >> "$work/fps"
  round=$((round + 1))
done
for f in plain proxy; do ln -sfn "${f}1" "$work/$f"; cp "$work/${f}1.log" "$work/$f.log"; cp "$work/${f}1.cauldron.log" "$work/$f.cauldron.log"; done
ran plain && ok "the sample ran alone" || bad "plain run" "content loaded, frames counted" "$(tail -2 "$work/plain.log" | tr '\n' ' ')"
ran proxy && ok "the sample ran through the proxy" || bad "proxy run" "content loaded, frames counted" "$(tail -2 "$work/proxy.log" | tr '\n' ' ')"
grep -q "ffx proxy loaded amd_fidelityfx_loader_dx12.dll" "$work/proxy.log" && ok "Wine loaded the builtin, which loaded AMD's" \
  || bad "proxy loaded" "ffx proxy loaded" "$(grep -m2 ffx "$work/proxy.log" | tr '\n' ' ')"
for call in create configure query dispatch destroy; do
  grep -q "ffx $call " "$work/proxy.log" && ok "$call logged" || bad "$call logged" "ffx $call" "none"
done
grep -q "ffx dispatch .* upscale #1 " "$work/proxy.log" && ok "upscale dispatches logged with their inputs" \
  || bad "upscale dispatch" "upscale #1" "$(grep -m1 'ffx dispatch' "$work/proxy.log")"
[ "$(fsr_lines plain)" = "$(fsr_lines proxy)" ] && ok "the sample says the same about FSR (versions, sizes, memory)" \
  || bad "same FSR lines" "$(fsr_lines plain | head -3 | tr '\n' ' ')" "$(fsr_lines proxy | head -3 | tr '\n' ' ')"
plain_fps=$(sed -n 's/^plain //p' "$work/fps" | median); proxy_fps=$(sed -n 's/^proxy //p' "$work/fps" | median)
info "fps per run: $(tr '\n' ' ' < "$work/fps")"
awk -v a="$plain_fps" -v b="$proxy_fps" 'BEGIN { exit !(b >= 0.9 * a) }' && ok "same speed: median $proxy_fps fps through the proxy, $plain_fps alone" \
  || bad "same speed" ">= 90 % of $plain_fps fps" "$proxy_fps fps"

fi
python3 -I "$here/moving_sponza.py" "$sample/../../../../../../media/cauldronmedia/SponzaNew/MainSponza.gltf" "$work/scene" \
  "${FFX_PAN:-6}" "${FFX_PERIOD:-6}" > /dev/null
scene="-resolution 960 540 -loadcontent $(windows "$work/scene/MovingSponza.gltf") -camera PhysCamera003"
if stage copy; then
echo "== copies of depth and motion into the library, on a panning scene =="
# shellcheck disable=SC2086 # scene is a list of arguments
run copy "$quiet:$lib" "$proxied CARTOUCHE_FFX_COPY=1 CARTOUCHE_FFX_FG=ours CARTOUCHE_FRAMEGEN_TUNE=limit=auto \
CARTOUCHE_FRAMEGEN_FFX_WAIT=${FFX_WAIT:-0}" $scene
grep -q "framegen: ffx copies on" "$work/copy.log" && ok "the proxy records copies in the game's lists" \
  || bad "copies on" "ffx copies on" "$(grep -m3 'ffx copies\|ffx proxy' "$work/copy.log" | tr '\n' ' ')"
grep -q "framegen: ffx engine data motion=" "$work/copy.log" && ok "depth and motion reach the library" \
  || bad "engine data" "ffx engine data" "$(grep -m2 'framegen: ffx' "$work/copy.log" | tail -1)"
grep -q "framegen: engine motion in use" "$work/copy.log" && ok "the interpolator takes the game's motion" \
  || bad "engine motion" "engine motion in use" "$(grep -m1 'framegen: active\|framegen: disabled\|framegen: paused' "$work/copy.log")"
info "$(grep -m1 'framegen: ffx engine data' "$work/copy.log" | cut -c11-)"
grep "framegen: ffx copy stats\|framegen: ffx library\|framegen: ffx match" "$work/copy.log" | tail -3 | while read -r line; do info "$(echo "$line" | cut -c11-)"; done
match=$(grep "framegen: ffx match" "$work/copy.log" | tail -1)
[ -n "$match" ] && ok "each real frame takes its own vectors, or the newest ones when its own are late" || bad "match stats" "ffx match ..." "none"
info "copy run: $(fps copy) fps; the same scene without the proxy's copies follows"
# shellcheck disable=SC2086
run nocopy "$quiet:$lib" "$proxied" $scene
info "no copy: $(fps nocopy) fps"
fi

if stage score; then
column() { grep '^mean' "$1" | awk -v c="$2" '{ print $c }'; }
# score <name> <pan> <period> <yaw> <depth>: the upscaled frames of a scene dumped, then scored
score_scene() {
  scene_name="$1"; shift
  echo "== our frame generation on the sample's frames at half its rate: $scene_name scene ($*) =="
  python3 -I "$here/moving_sponza.py" "$sample/../../../../../../media/cauldronmedia/SponzaNew/MainSponza.gltf" \
    "$work/scene-$scene_name" "$@" > /dev/null
  mkdir -p "$work/dump-$scene_name"
  # shellcheck disable=SC2046 # the scene's arguments
  run "dump-$scene_name" "$quiet:$lib" "$proxied CARTOUCHE_FFX_COPY=2 CARTOUCHE_FRAMEGEN_FFX_DUMP=$work/dump-$scene_name \
CARTOUCHE_FRAMEGEN_FFX_DUMP_FROM=${FFX_DUMP_FROM:-300} CARTOUCHE_FRAMEGEN_FFX_DUMP_COUNT=${FFX_DUMP_COUNT:-41}" \
    -resolution 960 540 -loadcontent "$(windows "$work/scene-$scene_name/MovingSponza.gltf")" -camera PhysCamera003
  gpu_take
  nice -n 15 "$score" "$work/dump-$scene_name" > "$work/score-$scene_name.txt" 2>&1
  SCORE_MOTION_SCALE=-1 nice -n 15 "$score" "$work/dump-$scene_name" > "$work/flipped-$scene_name.txt" 2>&1
  gpu_free
  sed 's/^/        /' "$work/score-$scene_name.txt"
  estimate=$(column "$work/score-$scene_name.txt" 3); game=$(column "$work/score-$scene_name.txt" 4); flipped=$(column "$work/flipped-$scene_name.txt" 4)
  if [ -n "$game" ] && [ -n "$flipped" ]; then
    awk -v g="$game" -v f="$flipped" 'BEGIN { exit !(f > g + 1) }' && ok "$scene_name: the vectors are read the right way: $game % wrong, $flipped % turned around" \
      || bad "$scene_name: vectors used" "turned around worse than $game % by over 1 point" "$flipped %"
    info "$scene_name: the game's vectors $game %, one frame late $(column "$work/score-$scene_name.txt" 5) %, our estimate $estimate %"
  else
    bad "$scene_name: score" "a mean line" "$(tail -1 "$work/score-$scene_name.txt")"
  fi
  [ -n "${FFX_WORK:-}" ] || rm -rf "$work/dump-$scene_name"
}
score_scene pan "${FFX_PAN:-6}" "${FFX_PERIOD:-6}" 0 0
score_scene hard 3 4 8 2
fi

if stage fg; then
echo "== the game's frame generation =="
# shellcheck disable=SC2086
run ui "$quiet:$lib" "$proxied CARTOUCHE_FFX_UI=1 CARTOUCHE_FFX_FG=ours CARTOUCHE_FRAMEGEN_TUNE=limit=auto" $scene
calls=$(grep -c "ffx present callback" "$work/ui.log")
grep -q "ffx game frame generation on, AMD's off (ours instead)" "$work/ui.log" && ok "the game asks for frame generation; AMD's is kept off, ours runs" \
  || bad "ours instead" "AMD's off (ours instead)" "$(grep 'ffx game frame generation' "$work/ui.log" | tail -1)"
grep -q "standing down" "$work/ui.log" && bad "ours runs" "no standing down" "standing down" || ok "the library's own does not stand down"
info "AMD's kept off, its swapchain calls the game's present callback: $(grep -m1 'ffx present callback' "$work/ui.log" | cut -c11- || echo never)"
info "ui run: $(fps ui) fps, $calls callback lines"
# shellcheck disable=SC2086
run forced "$quiet:$lib" "$proxied CARTOUCHE_FFX_UI=1 CARTOUCHE_FFX_FG=force CARTOUCHE_FRAMEGEN_TUNE=limit=auto" $scene
grep -q "ffx game frame generation .*, AMD's on" "$work/forced.log" && ok "the proxy sees the game's frame generation on" \
  || bad "game generation" "ffx game frame generation ..., AMD's on" "$(grep -m1 'ffx game frame generation' "$work/forced.log")"
grep -q "framegen: standing down: the game generates frames" "$work/forced.log" && ok "the library's own stands down" \
  || bad "standing down" "standing down" "$(grep -m1 'framegen: active\|framegen: paused' "$work/forced.log")"
ran forced && ok "the sample runs with AMD's frame generation on D3DMetal: $(fps forced) fps counted" \
  || bad "forced run" "frames counted" "$(tail -2 "$work/forced.log" | tr '\n' ' ')"
info "$(grep -m1 'ffx present callback.*generated=1' "$work/forced.log" | cut -c11- || echo 'no generated frame seen in the callback')"
fi

if stage ui; then
echo "== the UI kept apart: frames without and with it, scored =="
mkdir -p "$work/dump-ui"
# shellcheck disable=SC2086
run uidump "$quiet:$lib" "$proxied CARTOUCHE_FFX_COPY=1 CARTOUCHE_FFX_UI=1 CARTOUCHE_FFX_FG=ours \
CARTOUCHE_FRAMEGEN_FFX_DUMP=$work/dump-ui CARTOUCHE_FRAMEGEN_FFX_DUMP_FROM=${FFX_DUMP_FROM:-300} \
CARTOUCHE_FRAMEGEN_FFX_DUMP_COUNT=${FFX_DUMP_COUNT:-41}" $scene
info "$(grep -m1 'framegen: ffx ui frame' "$work/uidump.log" | cut -c11-)"
info "$(grep 'framegen: ffx ui copies' "$work/uidump.log" | tail -1 | cut -c11-)"
gpu_take
SCORE_UI=1 nice -n 15 "$score" "$work/dump-ui" > "$work/score-ui.txt" 2>&1
gpu_free
sed 's/^/        /' "$work/score-ui.txt"
mean=$(grep '^mean' "$work/score-ui.txt")
if [ -n "$mean" ]; then
  captured=$(echo "$mean" | awk '{ print $2 }'); kept=$(echo "$mean" | awk '{ print $4 }')
  awk -v c="$captured" -v k="$kept" 'BEGIN { exit !(k <= c) }' && ok "the UI kept apart ghosts less: $kept % of UI pixels off, $captured % from final frames alone" \
    || bad "UI kept apart" "<= $captured %" "$kept %"
else
  bad "UI score" "a mean line" "$(tail -1 "$work/score-ui.txt")"
fi
[ -n "${FFX_WORK:-}" ] || rm -rf "$work/dump-ui"
fi

after=$(fingerprint)
[ "$before" = "$after" ] && ok "the sample's folder is untouched ($after)" || bad "untouched" "$before" "$after"
info "logs in $work"
if [ "$fails" -eq 0 ]; then
  echo "==> framegen-ffx: all assertions hold"
else
  echo "==> framegen-ffx: $fails failed"
  exit 1
fi
