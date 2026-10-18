# Controls: controller, keyboard and mouse

Date: 2026-10-19. Can Cartouche manage controls for PC (Wine) and console (RetroArch) games? What is really possible with free signing?

## Short answer

Yes for most of it. Four things are real today: controller detection and status (Apple's Game Controller framework), console remapping (RetroArch files), Mac keyboard and mouse options for Wine games (Wine's Mac driver settings), and controller-to-keyboard for keyboard-only games (posting keyboard and mouse events, the same permission NotProton already asks Steam for). One thing is not possible with free signing: making macOS see a **virtual** controller. Inside Wine we can still remap, because we build our own Wine.

## What each layer allows (checked in source code)

| Need | How | Verified in |
|---|---|---|
| See which controllers are connected, battery, type | Apple Game Controller framework (Xbox, DualSense, DualShock 4, Switch Pro, Joy-Con, MFi), keyboard and mouse objects too | Apple framework, macOS 11+ |
| Light bar, rumble test, adaptive triggers (DualSense) | Game Controller framework (`GCDualSenseGamepad`, haptics) | Apple framework |
| Controllers in Wine games | Wine's `winebus.sys` with its SDL backend; registry `Enable SDL`, `Map Controllers`, `DisableHidraw` | `dlls/winebus.sys/main.c` |
| Steam games: full remapping, gyro, mouse on a controller | Steam Input. NotProton already asks macOS for the "post events" permission it needs | `dylib/feats/input_access.c` |
| Cmd as Ctrl, Option as Alt in Wine games | Wine Mac driver: `LeftCommandIsCtrl`, `RightCommandIsCtrl`, `LeftOptionIsAlt`, `RightOptionIsAlt` | `dlls/winemac.drv/macdrv_main.c` |
| Mouse locked to the game window (shooters), smooth scrolling, Retina | Wine Mac driver: `UseConfinementCursorClipping`, `UsePreciseScrolling`, `RetinaMode`, `CaptureDisplaysForFullscreen` | `dlls/winemac.drv/macdrv_main.c` |
| Console games: per-game and per-core remapping, hotkeys, 2+ players | RetroArch remap files (`input_remapping_directory`) and controller profiles (`joypad_autoconfig_dir`) | `configuration.c` |
| Play a keyboard-only game with a controller (any game) | Cartouche reads the controller and posts keyboard and mouse events (CGEvent). User grants Accessibility once | macOS API, same as Steam Input |
| Play a controller-only game with keyboard and mouse | **Not as a system-wide virtual controller**: that needs a DriverKit virtual HID entitlement from Apple, which free signing cannot get. Possible **inside Wine**: our Wine build can present a virtual XInput pad fed by Cartouche | Apple entitlement rules; our own Wine build (P2) |
| Navigate Cartouche itself with a controller (couch mode) | Game Controller framework + SwiftUI focus | Apple framework |

## Remapping a controller for a non-Steam PC game (checked 2026-10-19)

Wine's SDL backend (`dlls/winebus.sys/bus_sdl.c`) reads the `SDL_GAMECONTROLLERCONFIG` environment variable and adds each mapping with `SDL_GameControllerAddMapping`. So Cartouche can remap buttons per game by setting that variable in the launch environment, with no Wine patch. The game then sees an Xbox controller with the user's layout. To verify on our own Wine build: that it ships SDL2 and the SDL backend is on (`Enable SDL`, `Map Controllers`).

## What the feature looks like

- **Game panel > Controls**: the connected controller (name, battery), and who handles the layout: Steam Input for Steam games, Cartouche for other PC games, RetroArch for console games. One button: Customize.
- **Customize sheet**:
  - Controller tab: a controller drawing with each button's action; presets (Default, Southpaw, Swap A/B for Nintendo layouts).
  - Keyboard & Mouse tab (PC): Cmd as Ctrl, Option as Alt, lock the mouse in the window, precise scrolling.
  - "Play with a controller" for keyboard-only games: sticks to WASD and mouse, buttons to keys.
- **Settings > Controllers**: list of controllers, test buttons and rumble, DualSense light color, couch mode.

## Phase

A new change after P5 and P6, with RetroArch (P12) for consoles. The virtual XInput pad inside Wine needs our Wine build (P2) and is the riskiest part.
