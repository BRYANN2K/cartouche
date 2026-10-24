# Evidence: p3-graphics-backends

Branch `phase/p3-graphics-backends`, cut from main 797fb2b (P5 merged). Machine: Apple silicon, macOS 27.0, Xcode 27.0, Swift 6.4, Python 3.14. Nothing was pushed, no workflow ran on GitHub, no secret was set, nothing was installed, no archive was downloaded. Tests use fixtures, scratch HOME folders and scratch UserDefaults; none reads or writes the user's Steam or `~/Library` (the SteamFixture folder stands in for `~/Library/Application Support/Steam`).

Every scenario that needs a real game, a real Steam client or real hardware is marked **needs maintainer** with exact steps.

## Tests

| Suite | Before (main 797fb2b) | After (branch head) |
|---|---|---|
| `make -s app-tests` | 785 tests in 95 suites, 34 fail (43 issues) | 824 tests in 101 suites, the same 34 fail (43 issues) |
| Failing test names | `evidence/baseline-failing-tests.txt` (34, the payload ones, same list as P2) | `evidence/after-failing-tests.txt`, `diff` empty |
| Hermetic suites from `app.yml`, plus `runcheck`, `scriptcheck`, `redistscan`, `retroarch-tests` | all pass (`evidence/baseline-suites.txt`) | all pass, plus the new `backendcheck` (`evidence/after-suites.txt`) |
| `make -s compatcheck` | layout probes, tool list, stale tools | the same, plus backend list, pair directories, request file cases, and it runs `backendcheck` |
| `make -s retroarch-tests` | 67 tests in 9 suites pass | the same |
| `make -s packagingcheck` | pass | pass |
| `make -s redistscan` | pass | pass, also on `out/Cartouche.app` |
| `make -s -o app-payload app && make -s l10ncheck` | 730 strings | 749 strings, all translated for zh-Hans and it (the same one zh-Hans string left in English) |
| `openspec validate --all --strict` | pass | 19 passed |

- The 34 failing Swift tests need the staged payload (`make app-payload` needs the bridge build), as on main and in P1, P2 and P5.
- New Swift suites: "Game setup" (12), "Graphics backend downloads" (8), "Steam tools per runner and backend" (4), "Setup written to Steam and read back" (6), "Mac builds from appinfo" (4, one with 3 cases), "Setup menus offer valid pairs only" (5).
- New shell suite: `dylib/tests/backendcheck.sh` (`make backendcheck`, also run by `make compatcheck`, which `app.yml` already runs).
- No existing test was edited, skipped or deleted. `SteamToolListTests` (the P0 tool list baseline), `PrefixToolsTests` (WINEDLLPATH agreement) and `envcheck` pass unchanged: the backend pairs go to a second list file, and the backend's WINEDLLPATH entry is a separate line after the line those tests read.
- `runcheck` and `scriptcheck` skip: shellcheck is not installed here. `sh -n dylib/feats/compat_run.sh` passes; `lint.yml` runs shellcheck in CI.

## How it fits together

