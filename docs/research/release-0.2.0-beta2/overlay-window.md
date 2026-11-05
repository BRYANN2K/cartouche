# In-game menu: library behind it, windowed games

Two bugs from the 0.2.0-beta1 test with Far Shore (Ubisoft Connect, windowed 800×450).

1. The library window showed behind the translucent ⌥C menu.
2. The menu always covered the whole screen, even over a windowed game.

## Bug 1: the cause

Cartouche was hidden when the menu opened, and activation unhid it.

- "When a game starts" defaults to Hide: `afterLaunch` calls `NSApp.hide(nil)` (`App/AppModels.swift`). The user's defaults hold no value, so Hide applies.
- While an app is hidden, `NSWindow.isVisible` is false for all of its windows. `OverlayWindows.hideAll()` filtered on `isVisible`, so it found nothing to order out.
- `NSApp.activate()` then unhid Cartouche, and the unhide brought back every window shown before the hide, the library included, under the translucent panel.
- The outside HUD panel had the same effect: ordering in a window that can hide unhides its app.

### Evidence

Unified log of the running beta1 (pid 22271), the user's session on 2026-11-03:

| Time | Line | Meaning |
|---|---|---|
| 18:38:17.610 | `PostHideProcess: pid=22271` | Game launch, the Hide setting. `app.log` registers ⌥C at 17:38:17Z (UTC). |
| 18:39:56.136 to .164 | `PostShowProcess: pid=22271` (3 times) | The menu opens: Cartouche unhides. |
| 18:39:56.380 | `Notify ApplicationDidBecomeActive` | The activation that follows. |

After the menu closed, the window list showed the library window (titled "Ubisoft Connect", the sidebar selection) on screen at layer 0. Cartouche stayed unhidden.

`overlay-window/hide-probe.swift` reproduces the AppKit behaviour with invisible 1×1 windows and no activation:

```
shown:  library.isVisible true, closed.isVisible false
hidden: isHidden true, library.isVisible false, closed.isVisible false, hud(canHide false) on screen true
hidden, canHide false panel shown: isHidden true, on screen true
unhidden: library.isVisible true, ordered out while hidden false, closed false
hidden, then orderBack: isHidden false
```

- A window ordered out while hidden stays out after the unhide.
- A `canHide = false` panel shows while the app stays hidden.
- `orderBack` on a hidden app unhides it, so the app hides again after the restore, not before.

Ruled out: SwiftUI reopening the `Window` scene (no reopen event, the log shows an unhide), windows on another level (the library is `.normal`), and the restore order (nothing was hidden, so nothing was restored).

## Bug 1: the fix

- `OverlayWindows` records the visible windows on `willHideNotification`. While Cartouche is hidden, `hideAll()` orders out those windows instead of the `isVisible` ones.
- `OverlayController` notes that Cartouche was hidden when the menu opened. On close, after the game is back in front and the windows go back behind it, Cartouche hides again.
- `OverlayPanel.canHide = false`: the menu and the HUD panels no longer unhide Cartouche, and the HUD stays when Cartouche hides.

## Bug 2: the fix

`OverlayFrame` picks where the panel goes, from the window list of the game's pid.

- Main window: the largest on-screen window of the pid with alpha above 0, at a layer from 0 to below `.screenSaver`. Wine lifts a fullscreen game to layer 26, so layer 0 alone would miss it. Tooltips and menus lose on size.
- Coordinates: from the window list's top-left origin to Cocoa, against the primary screen's height. The screen is the one the window covers most.
- Fullscreen: when the window covers the screen's visible frame (1 pt slack), the panel takes the whole screen, as before. A window maximized under the menu bar counts too.
- Windowed: the panel takes the window's rect, cut to its screen.
- No window yet: the main screen, as before.

`OverlaySafeArea.within(_:of:)` keeps only the part of the notch and menu-bar band inside the window, and sets the HUD target height to the window's height. A window below the menu bar gets no inset. The in-game HUD reads the same values through the control block, and the shim applies the inset only to a target that matches that height.

The outside HUD panel takes the same rect. It sits in the window's corner and follows the window: each live refresh (500 ms) re-reads the rect while the menu is closed.

### Deviation from the brief

The panel covers the window's frame, title bar included, not its content rect. The window list gives frames only. Reading another app's content rect needs Accessibility, and guessing a title-bar height breaks on borderless windows. Covering the title bar leaves nothing of the window outside the menu.

## Tests

Swift Testing, red first: the new tests failed to build without `OverlayFrame`, `OverlayPlacement`, `within`, `appHidden` and `hideApp`.

- `OverlayFrameTests`: fullscreen, maximized, windowed and flipped, a window on the screen below the primary, fullscreen on that screen, several windows (tooltip, alpha 0, another pid), a popup in front of a fullscreen window, a window cut by its screen, no window, the window-list dictionaries. Safe area: below the notch, partly under it, fullscreen unchanged.
- `OverlayTests`: hidden Cartouche (windows leave before activation, the app hides again after close, a visible Cartouche stays visible), the windows chosen while hidden, `canHide` on both panels, the menu panel over a windowed game, the HUD panel over the window and following it.

Results, with `~/Library/Caches/cartouche-night/locked.sh`:

- `swift test --filter Overlay`: 76 tests in 6 suites pass.
- `swift test --no-parallel`: 2059 tests in 279 suites, 48 issues, all in 4 suites that need the staged payload (appinfo tool, Install payload, Runners model, Steam installer: "This build of Cartouche carries no components at all"). The worktree had no `make app-payload`.
- With the main checkout's payload copied in and `--manifest-cache none` (SwiftPM caches the manifest's `hasPayload`), those 4 suites pass: 57 tests. The copy was removed after.

## Not verified

- No run in the real app: the user was testing on the Mac. To check: Far Shore windowed, ⌥C, then ⌥⇧C, then close.
- The menu's layout in a small window. The column is at least 640 pt wide, so it fits 800×450, but the status capsule may crowd it.
- The Dock and the menu bar still hide while the menu is open, also over a windowed game.

## 2026-11-04: the random minimize, reproduced and fixed

Bench: `overlay-window/probe.c` is a fullscreen Win32 window that minimizes on `WM_ACTIVATEAPP(FALSE)`, like Cobalt Street. It is declared as an installed game and launched by Cartouche on the built-in screen. `cycle.sh` opens and closes the menu 20 times, alternating ⌥C and an Escape sent to Cartouche only (`esc.swift`). `front-watch.sh` logs every front-app change.

Cause: after the close, macOS gives the front to another app (Orca, the app in front on the other screen) in about 1 cycle out of 3. Sometimes Cartouche's request to activate the game is refused; sometimes the front goes to the game and then moves on as Cartouche hides. Wine's 500 ms grace then expires with the game inactive, and the game minimizes.

Fix:
- Cartouche (b3b6abaf): it hides only once the game is in front (0.6 s timeout), and for 1 s after the close it gives the front back to the game if another app takes it.
- Cartouche Wine (`0004-winemac-cartouche-overlay-focus.patch`): on didClose, and again 250 ms later, a game that is not active activates itself. macOS accepts self-activation, where it refuses activation requested by another app. The grace before a real focus loss reaches the game is now 700 ms.

Result before the Wine change: minimized at cycle 1 or 2. After: 20 of 20 cycles, 0 minimizes. Orca took the front 6 times and the game had it back within 60 to 100 ms each time.
