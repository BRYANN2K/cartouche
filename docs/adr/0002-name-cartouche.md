# 0002. Name the project Cartouche

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

The fork needs a name that does not collide with NotProton. A game cartridge and the oval that frames a name in hieroglyphs are both called a cartouche. The name was free on the Mac App Store, Homebrew and GitHub on 2026-10-18.

## Decision

The project is named Cartouche. The bundle identifier is `app.cartouche.Cartouche`. Data lives in `~/Library/Application Support/Cartouche` and logs in `~/Library/Logs/Cartouche`. The icon is a cartridge seen from the front whose label is a pixel play button. Sources are in `mockup/brand/`. UI copy is in English.

## Alternatives rejected

- Keep the name NotProton. Rejected: the two apps would share data and Sparkle would replace one with the other.
- Other names from the brand studies (`mockup/brand*.html`). Rejected: Cartouche was the maintainer's pick.
- Bundle ID `com.github.<user>.cartouche`. Rejected: it ties the identity to a personal account.

## Consequences

- A domain for the reverse-DNS bundle ID may be registered later. The ID does not need to resolve.
- Clear and Tinted icon variants still have to be made in Icon Composer.
- No leftover NotProton string may appear in the UI, except the attribution.
