# Code review and 0.1.0 work tracker — 2026-10-21 (cloud session)

Integration branch: `claude/sleepy-cerf-8bbse7`. Nothing here is compiled yet: the cloud container has no Swift toolchain.
GitHub Actions for this repo are blocked by billing ("recent account payments have failed or your spending limit needs to be increased").

## Merged on the integration branch
- review follow-ups (save backups, appinfo.vdf cache, Unreal shipping exe)
- RetroArchKit French (80 keys)
- B: extracted drops leave Caches; startup migration
- Release pipeline: libarchive/innoextract mandatory in release builds, CI caches, 60 min timeout, MACOS_RUNNER JSON labels, fr in retroarch-l10ncheck
- E/F: one Steam repair action (Settings + onboarding), D unchanged, C skipped
- A: launcher.sh exports the full SetupEnvironment (CX_APPLEGPTK_LIBD3DSHARED_PATH), stale launchers rewritten, unavailable graphics migrated; L: Play becomes Stop
- K: repack cancel cleanup + retry; G: Starts With

## In progress (agents)
- Drop handoff + Back to Add Games
- Rename our Wine build to "Cartouche Wine" (user-facing only; IDs unchanged)
- FP1 InstallerKit hardening, FP2 installer app fixes + direct-unpack fallback, FP4 RetroArch/MCP/Keychain, FP5 dylib hardening
- cartouche-wine 26.3.0-2 (SDL3, Mono/Gecko, dlopen check, headless boot check, licenses, actions, display name)
- Research: GStreamer (26.3.0-3), ISDone/unarc DEP under Rosetta

## Review findings not yet assigned (FP3, after drop handoff + rename merge)
- HIGH LibraryStore.swift:48-71 / AdvancedGameOptions.swift: one missing/unknown field resets library.json (favorites, covers, setups). decodeIfPresent + quarantine unreadable file.
- HIGH PrefixTools.swift:380-391: Delete Prefix also deletes its backups (pfx.previous-*), prompt doesn't say so.
- LibrarySetup.swift:17 installRunners reads + verifies the runner manifest on the main actor during render.
- SetupDefaultsSection.swift:110-120: installing DXVK/DXMT doesn't refresh Steam's backend tool list.
- RunnersModel.swift:208-229: removing a Wine build / GPTK while a game runs from it; GPTK removal skips syncTools.
- LibraryModel.swift:126-131: load() has no generation guard (stale result wins).
- OnboardingView.swift:540: pgrep in view body (check whether E/F already removed it).
- AppInfoVDF.swift:77-83: reserveCapacity from untrusted count.
- PerformanceStore.swift:42-56 + compat_run.sh: partial session file deletes live launch data.
- AppLocation.swift:71-72: Move to Applications can downgrade.
- RunnerInstaller.swift:33-36: CrossOver clone replace without swap/running check.
- CoverStore.swift:157-160: offline failure caches "missing" for 1 h.
- Improvements: JSON decode-or-quarantine helper; screenshot cache only on success; SteamLocalFiles.installFolder / PrefixesModel.load VDF reads off main actor; Attribution/CompatibilityCredits strings not localized.

## Maintainer-only before tagging 0.1.0
- Fix GitHub billing (or self-hosted runner via MACOS_RUNNER)
- Rename CHANGELOG `## [Unreleased]` to `## [0.1.0]` at tag time
- install.sh cert_sha1, signing cert + secrets, Sparkle EdDSA key, homebrew tap repo (see release-tasks-maintainer.md)
- Live checks: Steam export after Repair, controller with Cartouche Wine 26.3.0-2, D3DMetal on Silksong, repack install/cancel

## Follow-up after 0.1.0 (maintainer decision 2026-10-22)
- WebUI route access: on client 1790904859 the "flags" word of TransportAuth.Authenticate#1 and TransportValidationClient.AddNumbers#1 is identical (0x16bc80100), so it does not mark authentication. Custom routes take a served route's flags again (4918f5b). Study how the client really gates routes (transport auth handshake vs per-route flags) before relying on the export token as a boundary.
