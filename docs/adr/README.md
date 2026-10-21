# Architecture decision records

Index of accepted decisions for Cartouche. Read by contributors before changing an area. Accepted ADRs are never edited: a new ADR supersedes them.

Format: Status, Context, Decision, Alternatives rejected, Consequences. Files are named `NNNN-title.md`.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-independent-fork-of-notproton.md) | Independent fork of NotProton | Accepted, 2026-10-19 |
| [0002](0002-name-cartouche.md) | Name the project Cartouche | Accepted, 2026-10-19 |
| [0003](0003-free-self-signed-signing.md) | Free self-signed signing, no notarization, personal Homebrew tap | Accepted, 2026-10-19 |
| [0004](0004-macos-15-minimum-liquid-glass-on-26.md) | macOS 15 minimum, Liquid Glass on macOS 26 | Accepted, 2026-10-19 |
| [0005](0005-no-server-nightly-compatibility-json.md) | No server: a nightly compatibility JSON built by CI | Accepted, 2026-10-19 |
| [0007](0007-free-runners.md) | Free runners: Wine CrossOver built by our CI, WineHQ builds, user-installed GPTK | Accepted, 2026-10-19 |
| [0008](0008-bundled-retroarch-built-from-source.md) | Bundled RetroArch built from source, cores downloaded per console | Accepted, 2026-10-19 |
| [0009](0009-anti-cheat-as-linux-data.md) | Anti-cheat shown as Linux data only | Accepted, 2026-10-19 |
| [0010](0010-swiftui-native-app.md) | SwiftUI native app | Accepted, 2026-10-19 |
| [0011](0011-one-scope-first-release-v0-1-0.md) | One scope, consoles included, first release v0.1.0 | Accepted, 2026-10-19 |
| [0012](0012-install-script-avoids-gatekeeper-warning.md) | Install script to avoid the Gatekeeper warning (amends 0003) | Accepted, 2026-10-19 |
| [0013](0013-macgamingdb-read-live.md) | MacGamingDB is read live by the app and never redistributed (supersedes 0005 in part) | Accepted, 2026-10-19 |
| [0014](0014-bundle-identifier-dev-bryann2k-cartouche.md) | Bundle identifier dev.bryann2k.cartouche (supersedes 0002 in part) | Accepted, 2026-10-19 |
| [0015](0015-public-wine-builds-and-first-boot.md) | Public Wine builds and serialized first boot | Accepted, 2026-10-20; implementation merged in 95b4e47; hardware checks pending |
| [0016](0016-built-in-archive-import.md) | Built-in archive import | Accepted, 2026-10-20; backend merged in 95b4e47; app wiring pending |
| [0017](0017-installers-with-external-unpackers.md) | Installers with external unpackers ([verified recipe evidence](../research/direct-unpack-verification.md); app implementation merged in 3bb5921; fallback and end-to-end checks pending) | Accepted, 2026-10-20 |
| [0018](0018-local-game-import-and-removal.md) | Local game import and safe removal | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0019](0019-ranked-game-identification.md) | Ranked game identification | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0020](0020-pe-based-runtime-installation.md) | PE-based runtime installation | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0021](0021-steam-library-with-steam-closed.md) | Steam library with Steam closed | Accepted, 2026-10-20; implemented in main 307ad2c |
| [0022](0022-protected-steam-webui-export.md) | Steam library export through a protected WebUI route | Accepted, 2026-10-20; implementation merged in de0e6ec, real Steam check pending |
| [0023](0023-bundled-libarchive-drop-classification.md) | Bundled libarchive and shared drop classification | Accepted, 2026-10-20; backend merged in 95b4e47; app wiring and real archive pending |
| [0024](0024-unified-add-games.md) | One Add Games entry point | Accepted, 2026-10-20; UI merged in 51a8ece, backend pending |
| [0025](0025-verify-installation-or-fall-back.md) | Verify installation output or fall back | Accepted, 2026-10-21; implementation pending |
| [0026](0026-verification-levels-and-failure-choices.md) | Verification levels and explicit failure choices (amends 0025) | Accepted, 2026-10-21; UI merged in 7f8773b; engine pending |
