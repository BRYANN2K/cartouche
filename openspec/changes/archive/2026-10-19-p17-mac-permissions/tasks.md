# Tasks

## 1. Module

- [x] 1.1 Permissions catalog (the inventory in design.md) with state readers; unit tests per permission with mocked TCC answers
- [x] 1.2 Explanation sheet and request flow; UI test that the macOS prompt is only triggered after the sheet
- [ ] 1.3 Deep links per pane with fallback; tested on macOS 15 and 26

## 2. Integration

- [x] 2.1 Reuse NotProton's App Management detection; Steam step messaging; test with a write-refused fixture
- [x] 2.2 Settings > Privacy list with states and Open System Settings; snapshot test
- [x] 2.3 Degraded-feature messages for Downloads, Removable Volumes, Notifications, Accessibility, Local Network; UI tests

- [x] 2.4 Relaunch service (save screen, wait for games, reopen, restore); UI tests for Quit & Reopen, Later and game running
- [ ] 2.5 Matrix of which permissions apply without relaunch, measured on macOS 15, 26 and 27, in evidence.md

## 3. Acceptance

- [ ] 3.1 Info.plist scan for unused usage descriptions; update test across two signed builds (with P9); evidence per scenario; PRIVACY doc by the docs agent; `openspec validate p17-mac-permissions --strict` passes
