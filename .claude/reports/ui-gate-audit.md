# UI gate audit — main b0e4a17

2026-10-21. QA bundle: `/tmp/cartouche-qa-1529/Cartouche-QA.app`. Worktree: `sol-ui-french`, branch `ui-gate/french-layout`. Isolated senior home from `qa/launch.sh`, mock port 8897. No real Library, Steam or Keychain data changed.

## Findings before fixes

1. **French coverage:** three archive failure messages have no French localization: `Extracting %@ needs about %@ free on this drive; %@ is free.`, `Put %@ in the same folder as %@, then drop the archive again.`, `The drive ran out of space while extracting %@.` Report wording separately; no wording edits authorized.
2. **Menu IO:** `GameMenu.items` calls `ConsoleUninstall.ownsROM`, which resolves symlinks and checks file existence synchronously. Console ownership belongs in cached model state, not view/menu construction. Thin UI/model glue candidate.
3. **Visual inspection in progress:** French library, game panel and Add Games sheet inspected live; no overflow at the default QA window size. Settings/onboarding/install sheet and English run remain pending. No all-clear claimed.

## Coverage from source

- Console removal: per-game menu, own-ROM versus in-place labels, busy disable, confirmation, keep-saves checkbox; Remove Console action with confirmation and errors.
- Local lifecycle: busy-client-sensitive Quit/End Session, confirmation, Rename and suggestion acceptance, errors through library model.
- Steam downloads: activity and game-panel progress, pause/resume/cancel/retry actions.
- Archives: Add Games adapter now wired, detecting/extracting progress, cancel and failure sheets.
- Verification: panel status and Verify Files sheet, mismatch recovery and output fallback.
- Console scan, graphics availability and innoextract are backend changes reached through existing surfaces.
- Crash reports: banner, show/copy/dismiss; controller diagram in Controls; performance comparison sheet.

Further live results and any layout changes will be recorded below.

## Live evidence and fix

- French and English launches used explicit `-AppleLanguages '(fr)'` / `'(en)'`, the same isolated senior home and mock on port 8897. Screenshots in `ui-gate-shots/`: library/game panel and Add Games in both languages. French empty-library screen also inspected with clean fixture home (port 8898).
- No clipping or overflow observed on these screens at 1710×1074. Mock artwork is intentionally synthetic. No typography/style constants changed.
- Fixed item 2: `ConsoleCenter.reload` now caches ROM ownership off-thread; `GameMenu.items` reads the cache. Actual removal still makes its fresh plan before confirmation. Regression asserts cached labels do not probe disk and refresh after reload.
- No wording edits. Missing French archive errors recorded in `fr-review.md`.
- **Not visually verified:** Settings, onboarding assistant, install-sheet states, live error/confirmation dialogs, narrow window, light appearance, Reduce Motion/Transparency. Orca keyboard focus/window targeting did not reliably select Settings; clean fixture launch showed the empty library rather than the onboarding assistant. Source coverage is not a substitute for these visual checks.
- Filtered ConsoleUninstallTests passed (exit 0) through `swift test --disable-sandbox --filter ConsoleUninstallTests`. No full test or release/l10n build claimed.
