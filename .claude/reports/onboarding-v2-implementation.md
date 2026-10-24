# Onboarding v2 implementation

Continues the existing uncommitted Devin implementation. The SwiftUI shell follows the approved mockup: 224-point step rail, 900 × 660 sheet, persistent background-task strip and bottom actions. Seven steps retain detected machine/Steam/controller/toolkit state. English, Italian, Simplified Chinese and French copy is in the catalog.

## Behavior
- Continue on Windows starts runner installation and prefix-template first boot without blocking the next step. Core downloads and GPTK image imports also outlive the sheet.
- Pending runner/core/image requests persist with choices and resume on app initialization, even after setup was completed. Successful tasks clear their pending intent; failures remain retryable.
- GPTK images mount read-only off the main actor, copy only the existing D3DMetal import contents, and detach. Fixture tests do not mount real images or use Apple files.
- Existing v1 completion stays completed. Unfinished v1 setup migrates to Welcome, keeping applicable choices.
- Keyboard-only controller mapping is opt-in, initially off. The layout picker previews the diagram; actual per-game layouts remain in Controls (no global silent remapping of existing games).
- Choosing a games folder configures future installs only. Existing games retain their paths; no unsolicited storage migration runs.
- Removed the inherited Downloads suggestion toggle: no live download-watcher implementation exists, and this is not required for the approved setup. The decoded choice remains compatible with unfinished saved state.

## Follow-up review correction
- Runner selection now only recommends the pinned Cartouche Wine CrossOver entry; WineHQ cannot receive the recommendation. Fixtures use the bundled `wine-crossover-26.3.0-1` pin and assert that exact ID.
- The runner choice is on by default with a clear green selected switch in active and inactive captures. Continue is the sole download action; the extra Download in Background button is removed.
- A test asserts the task strip immediately names Wine CrossOver 26.3 after Continue. Re-captured Windows games in dark/light; 17 OnboardingFlowTests pass.

## Review points
- Welcome/Ready do not use a per-step Skip button: Welcome has Skip Setup and Ready opens the library, matching the implementation brief. ADR/OpenSpec currently say every step is skippable.
- App Management stays immediately before the Steam integration write in Stores. The OpenSpec delta still names Windows games, unlike the owning Steam action and ADR intent.
- Runner download progress is currently an indeterminate indicator because RunnersModel does not expose byte progress. Core progress uses completed-core fraction.
- Full Settings location/glyph defaults and applying controller layouts to future games are not implemented by the existing Settings architecture. Choices remain available through Run Setup Again; per-game layouts are in Controls.

## Validation
Native app build succeeded; `swift test --no-parallel --disable-sandbox --filter 'Onboarding|PortingToolkitDMG|SteamStep'` passed 42 tests across five suites. Light/dark native SwiftUI captures are included. A pre-existing deadline-test fake emits a checked-continuation leak diagnostic but its deadline assertion passes. Compiler-backed Debug localization check has no missing keys for onboarding; unrelated baseline issues: stale catalog entries and four existing untranslated French installer keys. `make l10ncheck` expects Release compiler extraction and reports no Release .stringsdata after Debug-only builds.
