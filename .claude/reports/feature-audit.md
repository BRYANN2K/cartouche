# Cartouche feature-gap audit (main)

Read-only audit of `main` (2026-10-20). Status describes checked-in code, not proposal intent. “IN-FLIGHT” means the named branch has unmerged commits; it is not DONE. Owner shorthand: Devin = code/backend/installer; Sol = frontend/UI; decision = maintainer/product.

## Highest-priority gaps

1. **MISSING/PARTIAL: store integrations.** Epic/GOG/Amazon adapters exist, but archive P10 evidence/tasks identify cloud saves/comet and real two-Mac validation still outstanding; do not treat mockup/sign-in screens as complete acquisition/install integration. (P10 evidence/tasks)
2. **PARTIAL: game install/import.** Installer supports Windows setup and local imports, but repack direct-unpack/archive intake and mandatory verification remain active unfinished changes; archives branch is substantial but unmerged. (archives, direct-unpack, verified-installs; `phase/archives`)
3. **PARTIAL: performance.** FPS instrumentation and per-game play history exist; full injection/overhead validation remains unchecked; FPS average/details across runner/backend are not established as complete. Sharing is explicitly disabled because no receiving API exists. (P8 tasks/evidence)
4. **DISABLED: Favorites.** Game menu exposes “Add to Favorites” but action is empty and disabled (`AppCommands.swift:180`).
5. **IN-FLIGHT: CrossOver default/first boot.** Main lacks the active spec implementation; `phase/crossover-default` contains it, but real hardware validation remains required.
6. **PARTIAL: free signing, distribution and updates.** Release pipeline tasks for self-signed cert, Sparkle appcast/update testing and Homebrew cask automation remain unchecked (P9); onboarding install.sh/dmg clean-account verification also incomplete (P18).
7. **PARTIAL: controls and Mac permissions.** Controller mapping implementation is present but live Wine/RetroArch checks remain manual/unchecked; permission relaunch/deep-link matrix remains incomplete (P15/P17).
8. **PARTIAL: retro console library.** RetroArch bundle/library and add-console flows exist; evidence/tasks still identify release/reproducibility and final scenario validation not complete (P12/P13).

## Full feature table

