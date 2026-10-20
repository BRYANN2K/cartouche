# Changelog

What changed in each Cartouche release. Read by users, and by the release workflow: each tag publishes its own section below as the release notes in Sparkle and on GitHub.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow semver 0.x (ADR 0011). A section heading that ends in `(critical)` publishes a critical update.

## [Unreleased]

- Import already-installed Windows games in place or copy them. In-place source files remain user-owned.
- Detect installers with external unpackers and prepare their Wine environment before setup. Direct extraction is still in progress.
- MCP agent control, console extras, controls, store integrations and performance tracking are merged. Real-machine and service checks remain before release.
- Wine builds are published from the public BRYANN2K/cartouche-wine build-recipe repository. The app repository stays private until v0.1.0.

- Cartouche starts from NotProton 1.2.0, renamed and with its own data folder, update feed and icon.
- Release pipeline: pull request checks, signed releases with Sparkle updates, a beta channel, a Homebrew tap and a nightly watch of upstream projects.
