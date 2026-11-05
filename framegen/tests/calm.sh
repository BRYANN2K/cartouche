#!/bin/sh
# One short session on a calm machine, about 8 minutes, for phase 1.5: GPU cost at 1080p (the
# defaults and mode 4, fastest and median of 30 frames), quality at 1440p with the automatic
# short way back and with the full one, and energy per shown frame at base 30 on the built-in
# screen. Run "sudo -v" first, for powermetrics. Builds nothing: run make first.
# Usage: framegen/tests/calm.sh   (the results also go to CALM_LOG)
set -u
cd "$(dirname "$0")/../.." || exit 1
bin="$PWD/out/framegen"
log="${CALM_LOG:-$HOME/Library/Caches/cartouche-framegen-calm-$(date +%Y%m%d-%H%M).txt}"
for f in "$bin/pipeline" "$bin/tune" "$bin/game" "$bin/winemetal.so" "$PWD/out/framegen.dylib"; do
  [ -e "$f" ] || { echo "calm: $f is missing, run: make framegen out/framegen/pipeline out/framegen/tune out/framegen/game out/framegen/winemetal.so"; exit 1; }
done
sudo -n /usr/bin/powermetrics -h > /dev/null 2>&1 || { echo "calm: run 'sudo -v' first"; exit 77; }
# The GPU is shared with other agents' runs: wait for it, and give it back on any exit
while ! mkdir /tmp/cartouche-gpu.lock 2> /dev/null; do sleep 5; done
trap 'rmdir /tmp/cartouche-gpu.lock 2> /dev/null' EXIT INT TERM
{
  echo "calm session $(date), load: $(uptime | sed 's/.*averages*: //')"
  echo "== GPU at 1080p"
  "$bin/pipeline" 1920 1080 | grep "with the default"
  PIPELINE_SET=mode=4 "$bin/pipeline" 1920 1080 | grep "with mode"
  echo "== 1440p, wrong 2x2 blocks at 40 and 60 fps (err ghost 2x2 each) | GPU ms"
  printf 'automatic (quarter, short way back)  '
  TUNE_W=2560 TUNE_H=1440 TUNE_FRAMES=12 TUNE_SET=repair=1 "$bin/tune" --3d mockup/brand/cartouche-icon-default.svg 40 60 \
    | tail -1 | cut -d'|' -f2-
  printf 'quarter, full way back               '
  TUNE_W=2560 TUNE_H=1440 TUNE_FRAMES=12 TUNE_SET=factor=4,check=1 "$bin/tune" --3d mockup/brand/cartouche-icon-default.svg 40 60 \
    | tail -1 | cut -d'|' -f2-
  echo "== Energy per shown frame, base 30, built-in screen"
  sh framegen/tests/watts.sh "$PWD/out/framegen.dylib" "$bin" 30 30
  echo "done $(date)"
} 2>&1 | tee "$log"
echo "calm: results in $log"
