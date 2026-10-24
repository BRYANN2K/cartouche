# Proposal

## Why

The fork still ships as NotProton: same name, bundle ID, data folder and update feed. Installed next to NotProton it would share its data, and Sparkle would replace it with NotProton at the first update check. Nothing else can be built safely until the fork has its own identity.

## What Changes

- The app is named Cartouche everywhere users see it (app bundle, menus, About window, README).
- New bundle identifier, data folder under `~/Library/Application Support/Cartouche`, and log folder.
- Own names inside Steam (dylib, compatibility tools, prefix files, launch options). Install, Repair Steam and Remove Everything leave NotProton's dylib, tools and prefix files alone.
- New Sparkle update feed and EdDSA public key. The NotProton feed is never contacted.
- Icon from `mockup/brand/` (Default and Dark appearances, menu bar glyph).
- README, NOTICE and LICENSE state that Cartouche is an independent GPL-3.0 fork of NotProton and is not affiliated with it or with Valve, Apple or CodeWeavers.
- Non-goals: no new runner, no UI redesign, no CI release pipeline (P9).

## Capabilities

### New Capabilities
- `app-identity`: how the app identifies itself, where it stores data, which update feed it trusts, and how it coexists with NotProton.

### Modified Capabilities
- None.

## Impact

`app/Info.plist`, `app/Package.swift`, `Support/SupportPaths.swift`, `Support/AppUpdater.swift`, localization strings, README, NOTICE, app icon assets. Depends on nothing.
