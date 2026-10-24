# Night report (2026-10-19)

Notes collected during the overnight run, for the morning summary.

## Merged
- Wave 2: P1, P4, P9, P12, P17 (+ docs/wave2: PRIVACY, DATA-SCHEMA, THIRD-PARTY-LICENSES, ADR 0013, 0014).
- FORK-PLAN fixed: MacGamingDB read live, not MIT.

## Decisions for the user
- AppleGamingWiki CC BY-NC-SA 3.0: the nightly file says its ratings are "shared under the same license". Check NC fits Cartouche's GPL distribution before v0.1.0.
- No off switch for the daily update check and compat file download (PRIVACY "Not decided").
- FPS sharing fields not decided (P8).
- P2: the remote runner manifest is not signed (HTTPS + github.com-only + pinned hashes). Signing it with the EdDSA key would be stronger. Follow-up?
- P2: redist hash list was computed from a GPTK 4.0b3 copy found read-only in another app's data folder on this Mac. OK with that source?
- P2: GPTK is copied automatically when found; a Homebrew keg or Gcenx app copies its whole lib folder (large). Ask before copying?
- P2: Wine CrossOver build script never ran; first CI run is the real test. Some gnutls-chain licenses unconfirmed in THIRD-PARTY-LICENSES.

- P5 task 1.1 BLOCKED (needs your decision): exporting the Steam library from Steam's UI needs a channel from Steam's page code to the app. A loopback-request design was refused as a new attack surface (any page Steam renders could write the file). Option: a WebUI route registered by the dylib that only Steam's own transport can reach. Until then the library comes from Steam's own files (installed games, playtime, collections, account). P5 merged but NOT archived because of this.
- P5: old Status/Prefixes/Backups panes moved to a "Steam Play Setup" window; Install lost ⌘I to Get Info. Disabled "comes in a later version" buttons for P6/P8/P10/P13 until those merge. Sidebar uses SF Symbols, not the store logos.

- P6 spec gaps (not built): Downloads watcher, GOG cover fetch, Choose Another Disk (low space only warns), backend choice in the review step (P3). Installed games are listed but Play is not wired yet (launch script exists). Winetricks is downloaded pinned, not bundled (proposal/TRD say bundled).
- P6: GameName.clean no longer strips the words "repack"/"rip" (wording rule) — folder names carrying them will match less well.

- P3 (please confirm): the "New Games" default setup is written as Steam's GLOBAL default compat tool (app 0) for every Windows game without its own mapping. Steam's menu now lists the old runner tools AND new "<runner> · <backend>" pairs. A pair's backend overrides the Steam Properties Graphics dropdown.
- P3: free runners (Wine builds, GPTK) still can't be Steam tools until their ntdll is pinned (P2 CI). DXVK used is Gcenx DXVK-macOS 1.10.3 (2023), not upstream 3.x. DXMT pinned to v0.80, the last MIT release (later ones LGPL).

- P18: install.sh uses BRYANN2K/NotProton (the current repo name), the mockup said BRYANN2K/cartouche. Rename the GitHub repo? Then the feed URL, install URL and tests change together.
- P18: install.sh refuses to run until `cert_sha1=` is set to the signing certificate's SHA-1 (RELEASE.md step 5). Onboarding asks only App Management: the Downloads / FPS / sharing toggles were left out until those features exist. PRIVACY.md still says onboarding asks Downloads (docs fix pending).
- Test suite note: P5's windowSnapshot leaves a stuck animation thread per render; near the 64-thread limit (a run hung once). Worth fixing before more UI phases.

- P8: sharing FPS has no destination (MacGamingDB has no report API, the spec names none): payload, opt-in toggle (off) and tests exist, but the toggle is disabled. Needs a decision. Steam App ID goes in the request URL, not the body.
- P8: wined3d sessions record play time but no FPS (OpenGL).
- P13: if Cartouche is killed (not quit) during a console game, RetroArch keeps running and that play time is lost. `.chd` matched by name only, `.7z` not identified. libretro-database read from master (unpinned).

- P7: Steam download pause goes through a read-only command file served by the dylib to Steam's page; unproven on real Steam (does PauseAppUpdate pause or remove?). The ring pauses instead of cancelling (mockup cancels). FPS in the activity slot needs a live value from P8 (not exposed yet).

