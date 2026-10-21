# 0024. One Add Games entry point

## Status

Accepted, 2026-10-20. Implementation is in progress: UI on `phase/liquid-glass-pass`, backend on `phase/archives`.

## Context

Separate Windows Games and Console Games entry points ask the user to classify files before Cartouche inspects them. They also duplicate navigation and drop handling.

## Decision

The toolbar + opens one Add Games sheet with a drop zone and Choose… for files or folders of any type. Dropping files or folders on the library window opens the same sheet. Remove separate Windows Games… and Console Games… entries. Automatic detection routes to the existing Windows installer, installed-game import, console ROM import or other matching flow. The UI uses the existing DropClassifying protocol; DropClassifier supplies the backend described in ADR 0023.

## Alternatives rejected

Do not keep a platform-choice menu before file selection. Do not give library-window drops a separate import path. Console configuration through Add Consoles remains separate from adding game files.

## Consequences

The game-library, windows-installer and console-library specs share this entry contract. Back from a detected flow returns to the common sheet, not a removed Windows/Console selector. Old mockup notes about switching between those modes are superseded by docs/research/unified-add-games.md. UI and backend integration are not yet complete.
