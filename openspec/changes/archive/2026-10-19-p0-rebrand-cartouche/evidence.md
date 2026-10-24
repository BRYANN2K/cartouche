# Evidence: p0-rebrand-cartouche

Branch `phase/p0-rebrand-cartouche`. Machine: Apple silicon, Xcode 27.0, Swift 6.4, with NotProton installed and configured (its `~/Library/Application Support/notproton` holds 63 files, and `/Applications/Steam.app` carries its `notproton.dylib`) and Steam running.

The local app bundle is built with `make -o app-payload app`: the real build minus the payload, which needs Dobby and the Wine bridge built in CI.

## Tests

| Suite | Before (main 0976c0b) | After |
|---|---|---|
| `make -s app-tests` | 538 tests, 34 fail (43 issues) | 554 tests, the same 34 fail (43 issues) |
| Hermetic C suites from `app.yml` (19), plus `runcheck`, `scriptcheck` | 21 pass | 21 pass |
| `make -s l10ncheck` | not run | 433 strings, all translated |

- The 34 failing Swift tests are in "appinfo tool", "Install payload" and "Steam installer". They all need the staged payload ("This build carries no components at all"), on main and on this branch alike. The list of failing test names is identical before and after.
- The 16 new tests are in `IdentityTests.swift` ("App identity", 11) and `CoexistenceTests.swift` ("Coexistence with NotProton", 5), under `app/Tests/NotProtonAppTests/`.
- Every dylib source also compiles (`make out/dylib/<file>.o` for each file in `SRCS`). Linking the dylib needs Dobby, which is built in CI only.
- `runcheck` and `scriptcheck` skip because shellcheck is not installed here.
- No test was deleted or skipped. Tests whose expected paths or strings changed with the rename were updated: `DetectionTests` (support paths), `PrefixToolsTests` (run script paths), `SteamInstallerTests` ("newer Cartouche", the refusal message), `TemplateCleanupTests`, `UninstallTests` and `RunnerSwitchTests` (template folder and tool names), and the C, shell and JS fixtures that carry the Steam-side names (`compatcheck.c`, `gatecheck.c`, `panel-behavior/*.js`, `library-filter/behavior.js`, `settingscheck.sh`, `envcheck.sh`, `bridgecheck.sh`, `seedcheck.sh`, `buildcheck.sh`, `shortcut-launch.py`, `delivery.m`).

## Scenarios

### Distinct identity / Built app reports its identity
- Check: command `defaults read "$PWD/out/Cartouche.app/Contents/Info" CFBundleIdentifier` and `… CFBundleName`; command `codesign -dv out/Cartouche.app`; test `IdentityTests.bundleIdentity`
- Result: pass, `dev.bryann2k.cartouche` and `Cartouche`. codesign reports `Identifier=dev.bryann2k.cartouche`. CFBundleDisplayName and CFBundleExecutable are also `Cartouche`.

### Distinct identity / No leftover NotProton strings
- Check: test `IdentityTests.catalogIsRenamed` (no "NotProton" in `Localizable.xcstrings`, any case); test `IdentityTests.onlyAttributionNamesNotProton` (no string literal containing "NotProton" in any app Swift file except `Support/Attribution.swift`); screenshot `evidence/main-window.png`
- Result: pass. The only app text naming NotProton is `Attribution.swift` (About window). In the repository, README.md credits it in Credits and License, NOTICE and the LICENSE header too.
- Internal name kept on purpose, not shown in the app's UI: the Swift package, target and module `NotProtonApp`, test target `NotProtonAppTests`, resource bundle `NotProtonApp_NotProtonApp.bundle`. Renaming moves ~60 files and every `@testable import`. The binary in the bundle is named `Cartouche`. Every other `notproton` name in code is renamed (see "Leaves NotProton untouched").

