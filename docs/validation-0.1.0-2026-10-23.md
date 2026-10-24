# Cartouche 0.1.0 validation checkpoint — 2026-10-23

This checkpoint records the accumulated app changes from the Mac validation session, including the final first-install fixes. It is a development checkpoint, not a release-readiness declaration. The separate `cartouche-site` repository is outside this commit.

## Included behavior

- Steam installation stays in the background, game state follows Steam's launch events, and supported runner changes reuse installed game files and prefixes. Uninstall handling clears stale installation state and removes the managed game prefix.
- Steam integration revision `0.1.0-5` adds logs for each launch attempt. Cartouche Wine 26.3 receives verified loader hooks needed for the native Steam bridge. The user confirmed Chained Together launches.
- PC and console inspectors share their main composition, artwork bounds and setup controls. Toolbar Search and Add retain glass; the artwork accent and continuous scroll fade remain. The fade is a visual fallback, not Apple's variable-blur implementation.
- GOG details include artwork and available size metadata. Console import includes emulator preparation and automatic artwork handling. Runner lists hide older uninstalled Cartouche revisions while retaining installed builds for management.
- About uses the approved product copy. General Settings includes the supplied Discord invite and optional Ko-fi support link. Credits remain in repository documentation.
- Compatibility changes distinguish Linux/Proton reports from Mac anti-cheat evidence. User-report collection and a website aggregation service remain proposals; this checkpoint does not implement those services. See ADRs 0035–0037 for the compatibility and shared-panel decisions.

## First-install regression fixes

The installed integration was already revision `0.1.0-5`. The reported Repair warning came from checking downloaded Wine's bridge files in a nonexistent CrossOver clone directory. Integrity checks now use the downloaded installation root and still reject changed or missing files.

Runner downloads now refresh system status and library choices. Runner preparation stages the bundled bridge when Steam setup has not yet run, and a failed preparation cannot be counted as a completed install. Onboarding chooses the latest pinned revision, waits for preparation, then opens Steam in the background after integration setup. If opening fails, the user can retry.

Controller glyph and layout controls use stacked rows within the onboarding card. Both segmented controls fit at the tested 612-point component width in dark and light appearances.

## Evidence and limits

| Check | Result |
| --- | --- |
| Final onboarding, runner and integrity tests | 91 tests in 11 suites passed |
| Final release app build | Passed |
| RetroArch embedding and strict deep app signature | Passed |
| Controller options component snapshots | Visually checked in dark and light appearances |
| Updated DMG checksum | Validated by `hdiutil verify` |
| Installed app | Replaced and reopened at `/Applications/Cartouche.app`; user data preserved |
| Complete live first-user walkthrough after the final fixes | Still pending the user's resumed test |

The final targeted tests cover automatic Steam handoff, preparation-failure blocking, first-download bridge staging, installed-root integrity, newest-revision selection and runner refresh. They are isolated fixtures and do not establish every live Steam or emulator behavior. Earlier targeted checks and user observations are recorded chronologically in `HANDOFF-codex.md`; the full repository test suite was not rerun for this checkpoint. An earlier broader identity/localization run had three unrelated failures, also recorded there.

Local evidence is under `.scratch/qualification-0.1.0/fresh-onboarding/`: `qualified-tests.log`, `build.log`, `retroarch.log`, `dmg-verify.log`, component snapshots and `live-main.json`. These artifacts and app bundles are not committed. The native inspection found onboarding resumed at Consoles; it did not advance the user's choices. Steam was left running and its integration was not reinstalled during app replacement.

The test installer is `~/Downloads/Cartouche-0.1.0-setup-fix.dmg`. No remote publication or push is part of this checkpoint.
