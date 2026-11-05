# C memory safety

Cartouche ships C and Objective-C that runs inside other programs: the dylib injected
into the Mac Steam client, the frame counter and overlay shim injected into games, the
frame generation library, the Windows helpers run under Wine. A memory bug there crashes
Steam or a game, or worse. Three kinds of checks cover that code, each a make target.

| Target | What it does | Needs | Time here |
|---|---|---|---|
| `make c-asan` | Builds and runs the hermetic C suites under ASan and UBSan | Xcode clang, node | 114 s, GPU part included |
| `make c-asan-gpu` | Same for the injected dylibs, host and dylib both sanitized (run by `c-asan`) | a Metal device | 29 s |
| `make c-analyze` | `clang --analyze` and `cppcheck` over the shipped sources, against a baseline | cppcheck, mingw-w64 headers | 53 s |
| `make fuzz-regress` | Replays every seed and past crash once under ASan and UBSan | Xcode clang | 6 s, plus about 30 s to build |
| `make fuzz-smoke` | Runs each libFuzzer harness for 60 s | network once, for libFuzzer | 618 s with the builds, plus 25 s once for libFuzzer |
| `make fuzz-nightly` | Same, `FUZZ_SECONDS` per harness (default 3600) | same | 1 h per harness |

Prefix them with the build lock on the shared Mac:
`~/Library/Caches/cartouche-night/locked.sh make c-asan`.

## What CI should run

| When | Targets | Why |
|---|---|---|
| Every PR touching C, Objective-C or the Makefile | `c-asan`, `c-analyze`, `fuzz-regress` | Minutes, no network, fail on any new finding |
| Nightly | `fuzz-nightly` (`FUZZ_SECONDS=3600`), then `c-asan` | Hours of fuzzing, corpus kept between runs |
| Before a release | `fuzz-smoke` locally | One minute per harness on the release build's sources |

Wired (docs/ci/CI.md): the `c-safety` job of `ci.yml` runs the PR row on every pull request
and push, whatever it touches, so the required check never waits on a path filter; the
`nightly.yml` `fuzz <harness>` jobs run one harness each, 30 minutes by default
(`fuzz_minutes` on a manual run), then its `c-asan` job. Both cache `build/libfuzzer/` on
the LLVM commit and `out/fuzz/corpus/<harness>/` from night to night, and upload
`out/fuzz/artifacts/<harness>/` when a harness fails. Hosted runners set `C_ASAN_GPU=0`.

On a hosted runner without a GPU, `c-asan` prints `skip overlay-shim-tests, fps-counter-tests:
no Metal device here` and passes. Set `C_ASAN_GPU=1` to run them without the device check,
or `C_ASAN_GPU=0` to skip on purpose. The nightly job should cache `out/fuzz/corpus/`
and `build/libfuzzer/`, and upload `out/fuzz/artifacts/` when a harness fails.

## c-asan

Each hermetic suite the CI already runs is rebuilt into `out/asan/` with
`-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all -g`
and run with `halt_on_error=1`, `detect_stack_use_after_return=1`,
`strict_string_checks=1` and `detect_invalid_pointer_pairs=1`. The suites:
compatcheck (its C part; the chained shell checks stay out with `COMPATCHECK_CHAIN=`),
compatsvc-check, libexport-check, services-check, webuicheck, shortcutcheck,
launch-shell, activatecheck, spawn-env, peicon-fixtures, webpatch-fixtures (with
nativeplatformcheck), panel-behavior, callscheck, unarccheck, homecheck. Each writes
`out/c-asan-<suite>.log`; a failure prints the sanitizer report.

The shell suites (envcheck, routecheck, settingscheck, ...) test `compat_run.sh`, not C,
and stay out. So do anchorcheck and spawn-live, which need a real `steamclient.dylib`
and a Dobby build.