### Separate data / Fresh install creates its own folders
- Check: command `sh snapshot.sh` before and after a first launch. It lists `stat -f '%Fm %Fc %z %N'` for every file under `~/Library/Application Support/notproton`, `~/Library/Caches/notproton`, `~/Library/Preferences/com.notproton.NotProton.plist` and NotProton's template cache. Then `open out/Cartouche.app`, wait 8 s, quit, run the snapshot again, `diff`. Before the launch, `~/Library/Application Support/Cartouche` and `~/Library/Logs/Cartouche` did not exist.
- Result: pass. `diff` is empty for all 63 entries: no mtime, ctime or size changed. Re-run after the Steam-side rename, with `/Applications/Steam.app/Contents/MacOS/notproton.dylib`, `/Applications/Steam.app/Contents/Info.plist` and `compatibilitytools.d` added to the snapshot: `diff` is empty for all 66 entries. After the launch, `~/Library/Application Support/Cartouche` exists, and `~/Library/Logs/Cartouche/app.log` starts with `--- Cartouche 1.2.0 started ---`. This was run on this Mac, where NotProton is installed and configured and Steam is running.
- Check: tests `IdentityTests.appAndDylibShareTheRoot`, `runScriptSharesTheRoot`, `scriptsShareTheRoot`, `SupportPathTests.pathsAreStable`
- Result: pass. The folder name is defined once in `app/Sources/CartoucheIdentity/include/cartouche_identity.h` (`CARTOUCHE_DIR_NAME "Cartouche"`). The app imports it as a C module (`SupportPaths.supportDirName = CARTOUCHE_DIR_NAME`), and the dylib compiles against it (`-I$(IDENTITY_INC)`). `strings` on the compiled `file.o` shows `Library/Application Support/Cartouche` and `Library/Logs/Cartouche`. The run script and the build scripts cannot include a header: the tests check that the run script's `np_support` matches the header, and that no source or script names an Application Support folder other than Steam, CrossOver or Cartouche.
- Note: the prefix template cache in Steam's compatdata is renamed `cartouche-template`. Each launch removes templates the app does not recognize there, so the old name would have deleted NotProton's templates.

### Leaves NotProton untouched / Remove Everything leaves NotProton untouched
- Check: tests `CoexistenceTests.removeEverythingLeavesNotProton` and `CoexistenceTests.removeEverythingTakesOnlyCartouche`. The fixture is a real signed Steam.app with NotProton's compiled `notproton.dylib` injected (insert entry and controller key in the outer and inner plists), NotProton's `notproton` and `notproton-fex` tools, a game prefix with `notproton-run.log` and `notproton-build`, NotProton's template cache, `legacycompat` and `steam.cfg` with the update block. The tests hash every one of those files before and after `Uninstall.run`.
- Result: pass. Every hash is identical after Remove Everything, and both plists' environments are unchanged. The Steam restore is never called, and the outcome reports `leftSteamForOtherTool`. Cartouche's `cartouche-proton-26.3` tool and its folder are removed. In the second test, Steam also carries `cartouche.dylib` next to NotProton's. Remove Everything deletes `cartouche.dylib` and takes its entry out of both inserts, leaving exactly NotProton's path. The controller key stays, the hashes still match, and `codesign --verify --strict` passes on the re-signed bundle.
- Check: test `CoexistenceTests.clearInsertKeepsOtherEntries`
- Result: pass. Clearing the insert removes only Cartouche's entry. A second call changes nothing, because NotProton's entry is not Cartouche's to clear.
- Install: `SteamInstaller.run` refuses before changing anything when Steam already loads another dylib, by insert entry or by NotProton's file in `Contents/MacOS`. Test `SteamInstallerTests.refusesForeignInsert` checks the new message, but it is one of the 34 tests that need the staged payload, so it runs in CI only.

### Leaves NotProton untouched / Repair refuses a Steam that NotProton injects
- Check: test `CoexistenceTests.repairRefusesNotProton`
- Result: pass. `SteamRepair.run` throws "Steam also loads another tool's dylib (<path to notproton.dylib>). Repair Steam would remove it, so Steam was left as it is. Remove that tool from Steam first." Steam is not stopped and the downloads folder is never created. The hash of every file in the bundle, the inner plist and `steam.cfg` is unchanged. `CoexistenceTests.detectsNotProton` shows NotProton's dylib is detected even when no insert loads it.

