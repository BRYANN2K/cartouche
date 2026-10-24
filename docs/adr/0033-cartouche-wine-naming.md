# 0033. Our Wine build is called Cartouche Wine

## Status

Accepted, 2026-10-21. Supersedes in part 0007, 0015, 0027 and 0032 for the name of our Wine build only. Rename merged on 2026-10-21, pending build and live check.

## Context

Our default Wine build is compiled by our CI from CodeWeavers' CrossOver sources (LGPL). The app and the docs called it "Wine CrossOver". Users could read that as CodeWeavers' paid CrossOver app, or as a build CodeWeavers makes or supports. Neither is true.

## Decision

The build is called Cartouche Wine in all user-facing text: runner name, onboarding, Settings, backend reasons, Steam compatibility tool display names, agent tool text, About credits and docs. The About credits say it is built from CodeWeavers' CrossOver sources (LGPL), is not CrossOver and is not made or supported by CodeWeavers. The name is never translated.

Internal identifiers do not change: runner IDs (`wine-crossover-*`), release asset names, folder names and Steam tool internal names. A manifest that still names the build "Wine CrossOver" is read as Cartouche Wine. CodeWeavers' CrossOver app keeps its own name.

## Alternatives rejected

- Keep "Wine CrossOver": suggests a link with CodeWeavers' product.
- Rename the IDs too: breaks installed runners, existing game records and Steam tool mappings for no user benefit.

## Consequences

Docs, specs and strings use "Cartouche Wine" for our build, and "CrossOver" only for CodeWeavers' app or sources. IDs and paths that contain `wine-crossover` stay as they are. Existing installs keep working without migration.
