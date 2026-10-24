# Onboarding v2 and Advanced prototype

Open `mockup/launcher.html`. Use the mockup state picker for fresh/resumed setup or the two Advanced backend states. Copy switches the new screens between English and French; the surrounding existing launcher is not translated.

## Captures and smoke checks
Run from the repository root with Playwright available:

```sh
PLAYWRIGHT_MODULE=/absolute/path/to/node_modules/playwright node mockup/capture-onboarding.cjs
```

Captures include all seven steps in English/French, disconnected controller, saved-step resume, interrupted download, and expanded/collapsed Advanced. Checks cover skip-all without download, background download on Continue, persisted step after reload, retry, and backend toggle counts (D3DMetal 5, DXMT 6).

## Design assumptions
- Sample Mac: M4 Pro, macOS 15.6, 24 GB; 112 GB free. Sample Steam account has 10 games. These are illustrative, not detected data.
- Advanced previews assume a capability-qualified CrossOver 26.3 runner. DLSS and High Resolution are design controls only: their full runtime mappings remain unverified. DXMT spatial scaling appears only for DXMT; factor is 1.0–2.0, initially 2.0. Toggles initially off; these are mockup defaults, not approved app defaults.
- App Management is described at the Steam action, immediately before modifying Steam, not requested broadly in Permissions. The OpenSpec delta says Windows-games step while ADR 0032 says before Steam modification; this placement follows the latter and keeps Steam actions together.
- All actions are simulations. Store sign-in, disk selection, permission prompts, restarts and downloads never touch the system. Progress is illustrative, not a real transfer.
- Resume/choices persist only under the mockup localStorage key `cartouche.mock.onboarding.v2`. Fresh setup resets the sample state. Continue starts the preselected runner download; Skip does not.
