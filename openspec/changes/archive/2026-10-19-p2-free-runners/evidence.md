# Evidence: p2-free-runners

Branch `phase/p2-free-runners`, cut from main 6d88fe8, main 4fdc047 (docs only) merged in. Machine: Apple silicon, macOS 27.0, Xcode 27.0, Swift 6.4, Python 3.14. Nothing was pushed, no workflow ran on GitHub, no secret was set, nothing was installed. The app bundle is built with `make -o app-payload app` (no payload, as in P1 and P9).

Building Wine takes an x86_64 Mac and about an hour, so it is CI only. Every scenario that needs the real build, a real game or real hardware is marked **needs CI** or **needs maintainer** with exact steps.

## Tests

| Suite | Before (main 6d88fe8) | After (branch head) |
|---|---|---|
| `make -s app-tests` | 696 tests in 82 suites, 34 fail (43 issues) | 722 tests in 86 suites, the same 34 fail (43 issues) |
| Failing test names | `evidence/baseline-failing-tests.txt` (34) | `evidence/after-failing-tests.txt`, `diff` empty |
| Hermetic C suites from `app.yml` (19 incl. `packagingcheck`), `runcheck`, `scriptcheck`, `mincheck` | pass | pass (`evidence/after-suites.txt`) |
| `make -s packagingcheck` | 50 Python tests, scan test, workflow check, signing test | 64 Python tests, the extended scan test, 9 workflows wired, signing test: pass |
| `make -s redistscan` | pass | pass (also on `out/Cartouche.app`) |
| `make -s l10ncheck` | 545 strings | 567 strings, all translated for zh-Hans and it (the same one zh-Hans string left in English) |
| `openspec validate --all --strict` | 19 passed | 19 passed |

- The 34 failing Swift tests are the ones that need the staged payload, as on main.
- New Swift suites: "Runner manifest" (7), "Wine runner install" (9), "Game Porting Toolkit" (5), "Runners model" (5). No existing test was edited, skipped or deleted.
- New Python tests: `packaging/tests/test_wine_crossover.py` (11), `test_runner_manifest.py` (3). `redist-scan-test.sh` gained cases; its old cases are unchanged.
- `runcheck` and `scriptcheck` skip: shellcheck is not installed here. New shell scripts pass `sh -n`; `lint.yml` runs shellcheck in CI.

## Task 1.0: CI build of Wine CrossOver

- Check: `.github/workflows/wine-crossover.yml`. Job `scripts` (every PR touching it): the script tests and a dry run. Job `build` (manual run): pinned Xcode, fetch with SHA-256 check, Homebrew formulas, `build.sh`, `package.sh`, `verify.sh` (archive hash, layout, notices, `check-deps.sh`, `wine --version` in a scratch HOME), redistribution scan of the archive, `boot-check.sh` (winecfg), `resolve.py`, artifact upload. Job `publish` (manual, `publish` ticked, main only): one prerelease with the archive, `.sha256`, `manifest-entry.json`, `SOURCE.md` and a copy of the CodeWeavers tarball.
- Check: command `python3 packaging/tests/workflow_check.py` → `9 workflows parse and are wired`.
- Check: command `sh packaging/wine-crossover/build.sh --dry-run /tmp/p2/dry` → `evidence/dry-run.txt` (configure with `--enable-archs=i386,x86_64 --with-mingw --without-x`, rpath `@loader_path/../../`, macOS 15.0 target).
- Check: `package.sh` and `verify.sh` on the real pinned tarball with a stand-in install tree → `evidence/real-package.txt`: one top folder `wine-crossover-26.3.0-1/` with `LICENSE`, `COPYING.LIB`, `AUTHORS` from the tarball, `SOURCE.md` (tarball URL and SHA-256, release link, scripts at the commit), the manifest entry, and `verify: ok`.
- Check: tests `test_wine_crossover.py` (fetch keeps a match and deletes a mismatch; package layout and entry; package refuses other sources; verify passes and refuses a wrong hash; `check-deps.sh` catches an absolute dylib path; `bundle-deps.sh` rewrites real dylibs to `@rpath` and the result passes `check-deps.sh`; dry run; pins are full hashes).
- Result: pass locally for everything except the build itself. **Needs CI** for "wine --version from the artifact" (task left unticked).