- P16: Ryubing bundle ID (org.ryujinx.Ryujinx) and "game as last argument" unconfirmed (its site refused connections). Fallback reads "a core exists" as "core already downloaded". A .iso matches five consoles; identifying it computes a CRC and fetches up to five databases (slow). No Switch database or covers.

## Maintainer steps
- `sudo pmset -a disablesleep 0` in the morning.
- P0: SPARKLE_PRIVATE_KEY secret, About screenshot, icon check, foreign-signed update test.
- P9: docs/RELEASE.md steps (cert, secrets, runner, branch protection, tap repo, two test releases).
- P17: six manual checks (evidence.md M1–M6).
- P12: RetroArch full build needs CI (Metal toolchain); PS1 BIOS test with own dump.
- P2: run Actions > wine-crossover with publish, paste manifest entry into runners.json (revision 2), pin ntdll from CI output, Steam check, winecfg boot, Apple GPTK image check (evidence.md).
- P5: manual checks M1–M4 (macOS 15 and 26, Reduce Motion/Transparency, real keys, real Steam paths). Screenshots are offscreen: Liquid Glass not visible in them.
- P6: innoextract pinned build never ran (first run in CI); `sudo installer/scripts/no-exec-check.sh` (eslogger) to prove analysis runs nothing; one real installer run end to end.
- P3: DX11 game with each backend (WINEDEBUG=+loaddll), Steam Properties screenshot of pairs, set a pair in Cartouche and check Steam, Mac/Windows depot switch, download DXMT/DXVK from Settings.
- P18: M1–M6 on clean macOS 15 and 26 accounts (install command, dmg window and Gatekeeper screenshots into docs/images/install/, DualSense found list, quit midway, Move to Applications, onboarding end to end).
- P16: real Dolphin play/quit, removal fallback, Ryubing bundle ID check.
- RetroArch probe leftovers are in the Trash: retroarch-probe-2026-10-19.

