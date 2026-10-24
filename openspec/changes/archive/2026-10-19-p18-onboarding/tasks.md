# Tasks

## 1. Install

- [ ] 1.0 `install.sh` (curl download, SHA-256 and codesign checks, install, open); shellcheck clean; tested on clean macOS 15 and 26 accounts with `xattr` output in evidence.md

- [ ] 1.1 dmg layout with the three "Open Anyway" steps; README install section with screenshots; cask caveats; checked on clean macOS 15 and 26 accounts

## 2. First launch

- [x] 2.1 Detection (Steam account, CrossOver, GPTK, controllers, candidate folders); unit tests with fixtures
- [x] 2.2 Five skippable steps; App Management requested only in PC games; UI tests for skip-all and the consoles step
- [x] 2.3 Ready step with a playable game; UI test

- [x] 2.4 Saved onboarding state and resume banner; UI test quitting at each step
- [x] 2.5 Move to Applications check (translocation, dmg, Downloads); tested from a mounted dmg

## 3. Acceptance

- [ ] 3.1 Evidence per scenario; APPFLOW updated by the docs agent; `openspec validate p18-onboarding --strict` passes