- **Setup store.** `GameSetupChoice` (P5's `library.json`) gains `version` and `environment`. `SetupDefaults` (Settings > Compatibility > New Games) fills what a game has not chosen. `GameSetupResolver` turns a choice into what this Mac can run and lists every problem (runner gone, invalid pair, FEX unavailable, refused variable).
- **Valid pairs.** `BackendSupport`: CrossOver serves DXMT, DXVK and wined3d, and D3DMetal only where its clone has `lib64/apple_gptk/external/D3DMetal.framework` and only with Rosetta. A Wine build serves wined3d, DXVK once downloaded, DXMT once downloaded and only on a Wine built from CodeWeavers' sources (DXMT's guide: a stock Wine lacks the winemac.drv API). Game Porting Toolkit serves D3DMetal only. FEX is offered only where `Runner.flavors` has it, which already excludes it before macOS 26.
- **Steam tools.** `CompatToolList.sync` writes `backend-tools` beside `tools`: one line per runner tool and valid backend, `name<TAB>build<TAB>flavor<TAB>backend<TAB>display`, name `<runner tool>-<backend>`, display `<runner> · <backend>`. The dylib reads it after `tools` (runner tools stay first and stay the default), writes a `backend` file into each pair's folder, and removes it with the rest of an unlisted tool.
- **Launch.** The run script reads `backend` from its tool folder. CrossOver gets `CX_GRAPHICS_BACKEND=<backend>` and loads its own copy; a launch option asking for another backend is replaced and the run log says so. Any other Wine gets Cartouche's pinned DXMT or DXVK first in WINEDLLPATH, `d3d11,dxgi,d3d10core=b` (DXMT) or `d3d9,d3d10core,d3d11,dxgi=b` (DXVK, wined3d) after the launch options' overrides, and DXMT's `winemetal.dll` in the prefix. A backend that is not set up stops the launch with an alert, after the runner check and before the prefix lock. The game's own variables (Metal HUD and the like) come from `setups/<appid>.env`, only the names the game launcher forwards (`D3DM_`, `DXMT_`, `DXVK_`, `MTL_`, `ROSETTA_`), and a launch option with the same name wins.
- **Steam's choice.** The app writes `compat-requests` (`appid<TAB>tool`, empty tool clears, app 0 is Steam's default for other Windows games). The dylib, on Steam's compat queries at most once a second, renames the file, maps each app with the same `SetCompatToolMapping` call the Properties page uses (`np_compat_map_tool`), deletes the file and refreshes the page. The app reads Steam's choices back from `config/config.vdf` > CompatToolMapping and adopts a Cartouche pair set in Steam, unless its own request is newer.
- **Mac or Windows.** `SteamAppInfo` reads `common/oslist` from `appcache/appinfo.vdf` (v27, v28, v29). A game with both builds gets a Run control (Mac Version, Windows Version). Windows Version asks Steam for the game's pair; Mac Version asks Steam to clear the forced tool. Installed games with both builds read "Mac version" or "Windows version" in the library.
- **Downloads.** `backends.json` pins DXMT v0.80 and DXVK-macOS v1.10.3-20230507-repack by URL, size and SHA-256 (`evidence/pins.txt`). `BackendInstaller` downloads, checks size and SHA-256, deletes a mismatch, checks again before unpacking, moves the folders into `backends/<backend>/` and writes a receipt with every file hash. The run script uses a backend folder only with its receipt. D3DMetal is refused by the manifest check and is never downloadable.
- Shared names (`backend-tools`, `compat-requests`, `backends`, `setups`) are in `cartouche_identity.h`; tests compare the app, the dylib and the run script against them.

## Per-game setup / Backend is applied at launch

- Check: command `make -s backendcheck` → `evidence/backendcheck.txt`.
- Result: pass. For a CrossOver tool with backend file `dxmt`: `CX_GRAPHICS_BACKEND=dxmt`, WINEDLLPATH holds only CrossOver's `lib/wine` folders, no override, log line `graphics: dxmt from CrossOver's own copy`. The same for d3dmetal, dxvk and wined3d. A launch option `CX_GRAPHICS_BACKEND=d3dmetal` is replaced by the tool's `dxmt` and the log names both. For a non-CrossOver Wine with DXMT downloaded: WINEDLLPATH starts `backends/dxmt/x86_64-windows:…/i386-windows:…/x86_64-unix:` before the runner's own folders, overrides end `d3d11,dxgi,d3d10core=b`, and no DXVK folder is on the path. Without the download, the launch is refused. Without a receipt, the folder is not used.
- Check: `make -s compatcheck` case "a pair's directory names its backend for the run script" (the dylib writes `backend` = `dxmt\n`, the same `build` and `flavor` as the runner tool).
- Check: tests `GameSetupTests` (the resolved backend is the one the pair carries) and `SteamCompatChoiceTests.bothDirections` (each of the 10 pairs maps back to itself).
- Result: the configuration side passes. **Needs maintainer** for the game log (task 2.2 left unticked):
  1. Build and install this branch (`make app`, open `out/Cartouche.app`, Steam Play Setup > Install), with CrossOver 26.3 set up and its clone carrying `lib64/apple_gptk`. Quit and restart Steam.
  2. In Steam, Properties > General > Launch Options of a DirectX 11 game (for example Unturned, app 304930, free): `WINEDEBUG=+loaddll %command%`.
  3. In Cartouche, set the game to CrossOver 26.3 · DXMT and launch it from Steam. Quit it.
  4. `grep -i 'd3d11' "$HOME/Library/Application Support/Cartouche/launchers/304930/cartouche-wine.log"`. Expected: the `Loaded L"…d3d11.dll"` line points into CrossOver's DXMT folder (`…/CrossOver/lib/dxmt/…` or its builtin path), and no line loads `apple_gptk` or a DXVK `d3d11.dll`. `grep graphics: <steamapps>/compatdata/304930/cartouche-run.log` shows `graphics: dxmt from CrossOver's own copy`.
  5. Repeat with D3DMetal (expect `apple_gptk`), DXVK and wined3d. Save the four grep outputs as `evidence/loaddll-<backend>.txt`.