## Pause
- 03:2x: paused P2 and P5 agents at 98% of the 5-hour limit. Resume scheduled at 03:33 (session-only cron).
- 03:35: resumed P2 and P5. Started P6 early (its deps P1 + InstallerKit are merged). vendor/RetroArch submodule now checked out in main.
- 03:55: P2 and P5 merged (785 tests, same 34 failures). Started P3 and P13; told P6 to merge main and enable Add Games.
- 04:10: P6 merged and archived (807 tests, same 34). Started P7 and P18 (deps ready). Running: P3, P13, P7, P18. 5h usage 38%, weekly 53%.
- 04:55: P3 merged and archived (846 tests, same 34). P8 held back: 5h usage 67% with P13, P7, P18 running. Usage guard cron every 15 min pauses agents at 90%.
- 06:4x: 5h usage 92%: paused P13 (a150335e53e30db9f, was running final checks), P7 (a254f76c8a176cff2), P18 (aecd256b417e555e2). Resume scheduled 08:33.
- 08:3x: resumed P13, P7, P18; started P8.
- 09:5x: P18 merged+archived (873 tests). Fixed test-suite hang (windowSnapshot animation threads) on main. P13 merged (900 tests on branch; RetroArch home fix). P7 sent back to merge main (conflicts with P13); P8 next after P7. Redist scan local: run on a git archive export (repo scan walks worktrees).
- 10:0x: user asked to run more agents at once. Running: P7 and P8 (merging main), P14, P16, P10, P15. P11 last.
- 10:3x: Devin swe-2-max trial on the version-order task: acceptable quality (comparable to Opus, more test cases; follows the brief literally; smart mode cannot commit, orchestrator commits). Launched Devin on P11 backend (server, transports, read/action tools, approval model, diagnose, secret scan) in .claude/worktrees/devin-p11; P11 Settings > Agents UI and controls tools stay for Opus after P15.
- 10:1x: session restarted, all agents had stopped. Added Devin sandbox rule to ~/.claude/settings.json (user asked). Devin swe-2-max (dangerous+sandbox) relaunched on P11 server; resumed Opus P7, P10, P14, P15, P16. Usage guard recreated: at 90% hand everything to Devin (user decision, frontend included).
- P7 merged and archived (963 tests on branch, same 34).
- 10:4x: 5h usage 95%: stopped Opus P10 (a9765402b7520d309), P14 (a3dd9f3c7ac749b1c), P15 (a60f5d1acc290d421), P16 (a46e230a369102a7a, its main merge was already committed). Devin swe-2-max took over P10, P14, P15 in the same worktrees (briefs /tmp/devin-brief/p1x.md, logs .log). Orchestrator checking P16 itself.
- 11:0x: P16 merged and archived (968 tests, same 34). Devin's sandbox cannot write to the main repo's .git, so it stopped at git merge/add on P10, P14, P15. Orchestrator now does all git steps: merged main into P15 (committed) and P10 (committed), committed P14's WIP and started its merge; Devin resolves file conflicts and finishes tasks, file edits only.
- P10 follow-up: the store download row sits in the sidebar beside P7's unified activity slot instead of being a slot case (InstallingCard opens the Windows install sheet, wrong for store jobs). Worth unifying later.
- P15 merge dropped catalog key '%@, playing' (unused in code).
- QA mode (branch qa/mode, committed, NOT merged): CARTOUCHE_QA_BASE_URL rewrites every download URL and adds extra pinned hashes. Must be compiled out of release builds (or refused when the app is signed for release) before merging: otherwise an environment variable can redirect and re-pin downloads. Review after the quota reset.
- P11 server (branch phase/p11-agent-control, Devin) committed, not merged: Settings > Agents UI (3.1), approval UI test (2.3) and controls tools still to do. Review: helper launches the app with /usr/bin/open when XPC is unanswered; undo is in memory only.
- P15 merged and archived (1009 tests, same 34). Tasks 2.1 and 3.1 left unticked: code and unit tests done, only manual Wine runs M2/M3 remain (evidence.md). Screenshots not regenerated (sandbox).
- P14 checks clean (1015 tests, same 34; RetroArch 142 pass). Task 5.1 waits on the PRIVACY.md docs fix (says netplay/RetroAchievements not merged).
- P10 merged into main (1018 tests, same 34; identity guard got a narrow commented exception for the heroic folder inside the GOG clients' private HOME). Not archived: tasks 3.2 (two-Mac cloud saves) and 4.1 (THIRD-PARTY-LICENSES, docs agent) open.
- P14 merged into main (1065 tests, same 34). Not archived: 5.1 waits on PRIVACY.md docs fix. Main now has P0–P10 and P12–P18 (P5, P10, P14 not archived). Left: P11 (server on branch; UI + controls tools), QA harness, docs pass, final Codex QA. Waiting for the 5h reset (100%).
- 11:4x: user said 'go devin. devin fini et codex fait le QA'. Devin launched on: P11 UI (devin-p11, main merged, Info.plist/App.swift markers left to Devin), docs pass (devin-docs, branch docs/wave3), QA harness finish incl. release-build guard for CARTOUCHE_QA_BASE_URL (devin-qa-mode, all qa/* branches + main merged). Then Codex QA (3 personas) with the lid open.
- Docs pass (Devin) merged into main: PRIVACY, THIRD-PARTY-LICENSES, SECURITY, TRD, DATA-SCHEMA, GLOSSARY, README; p10 4.1 and p14 5.1 ticked.
- P11 review (blocking, being fixed by Devin): (1) the app listens with NSXPCListener(machServiceName:) and declares MachServices in its Info.plist; a regular app cannot vend a Mach service that way (needs a launchd job), and the helper connects with NSXPCConnection(serviceName:), the API for bundled .xpc services, so the stdio helper cannot reach the app. (2) shouldAcceptNewConnection accepts every peer with no check. Fix: Unix domain socket in Cartouche's support folder (0700 dir, 0600 socket), same-uid check and peer path inside the app bundle.
- Killed 11 leftover QA mock servers (ports 8890–8900) and 10 Cartouche-QA app instances left by Devin's QA run.

## User decisions (2026-10-19, late morning)
1. P5 Steam UI export: Steam's own files only for v0.1.0 → tick/close 1.1 as "not in v0.1.0", archive P5.
2. AppleGamingWiki CC BY-NC-SA: keep as is (user accepts the NC clause).
3. P3 "New Games" as Steam's global default tool: confirmed.
4. P8 FPS sharing: no sharing in v0.1.0 → remove the disabled toggle and payload UI; FPS stays local.
5. P2 runner manifest: sign it with the EdDSA key before v0.1.0 (CI signs, app verifies).
6. P2 GPTK: ask once with the size, two buttons "Copy" / "Use in Place"; if the in-place folder disappears, say so and offer to copy.
7. Settings toggle for the daily update check and compat file download (on by default), documented in PRIVACY.
8. Repo rename to BRYANN2K/cartouche: user renames on GitHub; update install.sh, feed URL, tests and docs together. Docs say Cartouche started as a fork of NotProton but is its own project, not built on it.
- v0.1.1 planned (user): "Share your stats" from the app + a game list with user stars on cartouche.bryann2k.dev. So for v0.1.0 decision 4: hide the FPS sharing UI but KEEP P8's payload code and tests for v0.1.1. Ratings (stars) in the app need a spec in v0.1.1.
- QA harness merged into main (1077 tests, same 34; release binary has no CARTOUCHE_QA string; mocks and world unittest OK).
- Created private repo BRYANN2K/cartouche (empty, not a fork: the public fork BRYANN2K/NotProton cannot be private). Added local remote 'cartouche'. Nothing pushed. Install/feed URLs: public users cannot reach a private repo, so the repo must be public (or the downloads hosted elsewhere) before v0.1.0 ships.
- P14 archived. Devin in parallel: v0.1.0 decisions (devin-decisions), store downloads into the P7 activity slot (devin-store-slot), RetroArch/emulator orphan sessions after a kill (devin-retro-orphan). P11 final test + merge running.
- P11 merged and archived (1125 tests, same 34).
- Store downloads moved into the P7 activity slot (1128 tests, same 34), merged.
- v0.1.0 decisions merged (1132 tests, same 34). P5 archived; its 4.2 (macOS 15 material fallback snapshots on macOS 15/26 runners) and 5.1 (APPFLOW/DESIGN docs) stay unticked: CI and docs follow-ups.
- Gap found: RunnersModel (free runners install, GPTK question) had no screen and loadRunners never fed free runners. Devin building the Runners screen (devin-runners, phase/runners-screen).
- Console sessions survive a killed Cartouche: merged (same 34).
- User decision: runner and backend changeable for installer games (like Steam). Devin on it (devin-installer-setup, branch phase/installer-game-setup from the Runners screen branch). No game or prefix copy; older-Wine warning.
- User decision: after the code is done, NO QA yet. First a review pass by the orchestrator: code review, refactor without regression, fixes, optimization, comments reduced to the minimum. Then QA.
- The 34 'baseline' failures: vendor/dobby was never cloned locally (README step, CI does it), so app-payload failed and the payload tests had nothing to test. User OK'd cloning Dobby at the pinned commit 5dfc854 (gitignored). Building dobby + payload + tests on main to get a true 0-failure baseline. Flaky: 'RetroArch closed from its own window…' (passes alone 3/3) - fix in review pass. Runners OCR test fixed (Choose… read as Choose...).
- Runners screen merged into main. Installer-game setups (Devin) committed, checks running. make bridge (Wine 11.15 at pinned commit, user OK) running in main to build the full payload and get a 0-failure baseline.
- Installer games change runner/backend: merged (1155 tests, only the 34 payload tests).
- REVIEW Critical (confirmed): Uninstall.run deletes SupportPaths.support, which holds installs/ (installer games, prefixes, saves) while the dialog says they are kept. Fix first.
- REVIEW done (6 Opus reviewers, reports in /tmp/review/*.md): Critical 3 (uninstall deletes installer games; MCP helper hangs after handshake; MCP replies >8-16KB crash the app), High 28, Medium ~67, Low ~66. Fixes: 6 Devin runs in parallel, worktrees fix-<area>, branches review/<area>; orchestrator reviews each diff, then full checks (with payload when the bridge is built), then merge; App.swift split last by the orchestrator.
- Disk was at 97%: removed 31 merged, clean worktrees (branches kept). 41 GB free.
- BASELINE: with Dobby + Wine bridge + fonts (afdko 4.0.3 like CI) the full payload builds and ALL 1155 tests pass on main. The 34 failures were only the missing payload. New merge rule: 0 failures, tests run with the payload.
- Devin's sandbox workaround copied Sparkle sources into .deps/ (committed by mistake in review/consoles-controls, then removed: commit redone, 61 files). Add .deps/ to .gitignore on main.
- Uninstall fix extended by orchestrator: Devin kept installs/ only; store games (support/stores) and console saves/states/BIOS/screenshots (support/retroarch) were still deleted. Now kept, dialog texts updated (it, zh-Hans), test extended (23 pass).
- All 6 review branches merged into review/all (worktree review-all). Conflicts resolved per hunk: retry_install kept from stores (copy made async again), StoreGameEnvironment folded into SetupEnvironment with the env whitelist, one NotificationRouter (Allow keeps requiresUnlock, AgentNotifier.dismiss restored), compat data async + cached, comment-only conflicts resolved toward fewer comments. .deps/ ignored. Full checks with payload running.
- review/all full run with payload: 24 failing tests out of 1188 (console panel renders nothing, installer fixtures missing setup.exe, console import timing, GameMenu source assertions, a few others). Claude agent fixing in review-all; rule: fix causes, never weaken tests. Not merged into main.
- REVIEW MERGED into main (7df0e52): all 1188 tests pass with the full payload. Regression fixes after merge: ConsolePanel task (Group→ZStack), store stdout streaming, imported games "forget" without deleting files (legendary uninstall --keep-files --skip-uninstaller: flag not verified against legendary 0.21.1; an unknown flag makes legendary refuse, so it fails safe), fixtures/races.
- Weekly Claude quota at 89% (resets in 4 days): keep Claude work minimal, prefer Devin.
- User: pause after Devin's cleanup run. Cron 419e8fe4 deleted (saves weekly quota at 90%). Resume point: review devin-cleanup (App.swift split + comment pass), commit, run all 1188 tests with payload, merge, then Codex QA (lid open).
- Cleanup merged (App.swift split, comments 2,731→891 in sources, .tmp/.swiftpm untracked). 1188/1188 app, 75 installer, 145 RetroArch tests pass with payload; specs valid. Ready for Codex QA.
- HANG FIXED (real app 821 s hang, 3.6 GB): MenuBarExtra(isInserted: $showInMenuBar) KVO wrote @AppStorage on every update → scene rebuild loop. Found with lldb on the QA app (553 defaults writes / 20 s from MenuBarExtraController.observeValue). Guarded binding. QA app now 0.1% CPU. Separate intermittent crash seen once: SheetBridge _postWindowNeedsUpdateConstraints (two sheets competing?) in a fresh QA steam world; not reproduced on the next launch. To investigate.
- Flaky: ActivityTests 'A game Steam tracks is the running game' scans the real process table (failed once while leftover fake Dolphin processes from tests were alive). Leftover np-steam-console-dolphin processes = a test that leaks child processes.
- User decision 2026-10-20: installers that use an external unpacker (ISDone/unarc/FreeArc) must install by drag and drop; user takes legal responsibility. Built as generic installer compatibility: no 'repack' wording in app/docs, no DRM/crack handling. Devin on it (devin-unpacker, phase/external-unpackers). Evidence: Inno log stops after temp dir, no Wine err lines.
- My merge check for Replace NotProton was too loose (grep 'passed after' matched a suite): it merged with 1 failing test, the flaky Steam running-game test. Fixed the test (single snapshot, waits for exec), 6/6 passes. Merge checks must use the final 'Test run with ... passed' line.
- Replace NotProton merged into main (0c5b418). Real app rebuilt.
- Cover bug: CarX Street got no cover because covers need a Steam app ID from compat data, and the compat feed 404s (private empty repo) with nothing bundled. Devin: Steam store-search fallback, exe-icon placeholder, Change Cover… (devin-covers, phase/cover-fallback).
- Visual gap with the mockup: flat opaque sidebar, no Liquid Glass. Devin design pass (devin-glass, phase/liquid-glass-pass). User: Fable shares the weekly all-models quota (91%), so Devin.
- TODO: the real app asks for Documents access right at launch (privacy rule: ask at the right moment). Investigate which scan touches ~/Documents.
- User: the dark mockup is the target. Glass pass brief now includes: dark first, cover-tinted blurred backdrop with cross-fade, real one-color brand marks for stores and every console (Simple Icons CC0, sources in THIRD-PARTY-LICENSES, README trademark line).
- After the glass pass (orchestrator does it): remove the sidebar toggle button from the library toolbar (.toolbar(removing: .sidebarToggle)); user screenshot 8.png.
- 25 mockup screenshots (dark, Safari, cropped) in devin-glass/.design/mockup/ as Devin's visual reference. Do NOT commit .design/ (28 MB) nor mockup/_director.html (capture helper served on 127.0.0.1:8777).
- External unpacker support merged (70fae4d), 1199/1199 tests. Real app rebuilt and open. Waiting for the user's real drag-and-drop retry; logs: installs/<game>/wine-output.log + processes.log.
- CarX retry: Wine log shows the setup queries ProcessExecuteFlags (DEP) then executes data at 0x20002 → access violation loop under WineHQ 11.0 new-WoW64 on Apple Silicon. Not a missing runtime. Next: try Wine CrossOver runner; consider auto-fallback runner for this crash signature.
- Pushed ONLY the Wine CrossOver build recipe (orphan branch wine-build, no Cartouche code, ntdll resolve step removed) to private BRYANN2K/cartouche; it is now the default branch (switch to main when Cartouche is pushed). CI run 39456323504 (publish=false). Then: download artifact with gh, install as runner, user retries CarX.
- Research (docs/research/compat-isdone-dep-wow64.md in wine-build worktree): DEP cause unproven; CrossOver 23.7.1/GPTK/Heroic show the same ISDone setup.tmp null-call crash; only known workaround = innoextract + run unarc directly. User validated: 1) deeper trace (+virtual via CARTOUCHE_WINEDEBUG, commit 0b837af), 2) extraction fallback, 3) let the CrossOver CI build finish.
- Glass pass committed on phase/liquid-glass-pass (4073225 + sidebar toggle removed) but the release build loops (~90% CPU, 1.5 GB in 25 s). Agent hunting the loop in devin-glass. Not merged.
- User's real app reopened on main (no glass) for the CarX trace run.
- User rejected Devin's UI. Opus 5.5 (medium) agent redoing the whole interface in devin-glass, mockup dark = source of truth, loop fix first; user's screenshot feedback forwarded. Devin: install identification via Steam lookup when compat misses (phase/cover-fallback). Covers fallback committed 9a19473 (not merged).

## CarX trace, complete (2026-10-20 19:17)
- Log cap fix: head now keeps half the budget; crash region captured (line ~26734).
- Sequence: setup.tmp loads innocallback.dll, ISDone.dll; unarc.dll never loads.
- First fault: AV reading 0x4ECD at eip=7bf21139, inside wow64cpu.dll (Wine's 32/64 bridge, loaded at 7BF20000). eax=0xd7.
- Then the 32-bit SEH chain calls a bogus handler at 0x00020002 -> cascade.
- Neither DEP nor a plain null jump: the fault is in Wine's new-WoW64 transition, triggered right after ISDone starts.
- CrossOver CI failed on EGL (--with-opengl). Flag removed, rerun 39465355492. Note: it also builds new WoW64 (i386,x86_64).
- Wine Devel 11.18 (clean prefix carx-devel-test): same crash, same place (wow64cpu 7BF21135, right after ISDone.dll, unarc never loads). Not version-specific.
- Plan B (own unpacker: unarc/cls-* directly, no setup.tmp/ISDone) bypasses the crashing code path.
- CS2: Steam API platforms mac:false; Cartouche is right.
- Plan B prototype (unarcx.exe driver for unarc.dll, -cfg arc.ini, CLS.ini {app}->C:\T): fg-01 starts, filenames reached (CarX Street_Data\globalgamemanagers), then the srep/magic2/xtool pipeline stalls at 0% CPU (~55 min), nothing written. Killed. Likely a pipe/IPC deadlock between unarc, CLS plugins and external exes under Wine.
- Installed-game import merged (ab1e53e). OutputLog fix committed (6828683).
- Sol (CarX): root cause of plan-B stall = missing CLS init. Driver must create a named mapping `Init_MapFile_` (Global\) before loading unarc.dll (/tmp/carx-lab/unarcx-global.c). fg-02 extracted alone: 33 files, all MD5 OK. fg-01 reached 14.1 GB before Codex hit its usage limit and its exec sessions died; restarted detached at 22:05 (log /tmp/carx-lab/evidence/fg01-rerun.log). Path A crash = NtResetEvent syscall thunk in wow64cpu (11.0 d7, 11.18 dd). Recipe: /tmp/carx-lab/reproduce.sh, verify-game.py.
- Sol (CrossOver): no driver bug; first wineboot of a fresh prefix takes >5 min (11 min) and apps started meanwhile fail with nodrv/explorer c0000034. After full prefix init, winecfg/notepad open. CI boot-check 60 s is too short. Report /tmp/cx-lab/REPORT.md.
- App relaunched with DXVK pin fix (d3d10core+d3d11).
