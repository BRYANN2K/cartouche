# Proposal

## Why

Installing a game from a Windows installer on a Mac today means running an exe in a Wine bottle and hoping. Multi-part Inno Setup installers with heavy decompression (setup.exe plus .bin parts, unarc.dll, ISDone.dll) fail often and silently. Doing this well is Cartouche's standout feature. The analysis engine exists (InstallerKit); this phase runs the install.

## What Changes

- The six-step flow from `mockup/INSTALLER.md`: drop, analysis, review, install, choose the executable, ready.
- Analysis before anything runs: parts, missing parts, MD5 checked natively, Inno contents read with innoextract, game identified, space estimated.
- The install itself in a fresh prefix under Rosetta, guided or automatic, with real progress, background mode, and a stuck-installer watchdog.
- Redistributables replaced by winetricks, executable detected and ranked, Show in Steam.
- Retry with fixes after a failure (verify files, fewer threads, less memory, short path, other runner).
- Non-goals: anything that bypasses DRM; installers that are not Inno Setup get the guided mode only.
- Depends on P1 (runners) and InstallerKit.

## Capabilities

### New Capabilities
- `windows-installer`: analyzing and running Windows game installers, and turning the result into a playable library entry.

### Modified Capabilities
- None.

## Impact

`installer/` (InstallerKit grows an install runner), the app's install sheet, innoextract bundled (zlib license), winetricks bundled (LGPL). TROUBLESHOOTING doc.
