# 0027. Hide unavailable graphics backends

## Status

Accepted, 2026-10-21. Supersedes the Graphics reason-line UI in the crossover-default contract. Runtime eligibility and Apple-file distribution rules are unchanged. UI implementation is merged in 522d4fa.

## Context

Wine CrossOver is the default runner and enables D3DMetal/DXMT eligibility. Showing unavailable choices and repeated reason lines adds clutter to the game panel.

## Decision

Hide unavailable graphics backends. Graphics menus list only offered backends. Remove unavailable-backend reason lines from the game panel and menus. Show one “Get More Graphics Backends…” entry only when something is missing; it leads to installing Wine CrossOver. Onboarding preselects Wine CrossOver.

D3DMetal still requires CrossOver-capable Wine, Rosetta and the user’s own D3DMetal files. DXMT still requires CrossOver and its download. Hiding a choice does not relax these requirements or permit distributing Apple files.

## Alternatives rejected

- Keep disabled backend rows with reasons in the menu.
- Repeat missing-backend explanations in the game panel.
- Always show Get More Graphics Backends when all backends are already offered.

## Consequences

Update the crossover-default UI contract without changing existing runtime checks. The earlier reason-line implementation is historical evidence, not the target UI. This decision does not specify a new default backend or change existing per-game runner choices.
