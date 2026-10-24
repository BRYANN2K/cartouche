# Standalone emulators: bundle IDs, launch arguments, settings folders (P16)

Date: 2026-10-19. Read from each project's own source or documentation; "nc" means not confirmed from a primary source. Cartouche detects and starts these apps. Since the 2026-10-23 import update it can also install pinned official app archives into ~/Applications when the chosen runtime is missing. Emulator settings remain owned by the emulator.

## What `EmulatorCatalog` uses

| Emulator | App | CFBundleIdentifier | Executable | Arguments | Settings folder (macOS) | Consoles |
|---|---|---|---|---|---|---|
| Dolphin | `Dolphin.app` [1] | `org.dolphin-emu.dolphin` [2] | `Dolphin` [1] | `-b -e <file>` [3] | `~/Library/Application Support/Dolphin` [5] | GameCube, Wii |
| PCSX2 | `PCSX2.app` (nc; CMake output name `PCSX2` [6]) | `net.pcsx2.pcsx2` [7] | `PCSX2` [7] | `-batch -- <file>` [8] | `~/Library/Application Support/PCSX2` [9] | PlayStation 2 |
| PPSSPP | `PPSSPPSDL.app` (from the target name [10]; the release is `PPSSPPSDL-macOS-v1.20.4.zip` [11]) | `org.ppsspp.ppsspp` [10][12] | `PPSSPPSDL` [10][12] | `--pause-menu-exit <file>` [13][14] | `~/.config/ppsspp` [15] | PSP |
| Azahar | `Azahar.app` [16] | `org.azahar-emu.azahar` [17] | `azahar` [17] | `<file>` [18] | `~/Library/Application Support/Azahar` [19] | Nintendo 3DS |
| xemu | `xemu.app` [20] | `xemu.app.0` [21] | `xemu` [21] | `-dvd_path <file>` [22] | `~/Library/Application Support/xemu/xemu` (SDL pref path [23]) | Xbox |
| Ryubing | `Ryujinx.app` [24] | `org.ryujinx.Ryujinx` (nc, mirror only [25]) | `Ryujinx` [24] | `<file>` (nc) | `~/Library/Application Support/Ryujinx` ("the equivalent application data folder" [24]; exact path nc) | Nintendo Switch |

Detection matches the bundle identifier first, then the app name (`Dolphin`, `PCSX2`, `PPSSPPSDL`/`PPSSPP`, `Azahar`, `xemu`, `Ryujinx`/`Ryubing`), so a build with another identifier is still found. The version shown is `CFBundleShortVersionString`, else `CFBundleVersion`.

## Why these arguments

- **Dolphin.** `-b, --batch`: "Run Dolphin without the user interface (Requires --exec or --nand-title)". `-e, --exec`: "Load the specified file" [3]. With batch mode, `MainWindow::OnStopComplete` calls `QGuiApplication::exit(0)`, so Dolphin quits when the game stops [4]. There is no full-screen flag; full screen is Dolphin's own setting.
- **PCSX2.** `-batch`: "Enables batch mode (exits after shutting down)". `--`: "Signals that no more arguments will follow and the remaining parameters make up the filename" [8]. `-fullscreen` exists but is not passed: the user's setting decides.
- **PPSSPP.** The first file argument boots, skipping the logo (`UI/NativeApp.cpp`, `bootFilenames[0]`) [13]. `--pause-menu-exit`: "The 'Exit to menu' choice on the pause menu is changed to just 'Exit'", meant "for frontends that also pass a file to launch" [14]. `--fullscreen` "Forces full screen mode, ignoring saved configuration" and is not passed.
- **Azahar.** "Usage: {} [options] <file path>"; `-f, --fullscreen` exists [18]. The game is the last argument. There is no option to quit once the game ends: closing the game returns to Azahar's game list, so the session ends when the user quits Azahar.
- **xemu.** `-dvd_path` overrides the disc path of `xemu.toml` for this run [22]. Closing the window requests a power-off and the process exits [23].
- **Ryubing.** The setup guide names `/Applications/Ryujinx.app/Contents/MacOS/Ryujinx` and documents `--fullscreen` for command-line launches [24]. The game as the last argument follows Ryujinx's usage but was not read from Ryubing's source (its forge refused connections from the research machine). Maintainer check below.

## Game files per console

