# Bug J: Wine controller backend

## Cause

Read-only inspection of the installed `wine-crossover-26.3.0-1` runner found
`lib/wine/x86_64-unix/winebus.so` compiled with SDL support and a bundled
`lib/libSDL2-2.0.0.dylib`, but **no `libSDL3.dylib`**. The SDL2 library is
Homebrew's sdl2-compat (3201.70.0), not the original SDL2 implementation.
Its strings show `@loader_path/libSDL3.dylib` and `Failed loading SDL3 library.`.
A separate x86_64 dlopen probe reproduced that failure, including SDL's dialog
and abort. The Wine XInput probe in `.tmp/prefix` also terminated with code 2
without reaching main. The dialog was dismissed; all scratch Wine processes
were stopped. No real prefix or runner was modified.

`bundle-deps.sh` follows Mach-O load commands, so it cannot discover this
runtime dlopen dependency. `check-deps.sh` and `wine --version` both miss it.
The fix explicitly bundles Homebrew SDL3 alongside SDL2, and checks SDL controller
initialization in the build and unpacked archive. BUILD_REVISION changes 1 → 2.

## Ruled out / unchanged

- SDL_GAMECONTROLLERCONFIG is intentionally exported only for custom mappings;
  standard layouts use SDL's built-in mappings. It cannot repair a failed dlopen.
- Wine defaults enable SDL; DisableHidraw/DisableInput are Linux backend switches.
  No blanket registry overrides are added, preserving existing controller choices.
- IOHID is also built in, but is not a substitute for SDL's XInput mapping.
- No Input Monitoring or Accessibility grant can supply a missing dylib.
  No permission changes or resets were made.

## Validation

`python3 -m unittest discover -s packaging/tests -p test_wine_crossover.py`: 12 pass.
The new SDL check rejects the original runner with `missing libSDL3.dylib`.
For a local repaired-runner test, built SDL 3.4.18 from its upstream tarball for
x86_64 (SHA-256 9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3),
and copied its dylib only into `.tmp/runner/lib/libSDL3.dylib`. The real SDL
controller initialization check now passes. The Windows probe now reaches main
in a fresh `.tmp/prefix-fixed` and completes all 12 polls: XInput returns 1167
(device not connected), with no missing-SDL dialog or crash, as expected without
a controller. Full Wine rebuild is deferred to the existing x86_64 CI workflow.
`qa/controller-probe.c` is a Windows XInput/WinMM probe, compiled with
`x86_64-w64-mingw32-gcc qa/controller-probe.c -o .tmp/controller-probe.exe -lxinput -lwinmm`.
Use a worktree-local WINEPREFIX and WINEDLLOVERRIDES='mscoree=d;mshtml=d'.
No physical controller was connected during this investigation (IORegistry lists
only internal input devices and headset). Hardware recognition still needs a
controller connected to the rebuilt/published runner; the app manifest must then
be updated to the new archive hash. Do not replace the existing release asset.
