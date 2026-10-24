# 0014. Bundle identifier dev.bryann2k.cartouche

One accepted decision for Cartouche. Read by contributors and agents who need to know why. It supersedes the bundle identifier in ADR 0002.

## Status

Accepted, 2026-10-19. Supersedes ADR 0002 in part: only the bundle identifier changes. The name, the data and log folders and the icon stand.

## Context

ADR 0002 gave `app.cartouche.Cartouche`. That is a reverse-DNS name on a domain nobody on the project owns. Change P0 chose another identifier before the first release.

## Decision

The bundle identifier is `dev.bryann2k.cartouche`, on bryann2k.dev, a domain the maintainer owns. The release build, `app/Info.plist` and the app-identity spec use it. The designated requirement of every release names it.

## Alternatives rejected

- `app.cartouche.Cartouche`. Rejected: no one owns the domain.
- `com.github.<user>.cartouche`. Rejected: it ties the identity to a GitHub account.

## Consequences

- The identifier must not change after the first release. macOS ties permissions and Keychain items to it and to the signing certificate.
- Documents that gave the old identifier are corrected.