- GameCube: `iso gcm rvz gcz ciso wia tgc dol`; Wii: `iso wbfs rvz gcz ciso wia wad` (Dolphin's open dialog [4], minus `bin`, `elf`, `m3u`, `json` which other consoles already use).
- PlayStation 2: `iso cso zso mdf` (PCSX2's open dialog [26], minus `bin`, `cue`, `chd`, `elf`, `gz`, which PlayStation, other consoles or other file kinds already use).
- PSP: `iso cso pbp` [12].
- Nintendo 3DS: `3ds cci cxi 3dsx z3dsx zcci zcxi` (Azahar's game list [27], minus `app`, `elf`, `axf`).
- Xbox: `iso xiso` [28].
- Switch: `nsp xci nro` (nc, mirror plist document types [25]).

## RetroArch cores on the buildbot for Apple silicon

Listed on 2026-10-18 [29]: `dolphin`, `ppsspp`, `citra`, `citra2018`, `azahar`, `pcsx2`, `play`. Not listed: `lrps2`. No core exists for Xbox or Switch.

Catalog choice: GameCube and Wii `dolphin`; 3DS `azahar` (also `citra`); PSP `ppsspp`; PlayStation 2 `play` (Play! needs no BIOS file, so the P13 BIOS rule stays PlayStation-only); Xbox and Switch none.

## libretro database and thumbnails

rdb [30] and libretro-thumbnails [31]: `Nintendo - GameCube`, `Nintendo - Wii`, `Sony - PlayStation 2`, `Sony - PlayStation Portable`, `Nintendo - Nintendo 3DS`, `Microsoft - Xbox`. None exists for Switch; the catalog names it `Nintendo - Nintendo Switch`, so identification falls back to the console picker and no cover is found.

## Maintainer checks on real apps

1. With each emulator installed in `/Applications`, open Settings > Consoles: each is listed with its version. Compare with `defaults read /Applications/<App>.app/Contents/Info CFBundleIdentifier`.
2. Ryubing: confirm the identifier above and that `Ryujinx <file>` boots the game directly.

## Sources

1. https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/CMakeLists.txt
2. https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/DolphinQt/Info.plist.in
3. https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/UICommon/CommandLineParse.cpp
4. https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/DolphinQt/MainWindow.cpp
5. https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/Common/CommonPaths.h
6. https://github.com/PCSX2/pcsx2/blob/master/pcsx2/CMakeLists.txt
7. https://github.com/PCSX2/pcsx2/blob/master/pcsx2/Resources/Info.plist.in
8. https://github.com/PCSX2/pcsx2/blob/master/pcsx2-qt/QtHost.cpp ; https://pcsx2.net/docs/advanced/cli
9. https://github.com/PCSX2/pcsx2/blob/master/pcsx2/Pcsx2Config.cpp
10. https://github.com/hrydgard/ppsspp/blob/master/CMakeLists.txt (`TargetBin PPSSPPSDL`, `MACOSX_BUNDLE_GUI_IDENTIFIER org.ppsspp.ppsspp`)
11. https://github.com/hrydgard/ppsspp/releases (v1.20.4)
12. https://github.com/hrydgard/ppsspp/blob/master/macOS/Info.plist
13. https://github.com/hrydgard/ppsspp/blob/master/UI/NativeApp.cpp
14. https://www.ppsspp.org/docs/reference/command-line/
15. https://www.ppsspp.org/docs/reference/mac/
16. https://github.com/azahar-emu/azahar/blob/master/src/citra_qt/citra_qt.cpp
17. https://github.com/azahar-emu/azahar/blob/master/src/citra_meta/CMakeLists.txt
18. https://github.com/azahar-emu/azahar/blob/master/src/citra_meta/common_strings.h
19. https://github.com/azahar-emu/azahar/blob/master/src/common/common_paths.h
20. https://github.com/xemu-project/xemu/blob/master/build.sh
21. https://github.com/xemu-project/xemu/blob/master/Info.plist
22. https://github.com/xemu-project/xemu/blob/master/system/vl.c
23. https://github.com/xemu-project/xemu/blob/master/ui/xemu.c ; https://github.com/xemu-project/xemu/blob/master/ui/xemu-settings.cc
24. https://github.com/Ryubing/docs/blob/main/docs/guides/setup-guide.md ("Portable Mode", "Launch in Fullscreen")
25. Third-party mirror of Ryujinx's `distribution/macos/Info.plist`, not primary
26. https://github.com/PCSX2/pcsx2/blob/master/pcsx2-qt/MainWindow.cpp
27. https://github.com/azahar-emu/azahar/blob/master/src/citra_qt/game_list.cpp
28. https://github.com/xemu-project/xemu/blob/master/ui/xui/actions.cc
29. https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/
30. https://github.com/libretro/libretro-database/tree/master/rdb
31. https://github.com/libretro-thumbnails


## Import preparation, 2026-10-23

Console imports prepare their runtime before adding new game records, including consoles already present in the library. Installed standalone apps are reused. RetroArch consoles reuse or install their core. Missing standalone apps are downloaded from the pinned emulators.json manifest, SHA-256 checked, unpacked in a staging folder, signature checked and moved into ~/Applications without replacing an existing app. An import failure remains visible and retryable; cancellation leaves the game unimported. Folder imports use the same preparation path. Existing game panels offer Install when their emulator is missing.

Eden is the default for a Switch without an installed/chosen emulator. Existing Ryubing installations and explicit choices are retained. The Ryubing official forge/update endpoints were unreachable during qualification; no third-party executable mirror was substituted. Eden v0.2.1 was resolved through https://git.eden-emu.dev/api/v1/repos/eden-emu/eden/releases/latest and obtained from https://stable.eden-emu.dev/v0.2.1/Eden-macOS-v0.2.1.dmg. Its SHA-256 is 40575fc79a61550fbb9e332cbae94ccd20f5de20ff61b4b60fe1d42f2525c0b5. Its bundle has an empty CFBundleExecutable, so detection falls back to the catalog executable, eden, without changing the signed app. Launch arguments (-g <file>) are documented at https://github.com/eden-emulator/mirror/blob/master/docs/user/CommandLine.md.

Other pins: Dolphin, PCSX2 and xemu URLs/hashes were checked against Homebrew's public cask metadata; PPSSPP and Azahar against their official GitHub release asset digests. Pinned archives are downloaded on demand and are not redistributed in Cartouche.