`c-asan-gpu` builds the overlay shim and the frame counter, both slices, with the
same flags, and their test hosts too. A sanitized dylib loaded into an unsanitized
host aborts ("interceptors are not installed"), and with both sanitized the runtime is
already loaded when the dylib arrives, so `-mllvm -asan-globals=0` and preloading the
runtime are not needed. The x86_64 slice runs under Rosetta and passes too.

Line numbers: clang runs `dsymutil` itself when it compiles and links in one step with
`-g`, so every suite binary gets a `.dSYM` next to it and reports read `file.c:42`.

## c-analyze

`tools/c-safety/analyze.sh` runs `clang --analyze -Xanalyzer -analyzer-output=text` (Xcode
clang, default checkers plus `security.insecureAPI.strcpy`) over:

- the dylib sources (`SRCS` in the Makefile, without `vendor/`), `helpers/shortcuts.c`,
  `framegen/bridge/cartouche_bridge_unix.c`, `framegen/proxy/ffx_proxy_unix.c`;
- `overlay-shim/overlay_shim.m`, `fps-counter/fps_counter.m`, the frame generation
  library (`FRAMEGEN_SRC`, x86_64, ARC) and `framegen/ane/helper.m`;
- the Windows sources against the mingw-w64 headers: `framegen/bridge/cartouche_bridge.c`,
  `framegen/proxy/ffx_proxy.c`, `helpers/game-restore.c`, `helpers/unarc-driver.c`,
  `ntdll-patch/detour.c`, `ntdll-patch/detour32.c` (skipped with a message when
  `brew install mingw-w64` is missing).

Then `cppcheck --enable=warning,portability,performance --inline-suppr` over the same C
and C++ (cppcheck does not read Objective-C), with the include paths and the platform
of each group, plus `steam-shim/steam.cpp`.

Every finding is a line `tool file check message`, without the line number so moving
code keeps it. Anything not in `tools/c-safety/analyze-baseline.txt` fails the target;
baseline entries nothing reports any more are listed so they get removed. Prefer fixing
the code, then an inline `// cppcheck-suppress <id>` with the reason on the line above,
then a baseline entry with a reason.

Not analysed, each third-party or built elsewhere:

| Path | What | Why |
|---|---|---|
| `vendor/cJSON.*` | cJSON | Upstream, fuzzed by OSS-Fuzz; reached through the sigdb and libexport harnesses |
| `vendor/dobby`, `vendor/RetroArch` | Dobby, RetroArch | Upstream, not tracked here |
| `steam-shim/json/`, `steam-shim/jsoncpp.cpp` | jsoncpp amalgamation | Upstream |
| `framegen/proxy/ffx/` | AMD FidelityFX API headers | Upstream (MIT), include-only |
| `lsteamclient/` | Proton's lsteamclient | Valve's code, built in the Wine tree |
| `*/tests/`, `qa/`, `tools/`, `docs/research/` | Tests, probes, spikes | Not shipped |
| `steam-shim/steam.cpp` under clang | Valve's steam.exe shim | Needs the Wine tree headers; cppcheck covers it |

## Fuzzing

Harnesses live in `fuzz/`. Each includes the unit it fuzzes, the way the suites in
`dylib/tests/` do, so static parsers are reachable without changing the shipped code.
Xcode's clang has the sanitizers but not the libFuzzer runtime, so
`fuzz/build-libfuzzer.sh` fetches `compiler-rt/lib/fuzzer` from LLVM 21.1.0 (pinned
commit `3623fe66`, sparse, then checks the commit and the tree hash `c7aa7f0f` of
`compiler-rt/lib/fuzzer` before building) into `build/libfuzzer/` and builds `libFuzzer.a` once. The harnesses build
with `-fsanitize=fuzzer-no-link,address,undefined`, the same as
`-fsanitize=fuzzer,address,undefined` with a full LLVM. `LIBFUZZER=` points at another
runtime, such as Homebrew LLVM's.

