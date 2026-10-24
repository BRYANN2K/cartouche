# Verification UI

Worktree: sol-verify-ui; branch phase/verify-ui. ADR 0026.

- Installed local games show a discreet neutral shield/status plus explanation. States: Installed, not verified; Verified (sizes); Verified. Missing evidence is never described as full verification.
- Local game menu offers Verify Files…; Steam/store existing validation routes remain unchanged.
- Progress row includes filename, determinate progress and Stop.
- Mismatch sheet lists paths and offers default Retry with the Standard Method, advanced Keep Anyway, and Cancel. No skip checkbox; interactive dismissal disabled.
- Small @MainActor observable/sendable GameVerificationPresenting protocol is injected as `.environment(\.gameVerification, adapter)`. No filesystem checks or persistence implemented here. Backend must supply statuses/progress/mismatch and implement recovery/logging. Nil adapter reports unavailable; no success fabricated.
- FixtureGameVerification plus tests cover evidence labels, Stop and all failure choices remaining unverified, local menu routing, light/dark rendering.
- Fifteen new strings translated in Italian and Simplified Chinese. Existing design sizes reused (11pt status, 12pt progress, 17pt sheet header, 22pt padding). No global settings or real user files changed.

Validation pending: full suite, release build and l10ncheck. First compile required protocol Sendable for Swift 6 environment-key safety; corrected.

## Validation progress
Verification suite (4 tests) passes, including all light/dark renders. Initial mismatch title assertion encountered accessibility extraction typography and now checks its stable visible prefix.
Fresh checkout initially had no staged payload. Copied ignored payload from repo root. SwiftPM cached the earlier conditional resource list; partial plan invalidation did not fix it. Ran native `swift package clean`; `swift package describe --type json` now explicitly declares the payload copy resource. Full clean test build running. Earlier full-run failures were 43 payload-dependent assertions, not verification behavior; one prior run also hit existing installer timing test. Not reported as success.

## Handoff / validation limit
- Implementation commit: `8ea8d5f`; current main merged cleanly as `7d6cd84`.
- All four verification tests pass, including model levels, Stop, recovery choices, local menu route, light/dark renders. Other tests executed but payload-dependent failures prevent claiming full-suite success.
- `make -s app-payload` requested by orchestrator fails on six missing `build/dobby/*.a` archives in fresh worktree (clang link error). No dependencies installed. Full validation handed to orchestrator on main as agreed; no further cache manipulation.
- Queued no-manifest-cache release compilation/l10n extraction is still pending; final l10n result will be reported on completion. Catalog contains fifteen added keys, both target locales supplied.