## Per-game setup / Invalid pairs are not offered

- Check: test `SetupMenuTests.graphicsMenu` ("On a runner without D3DMetal the Graphics menu leaves it out; with it, D3DMetal comes first").
- Result: pass. Graphics submenu titles on CrossOver 26.3 without D3DMetal: `["DXMT", "DXVK", "wined3d"]`. With it: `["D3DMetal", "DXMT", "DXVK", "wined3d"]`, D3DMetal checked.
- Check: test `SetupMenuTests.translation` ("FEX is offered only by a runner that serves it, so never on macOS 15").
- Result: pass. The 41073 FEX build as macOS 15 lists it (`fexAvailable: false`): translations `[rosetta]`. On macOS 26: `[rosetta, fex]`, and with FEX picked, D3DMetal is not in the Graphics choices.
- Check: tests `GameSetupTests.noD3DMetal`, `noD3DMetalOnFEX`, `noFEXOnSequoia`, `wineBuilds`, `toolkit`: a stored invalid choice falls back to the first valid backend or Rosetta and the problem is reported (`backendUnavailable(.d3dmetal)`, `translationUnavailable(.fex)`).
- Screenshots: `evidence/setup-no-d3dmetal-light.png`, `-dark.png` (Runner CrossOver 26.3 Rosetta, Graphics DXMT, no Translation control because 26.3 has no FEX build), `evidence/setup-windows-version-*.png`.

## Steam compatibility tools per setup / Tools appear in Steam

