#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2016 # variables belong to the extracted script; patterns are literal
set -eu
src="${1:-$(dirname "$0")/../feats/compat_run.sh}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/support"
STEAM_COMPAT_DATA_PATH="$work/prefix with spaces"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
printf 'previous launch\n' > "$STEAM_COMPAT_DATA_PATH/cartouche-run.log"
eval "$(sed -n '/^init_launch_log() {$/,/^}/p' "$src")"
init_launch_log
first="$attempt_dir"
printf 'first launch\n' >> "$log"
init_launch_log
second="$attempt_dir"
printf 'second launch\n' >> "$log"
[ "$first" != "$second" ]
[ "$(cat "$first/launch.log")" = 'first launch' ]
[ "$(cat "$first/previous-run.log")" = 'previous launch' ]
[ "$(cat "$STEAM_COMPAT_DATA_PATH/cartouche-run.log")" = 'second launch' ]
# Render the actual generated launcher against a fake Wine executable.
WINELOADER="$work/wine"
loader_root="$work/loader"
mkdir -p "$loader_root"
printf '#!/bin/sh\necho wine-output\nexit 7\n' > "$WINELOADER"
chmod +x "$WINELOADER"
body=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$src" | sed '1d;$d')
eval "cat > \"$work/launcher\" <<LAUNCHER
$body
LAUNCHER"
for folder in "$first" "$second"; do
 status=0
 CARTOUCHE_LAUNCH_LOG_DIR="$folder" sh "$work/launcher" || status=$?
 [ "$status" = 7 ]
 grep -q 'wine-output' "$folder/wine.log"
 grep -q 'status=7' "$folder/wine.log"
done
[ -f "$first/wine.log" ]
echo 'launchlogcheck: separate launch and Wine logs, previous log retained, exit status captured'
