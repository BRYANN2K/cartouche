# Frontend continuation — Liquid Glass

Branch: `phase/liquid-glass-pass` (worktree `devin-glass`).

## Changes
- Retained the previous nine frontend commits: floating glass sidebar/panel, cover-tinted backdrop, platform marks, grid, console screens, activity, search/add toolbar, sheets, Runners, Settings, onboarding and empty/error states.
- `5936a9d`: merged main. Kept installed-game import behavior and Steam completion outcomes together with the redesigned 17pt sheet titles. Combined localization catalogs.
- `822daa1`: sidebar category changes no longer inherit panel layout animation; removed docked-panel width animation and scale entrance. Mac/Windows setup switches update without layout animation. Backdrop still cross-fades independently for 0.7s.
- Game panel: Steam store header first (460:215), then store screenshots. Pictures fit without cropping. Navigation arrows remain visible at 65% opacity at rest, full opacity on hover/focus. Canceled screenshot-list tasks cannot overwrite a new game's slides. Added cache/offline/missing-media tests.

## Validation
- Viewed feedback screenshots 16, 17, 18 and dark reference 01-library.png; read launcher.html tokens.
- `make -s app-tests`: **1,212 tests / 173 suites passed**, zero failures (790.246s test execution).
- `git diff --check`: clean.
- QA debug compilation succeeded; bundle packaging waits for SwiftPM lock held by release build.
- Release build, localization check, live QA screenshots and CPU/RSS sampling: **pending**. No measurements claimed yet.

## Remaining differences / limits
- Live screenshot comparison is not complete yet. Existing layout has the reference 214pt sidebar, 356pt panel, 8pt insets; toolbar intentionally follows the later capsule-search + round-add reference.
- Screenshot slides are letterboxed when their aspect ratio differs from the store header, to avoid cutting off gameplay.
- No constants beyond the arrow rest opacity changed. No user Library/Steam/Keychain data touched, no installations, no port 8765 actions.

## Review follow-up (validation running)
- Grid remains the exact CSS 132pt adaptive minimum and 16/22pt gaps. Earlier “six cards” capture was 1670pt wide, not the 1280pt reference width.
- Corrected prior card regression: uninstalled/unselected covers are now grayscale; downloads reuse the existing bottom-up Metal reveal rather than a thin progress bar. Existing Reduce Motion/static reveal fallback preserved.
- Compatibility-backed blocked anti-cheat status now appears red in grid subtitles; download/playing statuses keep priority.
- Carousel slides clipped individually; visible pager dots capped at seven.
- Narrow layout reserves panel space and permits docking with two 132pt columns (previously three).
- Native glass receives a 28% window-color backing for secondary-label legibility; Reduce Transparency remains opaque.
- Release online in scratch HOME verified public Steam header and screenshot switching. Captures: `frontend-captures/release-store-header.png`, `release-store-screenshot.png` (before clipping/dot refinements).
- Pre-follow-up release idle samples: CPU 0.0%, RSS 110816→66816 KiB; after carousel interaction, 0.1%, RSS 88288 KiB. Startup/fetch transient peaked at 98%; not treated as idle. App terminated after measurement.

- `25f6c7c` commits the review follow-up. QA debug build succeeded. A subsequent full suite run completed with one existing timing-sensitive RetroArch `playSeconds > 0` assertion failure; retry is in progress. No backend test or production behavior altered to hide the failure.

## Unified Add Games (maintainer decision)
- One toolbar button and the existing Command-O menu action open the same Add Games drop sheet. Empty/source/console add-game actions share it.
- Dashed drop zone accepts games, installers, archives and ROMs; Choose accepts any files/folders with multiple selection. Four new strings translated in Italian and Simplified Chinese.
- Existing `DropClassifying` signature unchanged. Nil backend shows an honest detection-unavailable result. The archive adapter must be injected through the environment after merge.
- Removed Windows/Console kind selection from downstream installer/ROM flows. Detected installer/installed folder/ROM results route to existing workflows after dismissing the detection sheet.
- Build and snapshot validation pending; no completion claimed.

- Unified entry full suite compiled and new entry/missing-adapter test passed. Eight assertions in old console tests still expected the deliberately removed Windows/Console kind pickers; tests updated to the approved single-entry behavior while preserving Back/reset/import checks. One stale `Kind` translation removed. Retry pending.
- QA packaging briefly failed because two queued make calls wrote the same bundle concurrently (duplicate rpath). Retrying with one packaging invocation; no production Makefile change.

## Final validation (22:22)
- Commit `271369a`: unified entry, approved console test updates; **1,213 tests in 173 suites passed**, zero failures (518.082s).
- `make -s l10ncheck`: **passes**, 1,309 strings; existing English Simplified-Chinese trial-version exception remains.
- QA and release bundles build successfully. Latest main merged again; only documentation changed after tests.
- Final 1280×800 real-art library captured: `frontend-captures/library-real-art-final.png`. Four columns match reference sizing; no card cuts. Selected Apex is color; anti-cheat subtitle red; God of War download base grayscale at 0%.
- Unified drop sheet captured: `frontend-captures/add-games-unified.png`.
- Console page/panel captured: `frontend-captures/console-final.png` (synthetic homebrew art, safe fixture; Continue From, setup, switches shown).
- Real public Steam BG3 header and arrow-switched screenshot confirmed in release scratch HOME (earlier captures); pager clipping/cap refinements covered by final build/tests.
- Reduced-transparency path remains opaque and existing light/dark/classic render tests pass. Did not change user's global accessibility preferences.
- Final-release startup displayed Sparkle “Unable to Check For Updates” once in isolated scratch HOME (ad-hoc local build). Dismissed; unrelated to visuals.

- Final release PID 16547: idle samples 0.0% / 116176 KiB, 0.1% / 101504 KiB, 0.0 100560 (CPU%, RSS KiB). Memory decreased after caches settled; no observed growth. Terminated only this owned release PID. Unknown pre-existing app PIDs left untouched.

## Final main integration
- `cb51e93`: merged main batch 307ad2c, keeping new cover fallback/search, Steam-closed library action, uninstall, runtime progress, and identification features alongside launcher visuals. CoverView keeps a single size-stable load task, now keyed by Steam app ID; no duplicate task. Steam empty source uses existing branded EmptyState and Open Steam action.
- Change Cover search sheet now follows 17pt title / capsule Search+Cancel / 22pt padding. Ready to Import title aligned.
- Full suite: **1,255 tests /176 suites passed**, zero failures (613.028s).
- Release rebuilt successfully before l10n extraction. Removed six genuinely obsolete strings only; live new strings preserved.
- Final `make -s l10ncheck`: **passes**, 1,328 strings, existing trial-version zh-Hans English exception.
- HEAD `a47ffd3675a840c610f5fec2b5c0764234c2e6db`. Tracked working tree clean; untracked `.design/` reference captures retained. Console played/save inconsistency noted for later, not changed.
