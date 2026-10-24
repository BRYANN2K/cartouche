# Task: fix a crash: synchronous process runs (lsof/pgrep) inside SwiftUI view updates

Repo: the current directory (Cartouche), branch fix/menu-busy-crash.

## Crash (real, release build, 2026-10-21 01:04)
EXC_CRASH SIGABRT, AttributeGraph precondition failure in AG::Graph::value_set during ViewGraph.beginNextUpdate / NSHostingView.layout. Faulting stack (app frames):
GamePanel.pcBody → GamePanel.block(_:_:) → closure in HStack → GameMenu.items(for:in:stores:installs:) → InstallCenter.isBusy(with:in:) → InstallCenter.isPrefixInUse → PrefixStore.isInUse(root:pfx:...) → PrefixStore.serverIsBusy → Shell.run(...drainTimeout:)
and, on the same main thread earlier: CartoucheApp.start → LibraryModel.watch(every:) → SteamLibraryImporter.isRunning → SteamBundle.isRunning → Shell.processIsRunning(named:pgrep:) → Shell.run.
Shell.run spins the run loop / blocks while SwiftUI is computing a view body, so state is mutated during the graph update.

## Fix
1. Never run processes (lsof, pgrep, anything via Shell.run) from a view body, a computed property used by a view, or GameMenu.items. GameMenu.items must be pure and cheap: compute the uninstall item's disabled state from already-known state (an observable per-game busy flag maintained off the main thread, refreshed when the panel/menu appears and when installs or game launches change). The full lsof check stays in GameActionRunner.removeInstalled before the confirmation (off the main thread, then hop back).
2. SteamBundle.isRunning / LibraryModel.watch: move the pgrep off the main actor (Task.detached / a background queue) and publish the result on the main actor; keep the watch interval behavior.
3. Grep for other Shell.run / Process waits reachable from views or the main actor during updates (e.g. PrefixStore.isInUse, processIsRunning callers) and fix the same way; list them in the report.
4. Tests: GameMenu.items does not call the busy probe (inject a probe that fails the test if called synchronously); the uninstall item reflects the cached busy flag; Steam presence updates arrive on the main actor without blocking.
Run `(cd app && swift test --no-parallel $S --filter 'GameMenu|Uninstall|Library|Steam')` then the full app suite: only known environmental failures allowed.

Finish with a short report: files changed, every synchronous call site you moved, test summary lines.

Rules (same as the Claude implementers): never push. NEVER run git add, commit, merge, stash, checkout or reset: read-only git only; the orchestrator stages and commits. Do not install software. Tests use fixtures and a scratch HOME; never touch the user's real ~/Library, ~/Documents, Steam, Keychain, RetroArch, emulators or store accounts. No piracy wording, no ROM/BIOS/key links, no DRM circumvention, never bundle D3DMetal/GPTK. Keep edits to shared files small and additive. New UI strings get zh-Hans and it translations in app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings, in xcstringstool's exact format (json.dumps(indent=2, separators=(",", " : "), sort_keys=True, ensure_ascii=False), empty dicts as `{\n\n}`, no trailing newline), never rewriting existing entries. SwiftUI work follows the existing views and mockup/launcher.html (Apple design, no AI slop). English UI.

## Building and testing inside your sandbox
Your shell can only write inside this worktree. Always `export TMPDIR="$PWD/.tmp" && mkdir -p "$TMPDIR"`. For Swift use `S="--disable-sandbox --cache-path $PWD/.swiftpm/cache --config-path $PWD/.swiftpm/config --security-path $PWD/.swiftpm/security"` and run `(cd app && swift test --no-parallel $S)`. Vision OCR and WKWebView fail in the sandbox: ignore those failures. Known baseline: 34 payload-related failures that also fail on main. Remove .tmp/.swiftpm/scratch at the end.

Finish with a short report: tasks done and not done with reasons, test results, things to review.
