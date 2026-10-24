# 0009. Anti-cheat shown as Linux data only

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Superseded by [0035](0035-game-reports-and-mac-anticheat.md), 2026-10-22. The original decision below is retained as history.

## Context

Anti-cheat decides whether online play works. ProtonDB reports and AreWeAntiCheatYet describe Linux, not macOS. EAC and BattlEye use a Linux module that does not exist on macOS. NotProton runs VAC games in Insecure Mode. No Mac evidence exists yet.

## Decision

Cartouche shows anti-cheat information as what ProtonDB and AreWeAntiCheatYet report for Linux, with counts, for example "Online works on Linux, 26 of 26 reports". It never states a macOS outcome and never shows a Mac verdict such as "Blocked by anti-cheat". Every anti-cheat string is reviewed for this wording. Tests on a real Mac (CS2 online, then Elden Ring online) and future user results may later replace Linux data with Mac data.

## Alternatives rejected

- A Mac verdict with a disabled Try Anyway button. Rejected: it claims knowledge Cartouche does not have, and could block games that work.
- Hide anti-cheat information. Rejected: players need the warning.

## Consequences

- The ProtonDB export is ODbL: cite ProtonDB and share derived data under the same license.
- Players still must judge risk themselves. Ban risk is theirs.
- The older text in `FORK-PLAN.md` (the verdict table) is superseded by this decision.
