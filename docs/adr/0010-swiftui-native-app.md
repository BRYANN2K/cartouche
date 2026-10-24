# 0010. SwiftUI native app

One accepted decision for Cartouche. Read by contributors and agents who need to know why.

## Status

Accepted, 2026-10-19.

## Context

NotProton's app is Swift. Competing launchers use Electron (Heroic) or Swift (Mythic). The mockup is a native macOS 26 design.

## Decision

The app is native SwiftUI in Swift 6, reusing the existing app in `app/`. The Steam-side code stays in C (`dylib/`). Engines such as InstallerKit are Swift packages. The MCP helper is also Swift, with the official Swift MCP SDK.

## Alternatives rejected

- Electron or a web view. Rejected: not native, heavy, no Liquid Glass.
- Rewrite in AppKit. Rejected: SwiftUI gives the target look with less code.
- Rewrite from scratch. Rejected: the existing app and tests are reused.

## Consequences

- Needs Xcode 26 era tooling and Swift 6 concurrency discipline.
- Liquid Glass APIs exist only on macOS 26, so ADR 0004 fallbacks are required.
- Snapshot tests are needed for each screen state.
