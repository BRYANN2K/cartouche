# Architecture decision records

Index of accepted decisions for Cartouche. Read by contributors and agents before changing an area. Accepted ADRs are never edited: a new ADR supersedes them.

Format: Status, Context, Decision, Alternatives rejected, Consequences. Files are named `NNNN-title.md`.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-independent-fork-of-notproton.md) | Independent fork of NotProton | Accepted, 2026-10-19 |
| [0002](0002-name-cartouche.md) | Name the project Cartouche | Accepted, 2026-10-19 |
| [0003](0003-free-self-signed-signing.md) | Free self-signed signing, no notarization, personal Homebrew tap | Accepted, 2026-10-19 |
| [0004](0004-macos-15-minimum-liquid-glass-on-26.md) | macOS 15 minimum, Liquid Glass on macOS 26 | Accepted, 2026-10-19 |
| [0005](0005-no-server-nightly-compatibility-json.md) | No server: a nightly compatibility JSON built by CI | Accepted, 2026-10-19 |
| [0006](0006-openspec-and-orchestrator-subagent-workflow.md) | OpenSpec and the orchestrator and subagent workflow | Accepted, 2026-10-19 |
| [0007](0007-free-runners.md) | Free runners: our Wine build (now Cartouche Wine, see 0033) built by our CI, WineHQ builds, user-installed GPTK | Accepted, 2026-10-19; naming superseded in part by 0033 |
| [0008](0008-bundled-retroarch-built-from-source.md) | Bundled RetroArch built from source, cores downloaded per console | Accepted, 2026-10-19 |
| [0009](0009-anti-cheat-as-linux-data.md) | Anti-cheat shown as Linux data only | Accepted, 2026-10-19 |
| [0010](0010-swiftui-native-app.md) | SwiftUI native app | Accepted, 2026-10-19 |
| [0011](0011-one-scope-first-release-v0-1-0.md) | One scope, consoles included, first release v0.1.0 | Accepted, 2026-10-19 |
| [0012](0012-install-script-avoids-gatekeeper-warning.md) | Install script to avoid the Gatekeeper warning (amends 0003) | Accepted, 2026-10-19 |
| [0013](0013-macgamingdb-read-live.md) | MacGamingDB is read live by the app and never redistributed (supersedes 0005 in part) | Accepted, 2026-10-19 |
| [0014](0014-bundle-identifier-dev-bryann2k-cartouche.md) | Bundle identifier dev.bryann2k.cartouche (supersedes 0002 in part) | Accepted, 2026-10-19 |
| [0015](0015-public-wine-builds-and-first-boot.md) | Public Wine builds and serialized first boot | Accepted, 2026-10-20; implementation merged in 95b4e47; hardware checks pending |
| [0016](0016-built-in-archive-import.md) | Built-in archive import | Accepted, 2026-10-20; backend merged in 95b4e47; app wiring merged in 539fbe3 |
| [0017](0017-installers-with-external-unpackers.md) | Direct unpack of supported installers ([verified recipe evidence](../research/direct-unpack-verification.md); app implementation merged in 3bb5921; fallback in 0034; end-to-end check pending) | Accepted, 2026-10-20; amended by 0034 |
| [0018](0018-local-game-import-and-removal.md) | Local game import and safe removal | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0019](0019-ranked-game-identification.md) | Ranked game identification | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0020](0020-pe-based-runtime-installation.md) | PE-based runtime installation | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0021](0021-steam-library-with-steam-closed.md) | Steam library with Steam closed | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0022](0022-protected-steam-webui-export.md) | Steam library export through a protected WebUI route | Accepted, 2026-10-20; implementation merged in de0e6ec, real Steam check pending; runtime token fetch merged in 9214df4, real Steam check pending |
| [0023](0023-bundled-libarchive-drop-classification.md) | Bundled libarchive and shared drop classification | Accepted, 2026-10-20; backend merged in 95b4e47; app wiring merged in 539fbe3; real archive pending |
| [0024](0024-unified-add-games.md) | One Add Games entry point | Accepted, 2026-10-20; UI merged in 51a8ece, backend wired in 539fbe3 |
| [0025](0025-verify-installation-or-fall-back.md) | Verify installation output or fall back | Accepted, 2026-10-21; live engine merged in 93aa900 / 04d6b6f |
| [0026](0026-verification-levels-and-failure-choices.md) | Verification levels and explicit failure choices (amends 0025) | Accepted, 2026-10-21; UI merged in 7f8773b; engine merged in 93aa900 / 04d6b6f |
| [0027](0027-hide-unavailable-graphics-backends.md) | Hide unavailable graphics backends | Accepted, 2026-10-21; UI merged in 522d4fa |
| [0028](0028-static-inspection-detection-tree.md) | Detect installers by static inspection, with evidence and confidence (approves the tree left proposed by 0025–0026) | Accepted, 2026-10-21 |
| [0029](0029-local-crash-reports.md) | Crash reports stay local | Accepted, 2026-10-21; implemented in main 1c25236 |
| [0030](0030-advanced-windows-game-options.md) | Advanced Windows-game options in the game panel | Accepted, 2026-10-21; amended by 0031; merged in 397990d / a46a8bb |
| [0031](0031-advanced-options-gating.md) | Advanced options gated per runner and backend, no frame generation (amends 0030) | Accepted, 2026-10-21; merged in 397990d / a46a8bb |
| [0032](0032-onboarding-v2.md) | Onboarding v2: seven steps with background tasks | Accepted, 2026-10-21; merged in d7b3404; evidence pending |
| [0033](0033-cartouche-wine-naming.md) | Our Wine build is called Cartouche Wine (supersedes 0007, 0015, 0027, 0032 in part, naming only) | Accepted, 2026-10-21; merged in 828e14e |
| [0034](0034-direct-unpack-fallback-on-try-again.md) | A failed direct unpack falls back to the original setup on Try Again, never automatically (amends 0017) | Accepted, 2026-10-21; merged in e4ff967; pending build and live check |
| [0037](0037-one-game-panel.md) | One game panel, fixed module order | Accepted, 2026-10-23 |
