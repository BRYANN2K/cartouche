#!/bin/sh
# Starts the game in its own prefix. Written by Cartouche.
export CX_GRAPHICS_BACKEND='dxmt'
export CX_ROOT='$SCRATCH/runners/wine-crossover-26.3.0-1'
export DXMT_LOG_LEVEL='none'
export WINEDEBUG='-all'
export WINEDLLOVERRIDES='winemenubuilder.exe=d;d3d11,dxgi,d3d10core=b'
export WINEDLLPATH='$SCRATCH/backends/dxmt/x86_64-windows:$SCRATCH/runners/wine-crossover-26.3.0-1/lib/wine/x86_64-windows:$SCRATCH/runners/wine-crossover-26.3.0-1/lib/wine/x86_64-unix'
export WINELOADER='$SCRATCH/runners/wine-crossover-26.3.0-1/bin/wine'
export WINEPREFIX='$SCRATCH/installs/Hollow Pines/pfx'
export WINESERVER='$SCRATCH/runners/wine-crossover-26.3.0-1/bin/wineserver'
export PATH='$SCRATCH/runners/wine-crossover-26.3.0-1/bin':"$PATH"
for dll in nvapi64.dll nvngx.dll; do
  ! cmp -s '$HOME/Library/Application Support/Cartouche/backends/dxmt/x86_64-windows'/"$dll" "$WINEPREFIX/drive_c/windows/system32/$dll" \
    || rm -f "$WINEPREFIX/drive_c/windows/system32/$dll"
done
crash_file="$WINEPREFIX/cartouche-crash"
if [ "$(cat "$crash_file" 2>/dev/null)" != '1' ]; then
  "$WINELOADER" 'reg' 'add' 'HKCU\Software\Wine\WineDbg' '/v' 'ShowCrashDialog' '/t' 'REG_DWORD' '/d' '0' '/f' >/dev/null 2>&1 &&
  "$WINELOADER" 'reg' 'add' 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' '/v' 'Debugger' '/t' 'REG_SZ' '/d' 'winedbg --auto %ld %ld' '/f' >/dev/null 2>&1 &&
  "$WINELOADER" 'reg' 'add' 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' '/v' 'Auto' '/t' 'REG_SZ' '/d' '1' '/f' >/dev/null 2>&1 &&
  "$WINELOADER" 'reg' 'add' 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' '/v' 'Debugger' '/t' 'REG_SZ' '/d' 'winedbg --auto %ld %ld' '/f' '/reg:32' >/dev/null 2>&1 &&
  "$WINELOADER" 'reg' 'add' 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' '/v' 'Auto' '/t' 'REG_SZ' '/d' '1' '/f' '/reg:32' >/dev/null 2>&1 &&
  printf '%s' '1' > "$crash_file"
fi
# Controls from Cartouche
if [ -f '$SCRATCH/installs/Hollow Pines/controller.sdl' ]; then
  SDL_GAMECONTROLLERCONFIG=$(cat '$SCRATCH/installs/Hollow Pines/controller.sdl'); export SDL_GAMECONTROLLERCONFIG
fi
if [ -f '$SCRATCH/installs/Hollow Pines/keyboard.reg' ] && ! cmp -s '$SCRATCH/installs/Hollow Pines/keyboard.reg' '$SCRATCH/installs/Hollow Pines/.keyboard.applied'; then
  cp '$SCRATCH/installs/Hollow Pines/keyboard.reg' "$WINEPREFIX/drive_c/cartouche-keyboard.reg" \
    && "$WINELOADER" reg import 'C:\cartouche-keyboard.reg' >/dev/null 2>&1 \
    && cp '$SCRATCH/installs/Hollow Pines/keyboard.reg' '$SCRATCH/installs/Hollow Pines/.keyboard.applied'
  rm -f "$WINEPREFIX/drive_c/cartouche-keyboard.reg"
fi
# Cartouche frame generation
if [ "${CARTOUCHE_FRAMEGEN:-0}" = 1 ]; then
  fg_library='$HOME/Library/Application Support/Cartouche/framegen.dylib'
  fg_stats='$SCRATCH/installs/Hollow Pines/'
  fg_marker="${TMPDIR:-/tmp}/cartouche-framegen-$$"
  if [ -f "$fg_library" ] && DYLD_INSERT_LIBRARIES="$fg_library" CARTOUCHE_FRAMEGEN_PROBE="$fg_marker" \
    "$WINELOADER" --version > /dev/null 2>&1 && [ -s "$fg_marker" ]; then
    export DYLD_INSERT_LIBRARIES="$fg_library${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
    export CARTOUCHE_FRAMEGEN_INTERPOLATE=0
    export CARTOUCHE_FRAMEGEN_DIR="${CARTOUCHE_FRAMEGEN_DIR:-$fg_stats}"
    echo "framegen: on for this launch"
  else
    echo "framegen: refused by this runner"
  fi
  rm -f "$fg_marker"
fi
# Cartouche local frame counter
if [ -n "${CARTOUCHE_FPS_DIR:-}" ]; then
  fps_result=refused
  fps_marker="$CARTOUCHE_FPS_DIR/probe"
  if [ "${CARTOUCHE_FPS:-1}" != 0 ] && [ -f "${CARTOUCHE_FPS_COUNTER:-}" ]; then
    if DYLD_INSERT_LIBRARIES="$CARTOUCHE_FPS_COUNTER" CARTOUCHE_FPS_PROBE="$fps_marker" \
      "$WINELOADER" --version > "$CARTOUCHE_FPS_DIR/probe.log" 2>&1 && [ -s "$fps_marker" ]; then
      fps_result=on
      export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:+$DYLD_INSERT_LIBRARIES:}$CARTOUCHE_FPS_COUNTER"
    fi
  fi
  rm -f "$fps_marker"
  printf 'measure=%s\n' "$fps_result" >> "$CARTOUCHE_FPS_DIR/session"
  echo "fps: $fps_result for this launch"
fi
cd '$SCRATCH/installs/Hollow Pines/drive_c/Games/Hollow Pines/' || exit 1
exec '$SCRATCH/runners/wine-crossover-26.3.0-1/bin/wine' '$SCRATCH/installs/Hollow Pines/drive_c/Games/Hollow Pines/HollowPines.exe' "$@"
