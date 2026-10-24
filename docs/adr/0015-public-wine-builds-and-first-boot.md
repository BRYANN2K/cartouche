# 0015. Public Wine builds and serialized first boot

## Status

Accepted, 2026-10-20. Supersedes ADR 0007 in part: publication and the default runner.

## Context

The app repository remains private until v0.1.0. Wine build recipes need a public source offer. A local CrossOver 26.3 prefix repair took 670.94 seconds; starting before it finished caused Explorer and window-driver errors.

## Decision

Publish our build of CodeWeavers’ LGPL CrossOver 26.3 Wine from the public BRYANN2K/cartouche-wine repository. That repository holds the build recipe, not the app. BRYANN2K/cartouche remains private until v0.1.0. CrossOver Wine becomes the default runner. Among the free Wine builds, only this variant enables D3DMetal and DXMT; D3DMetal still comes from the user’s own licensed files.

Make first boot an explicit setup phase, serialized per prefix. Do not launch a game or installer until initialization and the Wine server have finished successfully. Show progress, logs, cancellation and retry. A registry file or update timestamp alone is not completion proof.

## Alternatives rejected

Do not treat a 60-second cold-prefix smoke test as proof that the driver is broken. Do not let Wine implicitly initialize a prefix while a game starts.

## Consequences

The public build-repository decision is merged. The default-runner change and full first-boot gate are planned. Existing WineBootstrap only checks system.reg before creating a prefix. The roughly eleven-minute repair is a local diagnostic result, not a fixed delay or performance promise. See docs/research/wine-first-boot.md.
