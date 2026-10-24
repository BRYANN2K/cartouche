# Design

## Context

NotProton stores everything through `SupportPaths` and updates through `AppUpdater` (Sparkle 2.10, feed and key in Info.plist). The Steam-side dylib also reads `~/Library/Application Support/notproton`.

## Goals / Non-Goals

**Goals:** a build that can be installed next to NotProton without any shared state.

**Non-Goals:** migrating a NotProton user's data into Cartouche (can come later as an explicit import).

## Decisions

- **Rename paths in one place.** `SupportPaths` gets a single root constant, and the dylib reads the same root through a compile-time define. Rejected: search-and-replace across files, which leaves stragglers the scenario above would catch late.
- **Bundle ID `dev.bryann2k.cartouche`.** Reverse-DNS on bryann2k.dev, a domain the maintainer owns. Rejected: `app.cartouche.Cartouche`, on a domain nobody on the project owns; `com.github.<user>.cartouche`, which ties the identity to a GitHub account.
- **Own names inside Steam, also defined in the shared header.** The injected dylib is `cartouche.dylib`, the compatibility tools `cartouche-proton*` (Steam maps Cloud save paths only for tools whose name contains "proton"), prefix files `cartouche-*`, launch options `CARTOUCHE_*`, the library filter key `cartoucheWindows`. Install, Repair Steam and Remove Everything detect NotProton's dylib and leave it, its insert entry, its tools and the Steam parts it shares (update block, legacycompat) alone. Rejected: keeping NotProton's names until P3, which lets Remove Everything delete NotProton's tools and Repair Steam delete its dylib.
- **New EdDSA key generated once, private half stored only in CI secrets.** Rejected: reusing NotProton's key, which we do not have and must not use.

## Risks / Trade-offs

- [The dylib and the app disagree on the data root] → one shared header generated from the app's constant, plus a test that compares both.
- [Steam already has NotProton's compatibility tools registered] → Cartouche's tools have their own names, so both sets are listed side by side.
- [Both dylibs injected into one Steam] → Install refuses while another dylib is injected, so one Steam carries one of them at a time.
