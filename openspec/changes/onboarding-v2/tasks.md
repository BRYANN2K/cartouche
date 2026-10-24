# Tasks

- [x] Build the seven-step flow in order (Welcome+scan, Windows games, Stores, Consoles, Controller, Permissions/storage/privacy, Ready), each step skippable. Verify: OnboardingFlowTests step-order test.
- [x] Windows games step: preselect Cartouche Wine as the default runner and offer picking the user's GPTK disk image; ask App Management only here, before modifying Steam. Verify: defaults test and fixture dmg scan test. (d7b3404; the code asks App Management in Stores, immediately before the Steam write, per ADR 0032.)
- [x] Stores step offers Epic, GOG and Amazon sign-in; skipping adds no store. Verify: step test with no store connected.
- [x] Run onboarding downloads and installs as background tasks shown in Activity; no step blocks on a task and no process waits on the main actor. Verify: task-state test, code review of the view body.
- [x] Persist step, choices and task state after each step; after a relaunch reopen on the saved step with the Welcome back banner, Start Over and the task list restored. Verify: relaunch resume test.
- [ ] Update `mockup/onboarding.html` and capture screenshots (light and dark, macOS 15 and 26, Reduce Motion). Verify: screenshots in evidence/.
- [x] Add the new step strings to `Localizable.xcstrings` in en, it, zh-Hans and fr, in xcstringstool format. Verify: `make -s l10ncheck`.

## Acceptance

- [ ] Every scenario of the onboarding delta has an entry in `evidence.md`, `openspec validate --all --strict` passes, and the orchestrator review and post-merge ui-gate follow-up are complete.
