#!/bin/sh
# Graphics backend per compatibility tool, and the game's own variables, as the run
# script applies them. Blocks are cut out of the script and run against scratch trees.
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "backendcheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_backend=""$/,/^np_dropped=""$/p' "$SRC" | sed '$d')
setup_fn=$(sed -n '/^read_game_setup() {$/,/^}$/p' "$SRC")
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | sed 's/^[[:space:]]*//')
# shellcheck disable=SC2016 # Match the literal line.
backend_line=$(grep -x '\[ -z "$np_backend_path" \] || WINEDLLPATH="$np_backend_path:$WINEDLLPATH"' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$block" ] && [ -n "$setup_fn" ] && [ -n "$dllpath_line" ] && [ -n "$backend_line" ] && [ -n "$forward" ] \
  || { echo "FAIL: backend blocks not found in $SRC"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/Cartouche"
np_tool_dir="$work/compatibilitytools.d/cartouche-proton-26.3-dxmt"
crossover="$work/runners/crossover-26.3.0.39832/CrossOver"
wine="$work/runners/wine-wine-crossover-26.3.0-1"
mkdir -p "$np_tool_dir" "$crossover/share/crossover" "$crossover/lib/wine" "$wine/lib/wine"

# Runs the backend block for one tool, then the WINEDLLPATH line
run() {
  unset -v CX_GRAPHICS_BACKEND np_backend_files np_backend_dlls
  CX_ROOT="$1"
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$np_tool_dir/backend"; else rm -f "$np_tool_dir/backend"; fi
  WINEDLLOVERRIDES="$3"
  [ -z "$4" ] || export CX_GRAPHICS_BACKEND="$4"
  WINEDLLPATH=""
  eval "$block"
  eval "$dllpath_line"
  eval "$backend_line"
}

install_backend() {
  dir="$np_support/backends/$1"
  mkdir -p "$dir/x86_64-windows" "$dir/i386-windows" "$dir/x86_64-unix"
  printf '{}' > "$dir/.cartouche-backend.json"
}

echo "== CrossOver loads its own copy of each backend =="
for b in d3dmetal dxmt dxvk wined3d; do
  run "$crossover" "$b" "" ""
  is "$b: CX_GRAPHICS_BACKEND" "$b" "${CX_GRAPHICS_BACKEND:-}"
  is "$b: no Cartouche files in WINEDLLPATH" "$crossover/lib/wine/x86_64-windows:$crossover/lib/wine/x86_64-unix" "$WINEDLLPATH"
  is "$b: no DLL override" "" "$WINEDLLOVERRIDES"
  is "$b: logged as CrossOver's" "CrossOver's own copy" "$np_backend_from"
  is "$b: nothing missing" "" "$np_backend_missing"
done

echo "== The tool's backend replaces the launch option, and says so =="
run "$crossover" dxmt "" d3dmetal
is "launch option replaced" dxmt "$CX_GRAPHICS_BACKEND"
is "the log names both" "launch option CX_GRAPHICS_BACKEND=d3dmetal replaced by this tool's dxmt" "$np_backend_note"
run "$crossover" "" "" dxvk
is "a tool without a backend leaves the launch option" dxvk "$CX_GRAPHICS_BACKEND"
is "and loads nothing of Cartouche's" "" "$np_backend_path"
run "$crossover" 'dxmt;x' "" ""
is "a garbled backend file is ignored" "" "${CX_GRAPHICS_BACKEND:-}"

echo "== Another Wine loads Cartouche's pinned DXMT or DXVK as builtin DLLs =="
run "$wine" dxmt "" ""
is "dxmt not downloaded: the launch is refused" 1 "$np_backend_missing"
is "dxmt not downloaded: no override" "" "$WINEDLLOVERRIDES"
install_backend dxmt
install_backend dxvk
files="$np_support/backends/dxmt"
run "$wine" dxmt "winhttp=n,b" ""
is "dxmt first in WINEDLLPATH" \
  "$files/x86_64-windows:$files/i386-windows:$files/x86_64-unix:$wine/lib/wine/x86_64-windows:$wine/lib/wine/x86_64-unix" "$WINEDLLPATH"
is "dxmt builtins outrank the launch options" "winhttp=n,b;d3d11,dxgi,d3d10core=b" "$WINEDLLOVERRIDES"
is "dxmt logged from the backends folder" "$files" "$np_backend_from"
run "$wine" dxvk "" ""
files="$np_support/backends/dxvk"
is "dxvk first in WINEDLLPATH" \
  "$files/x86_64-windows:$files/i386-windows:$files/x86_64-unix:$wine/lib/wine/x86_64-windows:$wine/lib/wine/x86_64-unix" "$WINEDLLPATH"
is "dxvk builtins" "d3d9,d3d10core,d3d11,dxgi=b" "$WINEDLLOVERRIDES"
case "$WINEDLLPATH" in *backends/dxmt*) bad "no dxmt with dxvk" "" "$WINEDLLPATH" ;; *) ok "no dxmt with dxvk" ;; esac
run "$wine" wined3d "" ""
is "wined3d is Wine's own" "$wine/lib/wine/x86_64-windows:$wine/lib/wine/x86_64-unix" "$WINEDLLPATH"
is "wined3d builtins" "d3d9,d3d10core,d3d11,dxgi=b" "$WINEDLLOVERRIDES"
run "$wine" d3dmetal "" ""
is "d3dmetal without CrossOver is refused" 1 "$np_backend_missing"
rm -f "$np_support/backends/dxvk/.cartouche-backend.json"
run "$wine" dxvk "" ""
is "a backend folder without its receipt is not used" 1 "$np_backend_missing"