## Pinned free Wine builds / Install a pinned build

- Check: test `WineRunnerInstallerTests.installPinned` ("A pinned build is downloaded, matches its SHA-256, unpacks into the runners folder, is ready and runs"). A tar.xz laid out like the CI build, served from a file URL, pinned by its own size and SHA-256.
- Result: pass. Registry state before: `available`. After install: the receipt holds the archive SHA-256 and the hashes of `bin/wine`, `bin/wineserver` and both `ntdll.dll`; the registry lists kind `wineBuild`, state `ready`, installed, flavors `[rosetta]`, not offered to Steam; `runners/wine-<id>/bin/wine --version` prints `wine-11.0 (fixture)`; the downloads folder is empty and nothing else is left in `runners/`.
- Check: test `RunnersModelTests.download` ("Download on Wine CrossOver 26.3 installs it and the row reads Ready").
- Result: pass. Row before: title `Wine CrossOver 26.3`, detail `Built by Cartouche from CodeWeavers’ open-source code`, status `Not installed`, action Download. After `perform(.download)`: status `Ready`, state `ready`, no action, no message.
- Check: test `RunnerManifestTests.shipped` and `ciEntry`.
- Result: pass. The shipped `runners.json` (revision 1) pins `wine-stable-11.0_1` (185303032 bytes, `b50dc50e…cb82388`) and `wine-devel-11.18`; the entry CI writes for Wine CrossOver reads as `Wine CrossOver 26.3`.
- **Needs CI, then maintainer.** "Wine CrossOver 26.3" is not in the shipped manifest yet: its SHA-256 exists only once CI has built it. Steps:
  1. Merge, then Actions > wine-crossover > Run workflow on main, `publish` ticked. Expected: green, the step summary shows the manifest entry, `verify.txt` ends with `wine-11.0…`, release `wine-crossover-26.3.0-1` exists with 5 assets.
  2. Paste `manifest-entry.json` into `builds` of `app/Sources/NotProtonApp/Resources/runners.json`, raise `revision` to 2, commit to main. `runner-manifest.yml` publishes it on the compat-data release.
  3. On an M-series Mac with this build: open the Runners screen (P5), click Download on "Wine CrossOver 26.3". Expected: the row reads Ready; `~/Library/Application Support/Cartouche/runners/wine-wine-crossover-26.3.0-1/bin/wine --version` prints a `wine-11.0` line.
  4. The 60-second winecfg check: see task 1.4 below.

## Pinned free Wine builds / Tampered download is rejected

- Check: test `WineRunnerInstallerTests.tamperedIsRejected`. The served archive has other bytes than the pinned one.
- Result: pass. `StepFailure.detail` is exactly `The download was damaged. Try again.`; no archive in the downloads folder; `runners/` is empty; the registry runner is `available`, not installed.
- Check: tests `wrongSize` (right hash, wrong size: refused), `staleDownload` (a wrong file in the downloads folder is replaced; an archive swapped after the check is deleted and never unpacked), `noLoader`, `unreachable`, `RunnerManifestTests.wrongHash` (5 malformed hashes refused) and `refusals` (non-https, other host, GPTK or CrossOver kind, paths leaving the runner folder, bad ids, size 0, unknown flavors, duplicates, format 2).
- Check: test `RunnersModelTests.damagedDownload`.
- Result: pass. `model.message == "The download was damaged. Try again."`, the row still reads `Not installed` with Download.
- Check: test `test_wine_crossover.py` `test_fetch_refuses_a_wrong_hash_and_keeps_nothing` (the CI fetch of the source tarball and llvm-mingw).
- Result: pass, exit 1, the downloads folder is empty.