| Feature / requirement | Main status | Evidence (source or task/evidence) | Suggested owner |
|---|---|---|---|
| Steam full library import | DONE (local account/library import; not remote cloud API) | `Library/Steam/SteamLibraryImport.swift`, `SteamLocalFiles.swift`; P5 evidence | Devin |
| Epic/GOG/Amazon login + library | PARTIAL | `Stores/{EpicAdapter,GOGAdapter,AmazonAdapter}.swift`; P10 evidence; `p10-store-integrations/tasks.md:16` cloud saves/comet real test outstanding | Devin |
| Store login/sidebar mockup screens | UI PRESENT; actual integration PARTIAL | `mockup/launcher.html`; P10 evidence screenshots; inspect app Store settings | Sol + Devin |
| Mac-native launch option | PARTIAL / verify scope | game setup/Steam app metadata supports Mac versions; P3 evidence `SteamAppInfoTests.macBuilds`, `SetupMenuTests.macVersion`; no evidence all native games route correctly | Devin |
| Favorites star | DISABLED/PLACEHOLDER | `AppCommands.swift:180` empty action, `.disabled(true)` | Sol + Devin |
| Grayscale cover for uninstalled games and progressive color reveal | DONE | `Activity/Reveal/CoverReveal.swift`, `RevealShader.swift`; `ActivityCenter.swift:69`; P7 evidence | Sol |
| Download progress/activity and pause/cancel | PARTIAL | `Activity/ActivityCenter.swift`; Steam command support `SteamDownloadCommands.swift`; P7 `tasks.md:6` Steam progress/pause/cancel integration unchecked | Devin |
| FPS average / per runner+graphics detail | PARTIAL | `Performance/{PerformanceModel,PerformanceStore,PlayStats,YourPlayViews}.swift`, `fps-counter`; P8 `tasks.md:6-7` injection/accuracy checks unchecked | Devin |
| Performance history (“more”) | PARTIAL | same performance files; archive P8 evidence verifies local data/settings but no complete runner/backend comparison evidence | Devin + Sol |
| ProtonDB anti-cheat reports (Linux semantics) | DONE | `Compatibility/AntiCheatSummary.swift:1,20,46-49`; `CompatData.swift:73-82` | Devin |
| Uninstall per source | PARTIAL | `Installer/GameUninstall.swift`, `Model/Uninstall.swift`, Steam uninstall URL in `Activity/SteamDownloadCommands.swift:52`; no evidence unified uninstall across Epic/GOG/Amazon/local/console | Devin |
| Controller handling | PARTIAL | P15-controls implementation; P15 `tasks.md:9,15` live Wine mapping and Mac driver checks remain | Devin |
| MCP/agent tools | PARTIAL | `app/Sources/CartoucheMCP/MCPServer.swift`, channel transports; archived P11 evidence says full documentation deferred; audit tool parity for install/settings not demonstrated | Devin |
| RetroArch frontend + consoles | PARTIAL | `Consoles/ConsoleCenter.swift`, `ConsolePanel.swift`, `AddConsolesSheet.swift`; P12/P13 tasks include CI bundle/evidence still open | Devin + Sol |
| Per-console add / auto-detect ROM folder / “sources” rename | PARTIAL | `Consoles/AddConsolesSheet.swift`, `GameFolderWatch.swift`; P13 archive evidence/tasks, confirm exact UI label and settings path | Sol + Devin |
| Sparkle update | PARTIAL | P0 `tasks.md:18-20` key/appcast/foreign-signature tests unchecked; P9 release tasks unchecked | Devin |
| Homebrew update/install | PARTIAL | P9 `tasks.md:19` tap/cask automation unchecked; P18 onboarding cask caveats | Devin |
| Onboarding + permission restart | PARTIAL | `Onboarding/{OnboardingModel,OnboardingView}.swift`; `Permissions/RelaunchService.swift`; P17 tasks 1.3/2.5 incomplete; P18 install evidence incomplete | Devin + Sol |
| Free signing / Gatekeeper install | PARTIAL | P18 `tasks.md:5,7`; install.sh/dmg clean macOS 15/26 acceptance not recorded | Devin |
| Landing page link in About | MISSING/VERIFY | P0 task 1.3 attribution/non-affiliation is unchecked; confirm actual About external link | Sol |
| Statistics sharing | BLOCKED / DEFERRED BY TECHNICAL LIMIT | P8 evidence: destination/API unavailable; toggle disabled and reports stay local (`PerformanceSharing.macGamingDB == nil`) | decision (defer) |
| Cover art search + store screenshots carousel | DONE/PARTIAL | `Library/CoverStore.swift`, `Views/CoverSearchSheet.swift`, `Views/GameMediaCarousel.swift`; validate image-source coverage | Sol + Devin |
| Repack installer (.exe + .bin) | PARTIAL / IN-FLIGHT | `Installer/InstallEngine.swift`, bundled `Resources/payload/unarc-driver.exe`; active `direct-unpack` and `verified-installs` unchecked; P6 evidence/tests and tasks leave real multi-part Inno run outstanding | Devin |
| Already-installed game detection | PARTIAL | `Installer/GameMatcher.swift`, `InstalledGame.swift`; `unified-add-games/tasks.md:6-9` automatic detection integration unverified | Devin |
| Archive drag-and-drop | IN-FLIGHT | Main `Library/Drop/DropViews.swift`; `openspec/changes/archives/tasks.md:3-13` all unchecked; `phase/archives` has decompressor/classifier implementation | Devin |
| Verification (full/partial/unavailable; Verify Files) | MISSING / IN-FLIGHT | `verified-installs/tasks.md:3-10` all unchecked; `direct-unpack/tasks.md:9`; `phase/verify-ui` has no commits ahead per `git log main..phase/verify-ui` | Devin |
| Steam export/owned list refresh | IN-FLIGHT | `steam-export/tasks.md:9-10` real Steam/account-switch checks outstanding; branch `phase/steam-export` | Devin |
| Store integration cloud saves | PARTIAL | P10 task 3.2 unchecked; real two-Mac run maintainer step in evidence | Devin / decision for credentials |
| Statistics sharing default | DEFERRED BY DECISION (recommended) | P8 evidence explicitly disables because no API; should remain opt-in/deferred, no upload endpoint | decision |
| UI menus, settings/context menu states | PARTIAL | archived P5 evidence explicitly notes Add Games, store sign-in, Your Play buttons disabled pending later version; native game menu favorites disabled (`AppCommands.swift:180`) | Sol |
| CrossOver pinned runner as default, boot serialization/retry | IN-FLIGHT | `crossover-default/tasks.md:4-10`; branch `phase/crossover-default` has one commit; hardware validation required | Devin |
| Archives extraction and classification | IN-FLIGHT | `archives/tasks.md:3-13`; branch `phase/archives` includes CArchive, InstallerKit Archive/DropClassifier and tests | Devin |
| Menu busy crash | NO CHANGE IN BRANCH | `git log main..fix/menu-busy-crash` empty | Devin |
| Verify UI | NO CHANGE IN BRANCH | `git log main..phase/verify-ui` empty | Sol + Devin |

## Source-of-truth notes

Reviewed the chronological user-request log, fork plan/brainstorm, PRD/roadmap/ADRs, mockup, archived task/evidence files and active OpenSpec changes. The archived tasks remain unfinished despite directory names containing `archive`. UI mockup presence is not evidence of app behavior. P8 sharing is blocked by absent MacGamingDB submission API; defer rather than claim support. In-flight statuses are based on requested `git log main..<branch> --stat`; branches `phase/archives` and `phase/crossover-default` have commits; requested `fix/menu-busy-crash` and `phase/verify-ui` have none.