### Leaves NotProton untouched / Steam-side names come from one place
- Check: tests `IdentityTests.steamNamesShareTheHeader` and `IdentityTests.noNotProtonSteamNames`; the C suites build against the header
- Result: pass. `cartouche_identity.h` defines:
  - `CARTOUCHE_STEAM_PREFIX "cartouche"`, for the prefix files `cartouche-run.log`, `-build`, `-msync`, `-game-drive`, `-hidden-controllers` and `-disable-hidraw`, the template cache, the run-script marker and the `cartoucheWindows` filter key.
  - `CARTOUCHE_TOOL_PREFIX "cartouche-proton"`, for the compatibility tools.
  - `CARTOUCHE_DYLIB_NAME "cartouche.dylib"`.
  - NotProton's names, for detection only.
- The app reads these through `SupportPaths`, `compat.c` and `compatsvc.h` through the header, and the Makefile through `$(call identity,…)`. The run script and `webpatch.c` carry copies, checked by the test. Launch option variables are `CARTOUCHE_*` (`CARTOUCHE_RAW_CONTROLLERS`, `CARTOUCHE_DISABLE_HIDRAW`, `CARTOUCHE_RETINA`, `CARTOUCHE_HIDE_LAUNCHER_TILE`, `CARTOUCHE_OVERLAY_SHIM`, `CARTOUCHE_LOG_LEVEL`). No C, shell, Python, JS or Swift file outside the header and `Attribution.swift` contains `notproton`, except the `NotProtonApp` module name.
- Note: tool names must contain "proton". The client maps Cloud save paths into the prefix only for such tools (comment in `compat.c`, test `DetectionTests.namesParse`). So the tools are `cartouche-proton`, `cartouche-proton-fex`, `cartouche-proton-26.3` and so on, not `cartouche-*`.
- Not checked here: two dylibs loaded into one running Steam. Install refuses while another dylib is injected, so this does not happen through the app.

### Own update feed / Feed and key are Cartouche's
- Check: command `defaults read "$PWD/out/Cartouche.app/Contents/Info" SUFeedURL` and `… SUPublicEDKey`; test `IdentityTests.updateFeedAndKey`
- Result: pass. `https://github.com/BRYANN2K/NotProton/releases/latest/download/appcast.xml` and `GQF06ayCCpIxh8XlQPQYWTwbYO2SckfWqr9rYCuJrqI=`. NotProton's key was `rDOXzJ+vt12aWeu9hATgvz6q46MlRcgR4gbTfj5YuWQ=`.
- Note: the host is the fork's GitHub repository, still named `NotProton`. When the repository is renamed, SUFeedURL and this test must change too. GitHub redirects the old URL, but the plist should not rely on that.
- Key: generated with Sparkle's `generate_keys --account cartouche` (it is also kept in the login keychain under that account). The private key was exported to `~/Library/Application Support/Cartouche-dev/sparkle_private_key` (mode 600), outside the repository. The public key derived from that file equals the Info.plist value. `git grep` finds no part of the private key in the repository.