## Steam Play hooks on free builds / Steam API reaches the game

- Result: **not done, needs CI then maintainer** (tasks 1.3 and 3.1 left unticked). The hook offsets come from the built `ntdll.dll`, which only CI produces, and `resolve.py` needs capstone, which is not installed here.
- What exists: the CI `build` job installs `capstone==5.0.9` in a venv, runs `ntdll-patch/resolve.py` on the unpacked build and uploads `ntdll-resolve.txt`, `ntdll-x86_64-windows.sh`, `ntdll-i386-windows.sh`. Free runners stay off Steam until pinned (`Runner.isOffered` is false; test `installPinned`).
- MAINTAINER steps after the first CI build:
  1. From the artifact: add the clean hashes and derived values to `PINNED` in `ntdll-patch/resolve.py`, run `CX_ROOT=<unpacked build> ./ntdll-patch/build-ntdll.sh` with new `*_CLEAN_*`/`*_PATCHED_*` variables to produce `detour2-<id>.bin` and `detour32-<id>.bin`.
  2. Add an `NtdllPatcher.byBuild` entry and a `SupportedRunners.all` build for it (loader SHA-256 of `lib/wine/x86_64-unix/wine`, clean and patched ntdll, one Rosetta tool such as `cartouche-proton-wine-26.3`), the two `.copy` resources in `app/Package.swift`, and `NtdllPatcherTests` cases for the new hashes. `SteamToolListTests` will then need the new tool in its expected lists: that is an intended change of the baseline.
  3. Install the Wine CrossOver build into `runners/crossover-<id>/CrossOver` (the layout matches CrossOver's) or let P3 point the run script at `runners/wine-<id>`.
  4. In Steam, set a game that shows the overlay (for example Portal 2's Windows build) to the new tool, launch it. Expected: `~/Library/Logs/Cartouche` game log has an `lsteamclient` load line, Steam shows the game as Running. Save `evidence/steam-running.png`.

## Game Porting Toolkit detection / GPTK found

- Check: test `PortingToolkitTests.found`. Fixture shaped like Apple's image: `Volumes/Evaluation environment for Windows games 4.0/redist/lib/external/D3DMetal.framework` (with `Versions/Current` and top-level symlinks, `Versions/A/Resources/Info.plist` with `CFBundleShortVersionString` 4.0b3), `libd3dshared.dylib`, `wine/x86_64-windows/d3d12.dll`.
- Result: pass. One install, version `4.0b3`, origin the volume. Registry: kind `portingToolkit`, `available`. After `copy`: `runners/gptk-4.0b3/lib/…` with symlinks kept and a receipt of 4 file hashes. After deleting the volume: one runner `gptk-4.0b3`, `ready`, installed, flavors `[rosetta]`; `d3dMetal` is `.portingToolkit(version: "4.0b3", …)` from the copy.
- Check: test `RunnersModelTests.toolkitFound`.
- Result: pass. A toolkit in `Applications/Game Porting Toolkit.app` is copied on refresh; the row reads `Game Porting Toolkit 3.0`, `Ready`, `Found in <…>/Applications`.
- Check: tests `otherPlaces` (an app, a version 1 Homebrew keg with `Resources/Info.plist`, a folder the user picked; same version found twice is taken from the first place; a "Porting Toolkit Notes.app" without D3DMetal is ignored) and `damage` (one flipped byte in the copied D3DMetal: `damaged` naming the file, D3DMetal no longer offered; copying again: `ready`).
- Check: command `plutil -p <a GPTK 4.0b3 lib>/external/D3DMetal.framework/Versions/A/Resources/Info.plist` on a copy on this Mac, read only.
- Result: `CFBundleShortVersionString => "4.0b3"`, the key and path the code reads.
- **Needs maintainer** for Apple's own image: mount `Evaluation environment for Windows games <v>.dmg` from Apple's download, open the Runners screen (P5). Expected: "Game Porting Toolkit <v>", Ready, and `~/Library/Application Support/Cartouche/runners/gptk-<v>/lib/external/D3DMetal.framework` exists. Eject the image, refresh: still Ready.

## Game Porting Toolkit detection / Nothing Apple is redistributed

- Check: test `packaging/tests/redist-scan-test.sh` (in `packagingcheck`, and the CI `redistribution` job). New cases: a clean tar.xz passes; a toolkit name inside a tar.gz fails and the entry is named; stand-in bytes listed in a test hash list fail as `lib/wine/x86_64-windows/d3d11.dll (same bytes as …)` in a folder, a zip and a tar.xz; one changed byte passes; the shipped `redist-hashes.txt` is well formed.
- Result: pass.
- Check: command `evidence/plant-proof.sh <GPTK lib>` → `evidence/redist-plant-proof.txt`. Real files from a GPTK 4.0b3 copy planted in a scratch tree: Apple's `d3d12.dll` under its own name and `libd3dshared.dylib` renamed `renamed.dll`.
- Result: the folder and its tar.xz fail with exit 1, naming both files by hash; after removing them, exit 0. The repository scan `sh packaging/redist-scan.sh .` passes (exit 0), and so does `out/Cartouche.app`.
- Check: `packaging/redist-hashes.txt` lists Apple's 3.0 evaluation image (MacPorts pin), Gcenx's 3.0-3 tarball, and the 18 files of a 4.0b3 redist. The Wine CrossOver archive is scanned in its CI job before upload.
- **Needs CI** for the release-asset part: the first `wine-crossover` run must pass its "Scan the archive" step.

## Game Porting Toolkit detection / GPTK absent

- Check: test `RunnersModelTests.toolkitAbsent`.
- Result: pass. Row `Game Porting Toolkit`, status `Not found`, link `How to Get It` → `https://developer.apple.com/games/game-porting-toolkit/`; `model.d3dMetal == nil`.
- Check: test `PortingToolkitTests.absent`.
- Result: pass. No toolkit runner; `d3dMetal` nil with no CrossOver, nil with a CrossOver clone without D3DMetal, `.crossOver(framework:)` once the clone has `lib64/apple_gptk/external/D3DMetal.framework`.
- Not confirmed: that path in a real CrossOver (none on this Mac). The backend menu itself is P3's.

## Task 1.4: winecfg in a fresh prefix

- Check: `packaging/wine-crossover/boot-check.sh` (in the CI `build` job): scratch HOME and WINEPREFIX, starts `wine winecfg`, waits for a window owned by a `wine` process with `wait-window.swift` (compiled first, so its compile time is not counted), screenshot, `boot.txt` with seconds and `wine --version`, exit 1 past 60 s.
- Check: `wait-window` against this Mac's windows: `wait-window finder 5` → `0.0`, exit 0; `wait-window nosuchapp 1` → exit 1 with `no nosuchapp window after 1 s`.
- Result: **needs CI** (task left unticked). After the first run, copy `boot/boot.txt` and `boot/winecfg.png` from the artifact to `evidence/`. The scenario asks for an M-series Mac: MAINTAINER, on one, `tar -xJf wine-crossover-26.3.0-1-x86_64.tar.xz -C /tmp/wcx && sh packaging/wine-crossover/boot-check.sh /tmp/wcx/wine-crossover-26.3.0-1 /tmp/wcx-boot 60`; expected `result=pass seconds=<60 or less>`; save `boot.txt` and `winecfg.png` here.

## Acceptance (task 4.1)

- `openspec validate p2-free-runners --strict` → `Change 'p2-free-runners' is valid`.
- THIRD-PARTY-LICENSES and docs/TRD.md updated by the docs agent (Wine CrossOver with its sources, bundled dylibs and source offer; WineHQ builds; GPTK never redistributed).
- Task 4.1 stays unticked until the CI and maintainer evidence above is in.