- Check: test `SteamToolPairTests.everyValidPair` ("Two runners and their backends give every valid pair…"). Fixture: CrossOver 26.3 (with D3DMetal) and the 27.0.0.41073 FEX build (without).
- Result: pass. `backend-tools` holds exactly 10 lines, in the runner tools' order: `cartouche-proton-fex-41073-{dxmt,dxvk,wined3d}` ("CrossOver 2026 10 15-ARM64 - FEX · DXMT" …), `cartouche-proton-fex-rosetta-41073-{dxmt,dxvk,wined3d}`, `cartouche-proton-26.3-{d3dmetal,dxmt,dxvk,wined3d}` ("CrossOver 26.3 · D3DMetal" …). `tools` still has its 3 runner tools, byte for byte as before (`SteamToolListTests` unchanged and passing).
- Check: test `SteamToolPairTests.noClash`: every pinned build with every backend gives unique names, none equal to a runner tool, all starting `cartouche-proton`, none containing `notproton` (`CARTOUCHE_OTHER_STEAM_PREFIX`), names under 64 bytes and displays under 96 (the dylib's limits).
- Check: test `SteamToolPairTests.sequoia`: on macOS 15 the FEX tools have no pairs.
- Check: `make -s compatcheck` "backend list" cases: the dylib keeps 4 well-formed pairs after the 2 runner tools and skips an unknown backend, a 4-field line, a pair that takes a runner tool's name and a foreign name; the runner tool stays the default; `compatibilitytool.vdf` of a pair says `"display_name" "CrossOver 26.3 · DXMT"`; an unlisted pair's folder is removed whole, `backend` file included.
- Result: pass. **Needs maintainer** for Steam's own menu (task 3.1 left unticked): with two CrossOver builds set up (for example 26.3 and a Preview), Steam Play Setup > Install, quit and restart Steam, open any Windows game's Properties > Compatibility, tick "Force the use…", open the list. Expected: every pair of `~/Library/Application Support/Cartouche/backend-tools`, named "<runner> · <backend>", next to the runner tools; nothing named notproton. Save `evidence/steam-compat-menu.png`.

## Steam compatibility tools per setup / Cartouche and Steam agree

- Check: test `SteamCompatChoiceTests.eldenRing` ("Elden Ring set to 26.3 with D3DMetal in Cartouche asks Steam for that pair; Steam's later choice shows in Cartouche").
- Result: pass. After `setSetup(runner 26.3, D3DMetal)` on `steam:1245620`, `compat-requests` reads `1245620\tcartouche-proton-26.3-d3dmetal\n` in the library's folder, nothing in Steam's folders. A config.vdf that still says wined3d does not undo it while the request is pending, nor after the dylib consumed it if config.vdf is older than the request. Once config.vdf says `cartouche-proton-26.3-dxvk` and is newer, Cartouche shows DXVK and sends nothing back.
- Check: `make -s compatcheck` "request" cases (the dylib side): 4 well-formed lines applied through the client's mapping function with the per-app priority (250) or, for app 0, the global one (75); an empty tool clears; a non-Cartouche tool, a bad appid and a line without a tab are skipped; the file is consumed so Steam's later choice is not overridden; with the mapping function missing nothing is applied and the file stays.
- Check: tests `SteamCompatChoiceTests.requestFile`, `readsConfig`, `bothDirections`, `defaultsReachSteam`.
- Not literally testable yet: "Game Porting Toolkit · D3DMetal". The Game Porting Toolkit runner is listed but not offered to Steam until its Wine is pinned (P2's `Runner.isOffered`), so no GPTK pair exists. The same path is tested with "CrossOver 26.3 · D3DMetal".
- **Needs maintainer**: with this build installed and Steam restarted, set Elden Ring (1245620, or any Windows game you own) to CrossOver 26.3 · D3DMetal in Cartouche. Within a second of Steam's next compat query (open the game's Properties), Properties > Compatibility shows "CrossOver 26.3 · D3DMetal" forced. Launch from Steam: `compatdata/1245620/cartouche-run.log` has `graphics: d3dmetal from CrossOver's own copy`. Save `evidence/elden-ring-properties.png` and the log line.

## Mac or Windows version / Switch to the Windows version

- Check: test `SetupMenuTests.switchVersions` ("Switching to the Windows version asks Steam for the pair; back to the Mac version clears it").
- Result: pass. Cyberpunk 2077 (1091500) with a Mac build: picking Windows Version writes `1091500\tcartouche-proton-26.3-dxmt` (no D3DMetal in that fixture) and the library reads "Windows version".
- Check: tests `SteamAppInfoTests.macBuilds` (v27, v28, v29 caches: 1086940, 1091500 and 367520 have both builds; 1245620 Windows only; no oslist is Windows; a Mac-only app has no Windows version to pick; a depot's oslist is not the game's), `refusals`, `fromFile`, `libraryShowsVersion`; `SetupMenuTests.macVersion` (Runner and Graphics menus disabled for the Mac version, enabled for Windows).
- Screenshots: `evidence/setup-mac-version-*.png`, `evidence/setup-windows-version-*.png`.
- **Needs maintainer** (task 4.2 left unticked): pick a game you own with a macOS build (for example Hollow Knight, 367520). In Cartouche pick Windows Version. Expected: Steam shows "Update queued" or downloads, `steamapps/appmanifest_367520.acf` lists a Windows depot under InstalledDepots (its oslist is windows in `steamcmd +app_info_print 367520`), the game launches through Wine (`compatdata/367520/cartouche-run.log` exists with `=== launching`), and the library card reads "Windows version". Save the manifest excerpt and a screenshot.

## Mac or Windows version / Back to the Mac version

- Check: test `SetupMenuTests.switchVersions`.
- Result: pass. Picking Mac Version again writes `1091500\t` (empty tool, which the dylib maps to no tool: `compatcheck` "an empty tool clears the forced tool"), and the library reads "Mac version". `GameSetupApplier.apply` removes `setups/1091500.env` for the Mac version (`SteamCompatChoiceTests.environmentFile`).
- **Needs maintainer**: on the same game pick Mac Version. Expected: Properties > Compatibility no longer forces a tool, Steam downloads the macOS depot and `appmanifest_367520.acf` lists it, the game starts with no new `=== launching` line in `cartouche-run.log`.

## Pinned backends / Backend download is verified

- Check: test `BackendInstallerTests.tampered` ("A DXMT download whose SHA-256 differs is deleted and nothing is unpacked").
- Result: pass. Failure detail `The download was damaged. Try again.`; downloads folder empty; backends folder empty; nothing installed.
- Check: tests `installDXMT` (the receipt holds the archive SHA-256 and every file's hash, `backends/` holds only `dxmt`), `swappedBeforeUnpack` (an archive changed after the check is deleted and never unpacked), `missingFiles`, `installDXVKOldLayout` (`x64`/`x32` land in `x86_64-windows`/`i386-windows`), `damage` (a changed byte is named; installing again repairs), `shipped`, `refusals` (D3DMetal, an uppercase hash, another host, a path outside the backend folders, a duplicate).
- Check: command `sh evidence/pins.sh` → `evidence/pins.txt`: GitHub's API digest and size for `dxmt-v0.80-builtin.tar.gz` (18681669 bytes, `8f260e36…a264529d`, DXMT's latest release, published 2026-04-23) and `dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz` (2785833 bytes, `810b1e5c…3ef6f00`, Gcenx's latest, 2024-07-23). Licenses at those tags: DXMT v0.80 MIT (the release notes say v0.80 is the last MIT release, later ones are LGPL), DXVK-macOS zlib/libpng.
- Check: the run script uses a backend folder only with its receipt (`backendcheck` "a backend folder without its receipt is not used"), and only `BackendInstaller` writes a receipt, after the SHA-256 check. So DXMT reaches a prefix (`winemetal.dll`) only from a verified download.
- Check: `make -s redistscan` and `sh packaging/redist-scan.sh out/Cartouche.app`: pass. D3DMetal is never downloadable (`BackendManifest.downloadable` is DXMT and DXVK; `refusals`).
- Result: pass. **Needs maintainer**: the archive layout is not confirmed (nothing was downloaded here). In Settings > Compatibility > Graphics Backends click Download on DXMT 0.80. Expected: "Ready", and `~/Library/Application Support/Cartouche/backends/dxmt/` holds `x86_64-windows/{d3d11,dxgi,winemetal}.dll` and `x86_64-unix/winemetal.so` with `.cartouche-backend.json`. If it says the download does not hold the expected files, run `tar -tzf` on the archive and adjust `files` in `backends.json` (or `BackendInstaller.aliases`). The same for DXVK.

## Acceptance (task 5.1)

- `openspec validate p3-graphics-backends --strict` and `openspec validate --all --strict`: 19 passed, `Change 'p3-graphics-backends' is valid`.
- Docs for the docs agent: TRD (P3 section, data stores `backend-tools`, `compat-requests`, `backends/`, `setups/`), THIRD-PARTY-LICENSES (DXMT v0.80 MIT, DXVK-macOS zlib, both downloaded, not bundled), GLOSSARY (pair, backend tool). `docs/research/graphics-backends.md` holds the research.
- Task 5.1 stays unticked until the maintainer evidence above is in.