| Harness | Unit and entry | Input, and who writes it | Checks beyond the sanitizers |
|---|---|---|---|
| `peicon` | `dylib/util/peicon.c` `icon_from_map` | Any `.exe` the user adds as a shortcut | Every icon byte readable |
| `aob` | `dylib/resolver/aob.c` `np_compile_pattern`, `np_scan_sole_match` | Byte patterns from the signature database | |
| `sigdb` | `dylib/resolver/sigdb.c` `np_load_profile` (cJSON inside) | `signatures/*.json` in the support folder | |
| `webpatch` | `dylib/feats/webpatch.c` `np_webpatch_transform`, `np_webpatch_should_patch` | Steam's UI JavaScript chunks, steamui paths | Output NUL-terminated at its length |
| `libexport` | `dylib/feats/libexport.c` `loginusers_steamid`, `validate_export` | Steam's `config/loginusers.vdf`; the library page's owned-games JSON | |
| `compat` | `dylib/feats/compat.c` tool list, backend list, `np_compat_apply_requests_from` | The app's `tools`, backend list and tool requests files | Only Cartouche tool names reach `SetCompatToolMapping`; every kept entry valid |
| `nativeplatform` | `dylib/feats/nativeplatform.c` `np_nativeplatform_javascript` | The appinfo helper's output (it parses Steam's `appinfo.vdf`) | Only digits and commas reach the page |
| `spawn` | `dylib/hooks/hook_spawn.c` env strip and re-insert, target check | Every environment Steam spawns with | No stripped key survives; the insert is added once |
| `launch` | `dylib/hooks/hook_launch.c` `np_launch_shell`, backslash doubling | Launch options, `STEAM_GAME_LAUNCH_SHELL` | Unquoting the command line gives back the input |
| `framegen_env` | `framegen/fg_temporal.m`, `fg_upscale.m`, `fg_overlay.m` parsers | `CARTOUCHE_FRAMEGEN_TEMPORAL`, `_UPSCALE`, `CARTOUCHE_OVERLAY`, `_POS` | |

Not fuzzed, with the reason:

- `dylib/core/macho.c`, `dylib/resolver/anchor.c`: they read Steam's own loaded, signed
  `steamclient.dylib` in memory, not a file anyone else writes; callscheck and
  anchorcheck cover them.
- `dylib/feats/webui.c`, `compatsvc.c`, `usershortcuts.c`: they read Steam's live C++
  objects through the client's own functions; webuicheck, compatsvc-check and
  services-check cover them.
- `dylib/hooks/hooks.c` `np_hooks_env_lists_label`, `dylib/util/log.c` level,
  `dylib/core/loader.c` `CARTOUCHE_SIG` and sigdb file names: a bounded `strchr` walk,
  an `atoi`, a `snprintf` and a `strtoull`, read by hand.
- `fps-counter/`, `overlay-shim/`: no parser; the one path they take from the
  environment is copied with `strlcpy`.
- `helpers/appinfo` and the app's VDF readers are Swift, outside this C work.
- `framegen/framegen.m` `CARTOUCHE_FRAMEGEN_TUNE` and `fg_upscale.m` `CARTOUCHE_FRAMEGEN_CLICKS`:
  `sscanf` with bounded widths into fixed buffers, in test-only switches.
- `steam-shim/`, `ntdll-patch/`, `framegen/proxy`, `framegen/bridge`: Windows code run
  under Wine, built with mingw or in the Wine tree; covered by c-analyze.

Seeds are in `fuzz/corpus/<harness>/`, written by hand-made generators, with no Steam,
game or installer data: `python3 -I fuzz/make-seeds.py` for most of them, and
`make fuzz-seeds` for webpatch, whose seeds are its own gate table with each capture
filled by an identifier. The corpus grown by a run stays in `out/fuzz/corpus/`.

