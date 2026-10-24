# Task: fix the Sparkle updater configuration error at launch

Repo: the current directory (Cartouche), branch fix/sparkle-config.
The release app logs at every launch (2026-10-21):
  [org.sparkle-project.Sparkle] Fatal updater error (5): For security reasons, SUVerifyUpdateBeforeExtraction needs to also be enabled if SURequireSignedFeed is enabled for Cartouche.
So updates are dead. Find where the Info.plist keys are set (app Info.plist template, Makefile BUNDLE_APP/plutil steps, packaging/), add SUVerifyUpdateBeforeExtraction = YES next to SURequireSignedFeed (keep SUPublicEDKey etc.), and check the rest of the Sparkle settings against Sparkle 2's docs/source in the checkout (app/.build/checkouts/Sparkle if present): feed URL, EdDSA key presence, automatic checks setting that ADR/RELEASE docs specify. Add/extend a test or a `make` check (e.g. the existing buildcheck/settingscheck style) that fails if SURequireSignedFeed is set without SUVerifyUpdateBeforeExtraction.
Also list in the report the open P0/P9 release tasks you can see (openspec/changes/archive/2026-10-19-p0-rebrand-cartouche/tasks.md 1.8–2.0, …p9-release-pipeline/tasks.md) and which ones are code vs maintainer steps (keys, accounts), without doing them.
Finish with a short report: files changed, test/check output, the release-task list.

Rules (same as the Claude implementers): never push. NEVER run git add, commit, merge, stash, checkout or reset: read-only git only; the orchestrator stages and commits. Do not install software. Tests use fixtures and a scratch HOME; never touch the user's real ~/Library, ~/Documents, Steam, Keychain, RetroArch, emulators or store accounts. No piracy wording, no ROM/BIOS/key links, no DRM circumvention, never bundle D3DMetal/GPTK. Keep edits to shared files small and additive. New UI strings get zh-Hans and it translations in app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings, in xcstringstool's exact format (json.dumps(indent=2, separators=(",", " : "), sort_keys=True, ensure_ascii=False), empty dicts as `{\n\n}`, no trailing newline), never rewriting existing entries. SwiftUI work follows the existing views and mockup/launcher.html (Apple design, no AI slop). English UI.

## Building and testing inside your sandbox
Your shell can only write inside this worktree. Always `export TMPDIR="$PWD/.tmp" && mkdir -p "$TMPDIR"`. For Swift use `S="--disable-sandbox --cache-path $PWD/.swiftpm/cache --config-path $PWD/.swiftpm/config --security-path $PWD/.swiftpm/security"` and run `(cd app && swift test --no-parallel $S)`. Vision OCR and WKWebView fail in the sandbox: ignore those failures. Known baseline: 34 payload-related failures that also fail on main. Remove .tmp/.swiftpm/scratch at the end.

Finish with a short report: tasks done and not done with reasons, test results, things to review.
