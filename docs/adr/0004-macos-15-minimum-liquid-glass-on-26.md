# 0004. macOS 15 minimum, Liquid Glass on macOS 26

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

The existing app targets macOS 15. The mockup uses the macOS 26 Liquid Glass look. FEX (an alternative x86 translation) works only on macOS 26.

## Decision

The minimum is macOS 15 Sequoia. On macOS 26 the app uses Liquid Glass. On macOS 15 it uses standard materials, and every screen must render without missing controls. FEX is offered only on macOS 26. Reduce Motion and Reduce Transparency are honored on both.

## Alternatives rejected

- macOS 26 only. Rejected: it would cut off users who have not upgraded.
- Older than macOS 15. Rejected: the existing code and Swift 6 tooling target 15.
- A custom glass effect on macOS 15. Rejected: standard materials are native and simple.

## Consequences

- UI code needs availability checks and a fallback for each glass element.
- CI needs snapshot tests on a macOS 15 runner and a macOS 26 runner.
- Setups that need FEX are hidden on macOS 15.