echo "== The game's own variables =="
eval "$setup_fn"
app_id=1245620
mkdir -p "$np_support/setups"
printf '%s\n' "MTL_HUD_ENABLED=1" "DXMT_LOG_LEVEL=info" "PATH=/evil" "D3DM_ENABLE_METALFX=1" \
  "DXVK_HUD=fps" "dxvk_x=1" "MTL_=1" "no equals" > "$np_support/setups/$app_id.env"
unset -v MTL_HUD_ENABLED DXMT_LOG_LEVEL D3DM_ENABLE_METALFX
export DXVK_HUD=devinfo
wine_unix="$wine/lib/wine/x86_64-unix"
out=$(read_game_setup; printf '%s|%s|%s|%s|%s' "${MTL_HUD_ENABLED:-}" "${DXMT_LOG_LEVEL:-}" "$PATH" "${D3DM_ENABLE_METALFX:-}" "$DXVK_HUD")
is "allowed names are set, PATH is not, a launch option wins" "1|info|$PATH|1|devinfo" "${out##*
}"
case "$out" in *"setup: PATH is not a variable Cartouche sets, ignored"*) ok "PATH refused in the log" ;; *) bad "PATH refused in the log" "ignored" "$out" ;; esac
case "$out" in *"setup: DXVK_HUD kept from the launch options"*) ok "launch option kept in the log" ;; *) bad "launch option kept" "kept" "$out" ;; esac
wine_unix="$wine/lib/wine/aarch64-unix"
out=$(read_game_setup; printf '\nD3DM=%s' "${D3DM_ENABLE_METALFX:-}")
is "D3DMetal settings stay out on arm64 Wine" "D3DM=" "${out##*
}"
unset -v DXVK_HUD
read_game_setup > /dev/null
set --
eval "$forward"
forwarded=""
for a in "$@"; do
  case "$a" in MTL_HUD_ENABLED=*) forwarded=${a#*=} ;; esac
done
is "the game launcher receives the Metal HUD" "1" "$forwarded"
app_id=0
is "no app, no setup file read" "" "$(read_game_setup)"
unset -v MTL_HUD_ENABLED DXMT_LOG_LEVEL DXVK_HUD CX_GRAPHICS_BACKEND

echo "== A missing backend stops the launch before the prefix is touched =="
# shellcheck disable=SC2016 # Match the literal line.
refuse_at=$(grep -n '^if \[ -n "\$np_backend_missing" \]; then$' "$SRC" | cut -d: -f1)
check_at=$(grep -n '^stage_step="runner check"$' "$SRC" | cut -d: -f1)
prefix_at=$(grep -n '^  prepare_prefix_directory$' "$SRC" | cut -d: -f1)
if [ -n "$refuse_at" ] && [ "$check_at" -lt "$refuse_at" ] && [ "$refuse_at" -lt "$prefix_at" ]; then
  ok "refused after the runner check, before the prefix lock"
else
  bad "refused after the runner check, before the prefix lock" "$check_at < x < $prefix_at" "$refuse_at"
fi

if [ "$fails" -eq 0 ]; then
  echo "==> backendcheck: all assertions hold"
else
  echo "==> backendcheck: $fails failed"
  exit 1
fi
