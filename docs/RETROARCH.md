# RetroArch in Cartouche

How Cartouche gets the RetroArch it ships, how it runs it, and how to move it to a newer commit. Read by contributors and the release maintainer. The decision behind it is ADR 0008.

## Pinned commit

| | |
|---|---|
| Submodule | `vendor/RetroArch` |
| Upstream | https://github.com/libretro/RetroArch |
| Commit | `ed3187ec8e1fe55145366789718dc77f34abaeca` (master, 2026-10-19) |
| Version it reports | 1.22.2, plus `(Git ed3187e)` |
| License | GPL-3.0-or-later (`vendor/RetroArch/COPYING`) |

The commit has the MCP server: `network/mcp_server.c`, `docs/mcp-server.md` and the `--mcp-stdio` flag in `retroarch.c`. Stable 1.22.2 does not.

The Apple Xcode project does not define `HAVE_MCP`. `retroarch/xcode/Cartouche.xcconfig` adds it on top of upstream's `GitHubCI.xcconfig`. The deployment target is set to macOS 15 on the command line: Xcode 27 refuses the project's 10.13, and the xcconfig does not reach the project level where it is set.

## How it is built

- CI only: `.github/workflows/retroarch.yml`. Nothing built is committed.
- `make retroarch` runs `retroarch/scripts/build-retroarch.sh`: `xcodebuild` on `pkg/apple/RetroArch.xcworkspace`, scheme `RetroArch`. It refuses a submodule that is not at the pin or has local changes.
- `retroarch/scripts/check-retroarch.sh` then requires `--version` to name the pinned commit and `--help` to offer `--mcp-stdio`.
- `make retroarch-embed` copies RetroArch.app into `Cartouche.app/Contents/Helpers/` and signs it, nested code first, with `APP_SIGN_ID` (ad hoc until P9 brings the Cartouche certificate). Entitlements are kept: RetroArch needs `disable-library-validation` to load downloaded cores.
- The job builds twice from clean, checks both, and reports whether the two executables are byte-identical. They are not expected to be: the binary carries `__DATE__` and build paths.
- The Xcode build needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- `make retroarch-rig` builds a command-line RetroArch from the same commit with `./configure` and no Metal, for the tests. `make retroarch-testcore` builds the small libretro core the tests load (`retroarch/Tests/testcore`, never shipped).

## How Cartouche runs it

- Started with `--mcp-stdio`, `-c <root>/retroarch.cfg` and `--appendconfig <root>/cartouche.cfg`, where `<root>` is Cartouche's RetroArch folder.
- `retroarch.cfg` there is the included RetroArch's own. The user's `~/Library/Application Support/RetroArch/config/retroarch.cfg` is never read or written. RetroArch saves its config file by itself at times (after unpacking its assets, for example) whatever `config_save_on_exit` says, so it must not be the user's.
- Cartouche makes that `retroarch.cfg` before the first launch: RetroArch ignores `--appendconfig` when the `-c` file is missing.
- `cartouche.cfg` is rewritten before each launch. It turns off `config_save_on_exit` and `confirm_quit`, and points cores, core info, BIOS, saves, states, screenshots, playlists, logs, recordings, thumbnails, cache, menu config and unpacked assets under `<root>`, so nothing is shared with the user's own RetroArch.
- Stopping closes the pipe: RetroArch quits through its own Quit path and writes the auto save state. After 2.4 seconds it gets SIGTERM, then SIGKILL. macOS RetroArch writes nothing on SIGTERM.
- A build without MCP (an official release before the MCP server, or the user's own copy) gets `-L <core> <file>` on its command line, and is asked `GET_STATUS` and told `QUIT` on its UDP command port.

## Cores and BIOS

- Cores are never bundled. Cartouche downloads them per console from the libretro buildbot (`nightly/apple/osx/arm64/latest/<core>_libretro.dylib.zip`), takes only the named member out of the archive, and records size and SHA-256 at first download. Each launch checks them again.
- Each core's `.info` file comes from the buildbot's `assets/frontend/info.zip`.
- BIOS files are named with their MD5, from each core's `.info` file. PlayStation needs one region's BIOS and names `scph5501.bin` when none is there. Cartouche never links to a BIOS or game download.
- `make retroarch-scancheck` fails when git holds a RetroArch binary or a libretro core.

## Tests

- `make retroarch-tests` runs RetroArchKit's tests. Without a RetroArch build, the tests that run one are skipped and the rest use `fake-retroarch`.
- With `CARTOUCHE_RETROARCH` and `CARTOUCHE_TEST_CORE` set (from `make retroarch-rig retroarch-testcore`), the MCP contract and integration tests run too. `CARTOUCHE_RETROARCH_VIDEO=gl` opens a window. `CARTOUCHE_NETWORK_TESTS=1` adds the test that downloads the real Snes9x.
- Those tests run RetroArch with `HOME` in a scratch folder, so they never touch your own RetroArch folders.
- `make retroarch-l10ncheck` checks RetroArchKit's strings are translated.

## Moving to a newer commit

1. `git -C vendor/RetroArch fetch --depth 1 origin <commit>` and `git -C vendor/RetroArch checkout <commit>`.
2. Update the table above.
3. Open a pull request. The RetroArch job builds it, and the live contract test compares `tools/list` at that commit with `retroarch/Tests/RetroArchKitTests/Fixtures/tools-list-ed3187e.json`. When tools change on purpose, capture the new list and rename the fixture.

## Source offer

Cartouche ships RetroArch built from the commit above, unmodified except for build settings. The complete corresponding source is the submodule at that commit, and the release tag of Cartouche records it. Anyone who received Cartouche can get that source from the Cartouche repository, or from upstream at the same commit, under GPL-3.0. Settings > Consoles links to RetroArch's source.
