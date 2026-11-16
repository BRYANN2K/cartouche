# Cartouche 0.1.3: stable console hotfix for issues #23 and #24

Target release: `v0.1.3`. The application and bundle version are `0.1.3`; the changelog has a dedicated release section. Steam integration keeps its independent `0.1.2-1` version because its payload is unchanged. No tag or release has been published by this preparation.

Base: public `v0.1.2`, peeled commit `632437defd10f96dec4cd734bd21de8869a1ec76`, also public `main` when checked on 2026-11-16. Work is isolated on `fix/0.1.2-console-issues`; no beta or development changes are included.

## #23: missing default RetroArch and opaque error

The actual public `Cartouche-0.1.2.zip` was downloaded from the release. SHA-256: `c6b6960e702bc3710f0c9ff621dc04a2a6c77a6bd4ea7e6c9db27fc5e23fe47a`, matching the GitHub asset digest. It has no `Contents/Helpers/RetroArch.app/Contents/MacOS/RetroArch`.

`SettingsWindow.swift` selects that bundled path by default. `ConsolesSettingsModel.launcher` returns nil when its probe finds no executable. `ConsoleCenter.makeRunner` then returns nil, and `ConsolePlay.swift` throws `RetroArchSessionError.notRunning`. On this Swift toolchain, bridging that exact enum case to NSError yields code **4** (payload cases get the earlier codes). This reproduces a concrete route to the reported error; the reporter's own logs and setup were not supplied.

`make app` now builds, embeds, signs and checks the pinned RetroArch, requiring its executable, matching commit and MCP support. Both Woodpecker build pipelines and the GitHub app workflow initialize its submodule and provide the Metal toolchain. These changes cover the real stable release path as well as app CI. Every session error now has a localized description; command failures preserve RetroArch's reason and show the session log path. A missing session directs the user to Settings > Consoles.

## #24: BIOS policy follows the actual core

SwanStation recognizes OpenBIOS from `OpenBIOS` at offset `0x78`, not an MD5. Cartouche checks that signature and a 512 KiB regular file, and scans the BIOS directory under the filename the user supplied, including `scph5501.bin`. It does not mark arbitrary data or a truncated header as valid. The other supported PlayStation firmware filenames in the selected core's info are accepted too.

The BIOS check now takes the selected core (including a netplay override), and its cache includes that core and the core-info directory stamp. PCSX ReARMed may use its built-in HLE BIOS; Beetle keeps its external BIOS requirement. The panel reloads its BIOS result when the selected core changes. A rejected known BIOS reports its expected MD5; the SwanStation warning explains how to place OpenBIOS without renaming it.

Upstream evidence checked:

- https://github.com/libretro/swanstation/blob/main/src/core/bios.cpp (`GetImageInfo`, signature at 0x78).
- https://github.com/libretro/swanstation/blob/main/src/core/host_interface.cpp (`FindBIOSImageInDirectory`, scans filenames).
- https://github.com/libretro/pcsx_rearmed/blob/master/frontend/libretro.c (HLE BIOS support).

## Validation

- RetroArchKit: **174 tests in 28 suites passed** with the real RetroArch app produced by CI and a test core. The two independent CI builds name the pinned commit. A local embed/signature check and two explicit real-runtime launch/stop tests pass too.
- App build and **3 integration tests passed**: the missing-runtime error-4 path for Game Boy/DS, selected-core and netplay BIOS rules, and propagation of command errors with log location.
- RetroArchKit translations: **92 strings** checked in French, Italian and Simplified Chinese.
- App translations: **1720 strings** checked in those three languages.
- GitHub workflow structural checker: **9 workflows** parse and are wired.
- Woodpecker app/release YAML and all their shell commands parse.
- The existing `check-retroarch.sh` rejects the downloaded public bundle because the RetroArch executable is missing, as expected.
- `git diff --check` passes.

The initial complete suite exposed inherited UI capture failures and a stale Switch-emulator expectation. Captures now use an attached invisible window and the fast text recognition model supported on hosted Mac VMs; the expectation follows the existing Eden default. All 174 tests then passed. The isolated embed workflow uses a minimal host fixture; the app workflow checks the complete product. Named app/lint gates match the existing protected-branch requirements without weakening them. A complete signed release build and real Chrono Cross / Chrono Trigger / Tetris sessions remain separate validation steps.

The signing check also verifies that re-signing keeps RetroArch’s JIT entitlement and hardened-runtime flag. A disposable signing-certificate test passes. Hosted-runner diagnostics showed accurate OCR failing across all request revisions and image input types, while fast OCR recognized the same image; RetroArch UI assertions are retained using the supported mode. App UI tests additionally use test-only Tesseract for small text and exact punctuation, combined with fast Vision for filled buttons. OCR merges use maximum occurrence counts so two readers cannot count one control twice. The isolated Steam-library export fixture now supplies the Downloads subscriptions required by its injected worker; its refusal and backoff assertions remain unchanged. The panel-behavior suite passes locally.

The complete native app run exercised 1,684 tests in 236 suites. Its 13 initial failures were confined to obsolete toolkit fixtures and OCR: toolkit setup fixtures now use stable 4.0 (no update notice from the bundled 4.0b3 catalog), the expected Apple download URL follows the existing source, and block OCR also reads disabled filled buttons. All 61 targeted tests subsequently passed. The shell toolkit fixture includes the Windows graphics DLLs required by its existing launch script. DMG wording checks ignore case, including the README heading “Install script”. Disk-image fixture creation reports its exit status and retries transient hosted-service failures without retrying installation assertions.
