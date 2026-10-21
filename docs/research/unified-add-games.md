# Unified Add Games mockup notes

Accepted direction, 2026-10-20. See ADR 0024. UI merged in a47ffd3 / 51a8ece; InstallerKit backend classification is merged in 95b4e47, but the app adapter is not wired. The UI explicitly shows detection unavailable until that backend is supplied.

The toolbar + opens one Add Games sheet. It has a drop zone and Choose… for files or folders of any type. Dropping on the library window opens the same sheet. Automatic detection selects the installer, installed-game import, console ROM import or other matching flow.

Remove separate Windows Games… and Console Games… entries and any Windows/Console selector before file selection. Back from identification returns to the common sheet. Add Consoles still configures consoles; it is not a separate way to pick game-file types.

This supersedes the mode-switch advice and old separate-sheet inventory in mockup/AUDIT.md. Do not implement its old “switch from Console Games to Windows Game” navigation. Mockup source edits belong to the frontend owner.

UI: the phase/liquid-glass-pass branch, merged in 51a8ece. Backend: DropClassifier on phase/archives, behind the existing UI DropClassifying protocol. Shared archive rules are in ADR 0023 and openspec/specs/archive-import/.
