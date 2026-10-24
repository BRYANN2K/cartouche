# One Add Games entry point

Status: UI merged in a47ffd3 / 51a8ece; backend classifier and integrated verification remain pending. Maintainer decision: 2026-10-20. ADR 0024.

## Why

Users should not have to choose Windows or Console before Cartouche detects their files. The toolbar and window-drop paths should share one sheet.

## What changes

Toolbar + opens one Add Games sheet: drop zone and Choose… for files or folders of any type. Library-window drops open the same sheet. Remove Windows Games… and Console Games… entries. Automatic classification routes to the existing installer/import, console ROM or other matching flow.

UI merged from frontend-sol’s phase/liquid-glass-pass. Until a backend is supplied, the sheet shows “Game detection is unavailable”. Backend owner: phase/archives, implementing DropClassifier behind the existing DropClassifying protocol. Add Consoles remains console configuration, not a competing game-file entry.

## Mockup notes

The old mockup/AUDIT.md mode-switch notes are superseded by docs/research/unified-add-games.md. Mockup source files are outside the documentation owner’s edit scope.
