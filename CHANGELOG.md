# Changelog

What changed in each Cartouche release. Read by users, and by the release workflow: each tag publishes its own section below as the release notes in Sparkle and on GitHub.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow semver 0.x (ADR 0011). A section heading that ends in `(critical)` publishes a critical update.

## [Unreleased]

- French localization across the app, guided by `docs/l10n/glossary-fr.md` (vouvoiement, Apple terminology).
- Local crash reports: a post-crash prompt offers Show Report and Copy Summary, and a Collect Diagnostics command builds a zip locally; nothing is sent over the network.
- The Controls sheet shows a live controller diagram.
- Graphics menus and the game panel hide backends the game's setup can't use, with a single Get More Graphics Backends entry that leads to Wine CrossOver installation.
- innoextract is updated to 1.10 and covers Inno Setup installers up to version 6.4.0.
- Your Play compares a game's measured performance across its setups (Compare Setups).
- The install review shown for installers that unpack directly stays accurate through the run.

- Fix a release-app crash caused by blocking process probes during SwiftUI updates; game menus use cached busy state.
- Fix Sparkle startup by enabling update verification before extraction; a release-feed test guards the setting.

- Import already-installed Windows games in place or copy them. In-place source files remain user-owned.
- Detect installers with external unpackers and prepare their Wine environment before setup. Direct extraction is still in progress.
- MCP agent control, console extras, controls, store integrations and performance tracking are merged. Real-machine and service checks remain before release.
- Wine builds are published from the public BRYANN2K/cartouche-wine build-recipe repository. The app repository stays private until v0.1.0.

- Cartouche starts from NotProton 1.2.0, renamed and with its own data folder, update feed and icon.
- Release pipeline: pull request checks, signed releases with Sparkle updates, a beta channel, a Homebrew tap and a nightly watch of upstream projects.
