#!/bin/sh
# S3 with a human: 25 s with the Wine stand-in focused on the built-in screen. During that time,
# press in order, 3 s apart: ⌥F1, fn+⌥F1, fn+⌥⇧F1, then (controller connected) a short and a long
# press on the PS / Xbox button. The log shows which hotkey fired, whether the game saw F1, and
# whether a background app saw the Home button.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
spike="$here/../../out/overlay-spikes/Spike.app/Contents/MacOS/spike"
logs="${LOGS:-/tmp/overlay-spikes-logs}"
mkdir -p "$logs"
"$spike" pad --seconds 30 > "$logs/s3-manual.pad" 2>&1 &
"$here/run.sh" s3-manual "455 306 800 500 30 activate" "--hotkey --style activating --level screenSaver --end 25"
wait
grep -E 'pad|home' "$logs/s3-manual.pad"
grep -E 'hotkey|key vk|refused' "$logs/s3-manual.log"