A crash leaves its input in `out/fuzz/artifacts/<harness>/`. Minimise it with
`out/fuzz/fuzz_<harness> -minimize_crash=1 -runs=10000 <input>`, fix the code, and add the
input to `fuzz/regressions/<harness>/`, which `fuzz-regress` and every fuzz run replay.

## Findings, November 2026

First runs on `release/0.2.0-beta2`. Each fix has its own commit and a test.

| Where | What | Found by | Fix | Test |
|---|---|---|---|---|
| `helpers/unarc-driver.c` password callback | `strcpy` of `--password` into unarc's buffer, unbounded | release gate | Copy only when it fits `int1`, the buffer size unarc passes; refuse otherwise | `make unarccheck` |
| `framegen/fg_temporal.m` `FGTemporalParse` | `fx=1e30` or `fx=nan` cast to `int`: undefined | `fuzz-smoke` framegen_env | Out-of-range `fx` is an ignored part | `fuzz/regressions/framegen_env/` |
| `dylib/resolver/sigdb.c` `build_field` | negative or huge `steam_build` cast to `uint64_t`: undefined | sigdb harness, probe input | Reads as no build, like a missing field | `fuzz/regressions/sigdb/` |
| `steam-shim/steam.cpp` | `fscanf("%s")` into a 50-byte key; `sprintf`/`strcat`; `idx_str[10]` one byte short for `%u` | release gate, cppcheck `invalidscanf` | `%49s`, `snprintf` with sizes, `idx_str[12]`, `memcpy` | not built here (Wine tree) |
| `dylib/tests/callscheck.c`, `launch-shell.c` | `strcpy`, `popen` in tests | release gate | `snprintf`, `posix_spawn` | the suites themselves |

Accepted, with the reason next to each:

| Where | Check | Reason |
|---|---|---|
| `dylib/hooks/hook_webpatch.c` `np_fopen` | cppcheck `doubleFree` (inline) | A failed `fdopen` leaves the fd open, so closing it is right |
| `dylib/util/peicon.c` `np_pe_icon_ico` | cppcheck `nullPointerOutOfMemory` (inline) | `mmap` fails with `MAP_FAILED`, checked; never NULL |
| `dylib/util/file.c` `np_home_dir` | cppcheck `getpwuidCalled` (inline) | Only without HOME; macOS gives each result its own storage, `make homecheck` holds it |
| `dylib/feats/compat.c` tool lists | clang `unix.BlockInCriticalSection` (baseline) | The lists are read under the lock on purpose, a few hundred bytes |
| `dylib/feats/compat.c` `same_content` | clang `unix.Stream` x2 (baseline) | One extra `fread` after a short read returns 0 and ends the loop |
| `overlay-shim/overlay_shim.m` install | clang `osx.cocoa.RetainCount` (baseline) | One default device per process, created to read its class |
| `steam-shim/steam.cpp` | cppcheck `dangerousTypeCast` (baseline) | Valve's C-style casts to the Win32 API's own types |

Settled without a code change: cppcheck's `uninitvar` at `hook_webpatch.c:125` (the
array is filled before the outer call runs; the count now has its own statement) and
`unknownMacro` at `compat.c:691` (cppcheck lacked the identity include path).

Smoke after the fixes, fresh corpus, 60 s each, Apple M-series, all clean:

| Harness | Runs | Coverage | | Harness | Runs | Coverage |
|---|---|---|---|---|---|---|
| peicon | 20.0 M | 128 | | compat | 0.33 M | 151 |
| aob | 44.3 M | 53 | | nativeplatform | 60.7 M | 29 |
| sigdb | 0.75 M | 319 | | spawn | 25.8 M | 41 |
| webpatch | 0.24 M | 287 | | launch | 29.1 M | 34 |
| libexport | 1.84 M | 471 | | framegen_env | 6.6 M | 63 |

The sanitizer suites found nothing in the code they cover: every suite passed under
ASan+UBSan on the first run, and the overlay shim and frame counter did too.