### Own update feed / Foreign update is refused
- Check: command `sign_update --verify --ed-key-file <Cartouche key> archive <signature>` on a test archive, once signed with the Cartouche key and once with a throwaway key
- Result: partial pass. With the Cartouche signature, rc=0. With the foreign signature, "Error: failed to pass signing verification.", rc=1. This proves the key pair, not the runtime behavior.
- Result: pending maintainer for the runtime check. MAINTAINER steps:
  1. Copy a built `Cartouche.app` (version 1.2.0) to `/Applications`.
  2. Make a fake update: copy the app to `~/fake-update/Cartouche.app`, set its version with `/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" -c "Set :CFBundleVersion 9.9.9" ~/fake-update/Cartouche.app/Contents/Info.plist`, re-sign it with `codesign -fs - ~/fake-update/Cartouche.app`, zip it with `ditto -c -k --keepParent ~/fake-update/Cartouche.app ~/fake-update/Cartouche-9.9.9.zip`, then delete the `.app`.
  3. Sign it with a foreign key: `head -c 32 /dev/urandom | base64 > /tmp/foreign_key`, then `app/.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file /tmp/foreign_key --download-url-prefix http://127.0.0.1:8000/ ~/fake-update`.
  4. Serve it: `python3 -m http.server 8000 --directory ~/fake-update`.
  5. Point the installed app at it: set `SUFeedURL` to `http://127.0.0.1:8000/appcast.xml` in `/Applications/Cartouche.app/Contents/Info.plist`, add `NSAppTransportSecurity` > `NSAllowsLocalNetworking` = true, then `codesign -fs - /Applications/Cartouche.app`.
  6. Launch it and choose Cartouche > Check for Updates…, then Install Update.
  7. Expected: Sparkle shows that the update is improperly signed and could not be validated. `defaults read /Applications/Cartouche.app/Contents/Info CFBundleShortVersionString` still prints `1.2.0`. Record the log line from `log show --last 10m --predicate 'process CONTAINS "Cartouche" OR process CONTAINS "Autoupdate"' | grep -i -E "signature|EdDSA"`.
  8. Delete the test copy, the fake update folder and `/tmp/foreign_key`.

### Attribution and licensing / Attribution is present
- Check: test `IdentityTests.repositoryAttribution` (README.md and NOTICE contain the NotProton link, "GNU General Public License version 3 (GPL-3.0)" and the exact non-affiliation sentence; LICENSE starts with the Cartouche header above the unchanged GPL text); test `IdentityTests.aboutCredits` (the About window text)
- Result: pass for README.md, NOTICE and LICENSE. The About window shows `Attribution.credits`: the credit with the NotProton link, the GPL-3.0 notice, and "Cartouche is an independent project. It is not affiliated with NotProton, Valve, Apple or CodeWeavers." The menu item "About Cartouche" opens the standard About panel with these credits. They stay in English in every language.
- Result: pending maintainer for the About screenshot. Opening the menu needs a click, which was not automated. MAINTAINER steps: launch `out/Cartouche.app`, choose Cartouche > About Cartouche, check that the three paragraphs show, and save a screenshot as `evidence/about.png`.

### App icon / Icon appears in Finder and Dock
- Check: command `xcrun assetutil --info out/Cartouche.app/Contents/Resources/Assets.car`; a Swift check loading `MenuBarGlyph` from the built bundle; file `out/icon-src/Cartouche.iconset/icon_256x256.png`
- Result: pass for the build. Assets.car has the `Cartouche` icon stack for `NSAppearanceNameAqua` (layer `cartridge-default`, light gradient) and `NSAppearanceNameDarkAqua` (layer `cartridge-dark`, dark gradient). `Cartouche.icns` is built with `iconutil` from `cartouche-icon-default.svg`. Info.plist has `CFBundleIconName` and `CFBundleIconFile` set to `Cartouche`. `MenuBarGlyph` loads with `isTemplate == true` as a vector.
- Result: pending maintainer for the visual check. MAINTAINER steps: copy `out/Cartouche.app` to `/Applications`. Check that Finder (icon view) and the Dock show the cartridge icon after launch. Switch System Settings > Appearance to Dark, with the icon style set to Dark on macOS 26, and check that the dark variant shows. Save `evidence/icon-light.png` and `evidence/icon-dark.png`. macOS 15 has no dark app icons, so there the Default icon shows in both modes.
- Note: the app has no menu bar status item yet. The glyph ships as a template image ready for one (mockup/AUDIT.md plans a status icon). The "template glyph in the menu bar" part of the requirement cannot be seen until a phase adds that item.
