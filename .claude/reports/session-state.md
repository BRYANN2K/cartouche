# Session state — 2026-10-21 ~11:45 (orchestrator)
Rules: see memory 'cartouche-routing' + .claude/CONTEXT.md. Devin standalone = swe-2-max; frontend fallback during Codex limit = fusion-claude-opus-5-5-medium-sidekick-swe-2-medium. Docs + translations = Devin. Research = Luna (Aside without -m; GLM free refused by Aside). ui-gate (Sol) checks UI after every merge. Never push (except cartouche-wine).
Devin launch: run_devin(task, worktree, brief) pattern, briefs /tmp/devin-brief/<task>.md (+ copies .claude/briefs/), logs /tmp/devin-brief/<task>.log. I commit/merge; Devin can't run git.

## main = fa83720 (tests 1286/1286 at f9bb3d7 night). App built 02:15 (needs rebuild after next merges: make -s libarchive unarc-driver app).
## In-flight Devin (worktree .claude/worktrees/<name>, branch):
- devin-steam-compat-tools fix/steam-compat-tools — BLOCKER: tools dir never written for our runners (only crossover-* clones), Steam shows 0 tools/INSTALL grey; libexport token refused (stale cached page token). Seam: Settings>Steam>Advanced requestCompatibilityTool disabled w/o setupSource.
- devin-local-game-lifecycle fix/local-game-lifecycle — busy reason + Quit/End Wine, wineserver end after game exit, re-identify imported names + Rename.
- devin-steam-downloads, devin-perf-compare, devin-console-uninstall, devin-mac-native (phase/*)
- devin-drop-adapter phase/drop-adapter — wire DropClassifier+libarchive into Add Games
- devin-verify-engine phase/verify-engine — verification engine + fallback (implements GameVerificationPresenting)
- devin-innoextract-110 build/innoextract-110
- devin-main-actor-leftovers fix/main-actor-leftovers (+ console 'played' bug)
- devin-crash-reports feat/crash-reports
- sol-french l10n/french (Devin) — French + glossary docs/l10n/glossary-fr.md
- frontend via Devin Fusion: sol-graphics-menu phase/graphics-menu-hide (ADR 0027), sol-settings-rework phase/settings-rework (Steam + Wine Prefixes in Settings, banner), sol-controller phase/controller-diagram (pad from cartouche-site + L2/R2); sol-ui-gate ui-gate/direct-unpack (swe-2-max)
## Subagents: ui-gate (Sol, persistent, paused until ~12:01 by ChatGPT quota). Deleted: frontend-sol*, docs-sol replaced by Devin. To relaunch after 12:01: Luna research-upscaling (Aside sessions MQw38..., E0TO..., JmCZ... hold results).
## Pending user decisions: onboarding 7-step proposal (see chat; Welcome+scan, Windows games CrossOver+GPTK dmg, Stores, Consoles, Controller, Permissions/storage/privacy, Ready; background tasks; resume after relaunch); compact reply format for agents; Aside model (fund OpenCode Zen / new opencode-go key / default Luna).
## Open bugs seen by user today:
- Add Consoles shows 'Game Boy 4 games found', 'GBA 2 games found', SNES 'Added' though user has none: suspect MacScan scanning repo QA fixtures (qa/world) or worktrees under ~/Documents/Projects/NotProton. consoles.json = ["snes"] (added by earlier QA/test run?). Needs Devin investigation.
- Silksong uninstall disabled = stale wineserver (killed); name raw folder.
## Next after merges: rebuild app; user tests Steam tools/library, Deadlock install, Lost in Random (Add Games), D3DMetal (install Wine CrossOver in Runners); unpack speed benchmark; Advanced panel options after Luna; site captures; release 0.1.0 maintainer tasks (.claude/reports/release-tasks-maintainer.md).

## 12:25 update
- Kernel revival killed all Devin runs at ~12:18; relaunched all 17 detached (nohup) with RESUME header via launch_detached(task, worktree, text, model). No bash notifications: poll /tmp/devin-brief/<task>.log for 'exit='.
- steam-compat: d276841 committed on fix/steam-compat-tools (registration + services-check, checks pass); steam-compat-2 running (token refusal, Wine CrossOver as tool, Advanced button).
- docs-sol bb690c5 merged into main (main = bb690c5); docs-sol + l10n-fr deleted. French review at .claude/reports/fr-review.md, Devin 'french' fixing.
- New: console-scan (fix/console-false-positives). Luna research-upscaling-2 spawned.
- CONTEXT.md has Devin sandbox limits (actool, .gitmodules, Metal): orchestrator runs app build/tests outside sandbox.

## 17:05 update
- Devin lost free SWE-2 (Upgrade to Pro). Code now by Codex Sol 6.1 medium subagents: code-steam, code-2, frontend-sol, l10n-fr, ui-gate.
- main = 9257327: everything from today merged (steam compat + token, advanced options, settings rework, onboarding v2, French rewrite (fr-rewrite.md), innoextract 1.10 hermetic, lifecycle, console uninstall, main-actor leftovers, verify engine, drop adapter, steam downloads, console scan fix, crash reports, controller diagram, graphics hide, perf compare).
- out/Cartouche.app built at 4243f6a (missing On/Off fr only). Dylib deployed to Steam 15:36.
- Lesson: union_xcstrings at ROOT must keep main's fr (fixed helper; restored 317 fr in 9dd64fc).
- Next: l10n-fr review onboarding fr; ui-gate verify Settings/onboarding; user tests Steam/Settings/onboarding; then Lost in Random unpack benchmark, site captures, 0.1.0.

## 18:00
- Codex rate-limited ~3h. All Sol agents deleted (long contexts burned quota 4→78%). Resume from .claude/briefs/handoff-2026-10-21.md with fresh agents, max 2.
- out/Cartouche.app built at b0a048c (everything + final French).

## 22:30 (new session)
- New bugs J (controller in Wine), K (repack cancel leftovers) added to bugs-and-changes. G (switch exe) and I (Steam) reconfirmed.
- Running Sol: steam-token (fix/steam-export-token, wt fix-steam-token: I+H), controller (fix/controller-in-wine, wt fix-controller: J).
- Queue next (max 2): K+G (install lifecycle), A, E/F, B, then WIP chantiers 1-5.
- 22:40 added A update (D3DMetal only in gptk runner) and L (Play->Stop). Queue: K+G, A, L, E/F, B.
- 22:45 user: mods/patches = 0.1.1 (item M). Focus: finish 0.1.0 MVP.
- 23:00 merged fix/steam-export-token (I+H) -> main cb248b2; app-tests running (/tmp/apptests-main.log). Spawned 'install' (K+G, wt fix-install-lifecycle). Needs: build app + dylib, user Repair + restart Steam to verify live export.
- 23:10 merged fix/controller-in-wine (J root cause: Wine bundles sdl2-compat without libSDL3). Spawned 'wine-rev2' (publish cartouche-wine 26.3.0-2 + update runner manifest on build/wine-rev2). Running: install (K+G), wine-rev2.
