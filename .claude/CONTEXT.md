# Cartouche — shared agent context (read this instead of long prompts)
Repo /Users/user/Documents/Projects/NotProton, app "Cartouche" (fork of NotProton): macOS launcher for Windows games (Wine: Cartouche Wine 26.3 default, our build from CodeWeavers' CrossOver sources, WineHQ 11.x; D3DMetal/DXMT/DXVK), Steam integration via injected dylib (dylib/), stores Epic/GOG/Amazon, consoles via RetroArch, installer flows in installer/ (InstallerKit), SwiftUI app in app/.
Rules: never push; never touch the user's real ~/Library data, Steam, Keychain; never kill what listens on port 8765; no piracy wording ("installers with external unpackers"); minimal comments; no process waits on the main actor or in view bodies.
Strings: app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings, xcstringstool format exactly (json.dumps(indent=2, separators=(",", " : "), sort_keys=True, ensure_ascii=False), empty dicts {\n\n}, no trailing newline); languages it, zh-Hans, fr (fr being added).
Build/test: `make -s app-payload`, `make -s app-tests`, `make -s l10ncheck`; in a fresh worktree lacking build/dobby, copy app/Sources/NotProtonApp/Resources/payload from the main checkout. Devin sandbox: export TMPDIR="$PWD/.tmp"; swift test with --disable-sandbox.
Design: mockup/launcher.html (dark), Apple HIG, Liquid Glass. Decisions: docs/adr/ (0015–0027). Reports: .claude/reports/. Follow-ups: .claude/reports/review-followups.md.
Replies: short (≤10 lines): files changed, test summary, open points. No progress chatter.

## Devin sandbox limits (known; do not fight them)
- The sandbox blocks actool (Assets.car), writing `.gitmodules` (Sparkle checkout) and Metal. Do NOT try workarounds (copying .build state, editing workspace-state.json, skip-worktree…).
- Run what works: `make` C checks (dylib/installer), `swift build`/`swift test` for packages that don't need Sparkle (installer/, pure model tests). If app tests can't build, stop there and list the exact commands for the orchestrator to run outside the sandbox.
- Keep the final report ≤10 lines: status (done/blocked), files, tests run + result, commands left for the orchestrator, open points.

## Reply format (all agents, final report only — no progress chatter)
```
status: done | blocked
branch: <branch> (uncommitted ok)
files: A.swift, B.swift, …
tests: <what ran> → <result>; env-only failures: <count/kind>
orchestrator: <commands to run outside the sandbox, or none>
open: <points to review, or none>
```
