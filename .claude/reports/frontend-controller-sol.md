# Controller diagram

Worktree sol-controller; branch phase/controller-diagram.

- SwiftUI port of cartouche-site Pad.astro shell path and index.astro split parts; neutral monochrome surfaces follow system appearance/tint. Added independent L2/LT and R2/RT triggers above original shoulder bars (30pt extra vertical room).
- Controller mapping section includes diagram before list, shared by Wine/SDL and RetroArch variants. Row hover, keyboard focus and selection highlight source part; readout shows source-to-target mapping.
- PlayStation face glyphs × ○ □ △; Xbox/Nintendo positional labels use existing PadFamily rules. Trigger/shoulder labels follow family.
- Live presses and stick movement use existing GameControllerPadReader / ControlsCenter loop; does not replace controller handlers or add a timer. Fast polling applies only while diagram is visible and app active; publishes changed state only, clears on disconnect/dismiss. Small main-actor state read uses existing framework API; no heavy work moved onto main actor.
- Three localized strings (it, zh-Hans). Existing hardware button labels retained.
- Tests cover family/trigger labels, visible-only live state/disconnect, light/dark diagram renders. Full suite currently building; no result claimed.
- Assumption: keep Steam Input-managed controller screen unchanged (no local Each button sends mapping list there). No behavior/remap file changes.
