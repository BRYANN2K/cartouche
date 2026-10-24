Review follow-ups for a Devin fix pass after batch-1020 merges:
1. Uninstall: GameMenu.items calls InstallCenter.isBusy -> PrefixStore.isInUse (lsof, up to 2 s drain) synchronously while building the context menu on the main thread. Make it cheap (lock file + cached state) or move it off the main thread; the full check stays in removeInstalled before confirm.
2. Uninstall: copySaves fails if saves/<slug>/<user>/<dir> already exists (second uninstall of the same slug). Use a timestamped folder or merge.
3. Steam offline: SteamAppInfo.apps reads the whole appinfo.vdf (can be 100+ MB) on every import; cache by file mtime.
4. Steam offline: localconfig apps may not be the full owned list (pending research-luna).
5. Runtimes: RuntimeScan only scans the chosen exe dir; Unreal bootstrap exe -> Binaries/Win64/*-Shipping.exe (pending research-luna).
6. Identify + covers: exactly one Steam store lookup path (storeLookup seam vs identificationViaSteam).
Update after research-luna: item 4 -> Devin steam-offline-2 (drop localconfig-as-owned, use stale export). Item 5 resolver: parse *.uproject basename -> <Project>/Binaries/Win64/<Project>-Win64-Shipping.exe, else exe dir; RuntimeScan should scan that. Item 3 covered by steam-offline-2 if appinfo stays.
CrossOver default UX: explicit serialized 'Preparing Windows environment' phase (wineboot -u, then wineserver -w, verify), no Play until done, retry/recreate; no global mscoree/mshtml suppression outside the repair.
Merge note: phase/steam-export vs docs/refresh -> docs-sol owns openspec/changes/steam-export and openspec/specs/game-library/spec.md; keep docs version, forward Devin's spec additions to docs-sol.

CrossOver release published: url https://github.com/BRYANN2K/cartouche-wine/releases/download/wine-crossover-26.3.0-1/wine-crossover-26.3.0-1-x86_64.tar.xz size 149444708 sha256 60400817826a053599193aa290d4e24e97213a743195f4187400bf9c74906887 -> fill in phase/crossover-default runners.json.
Merge note: docs-sol owns openspec/changes/crossover-default; keep docs version over Devin's if both touch it.

Wiring after UI+archives merge: the DropClassifying adapter (phase/archives) must be injected with .environment(\.dropClassifier, adapter) at the library window root; default is nil, no fake production classifier.

APPROVED rule 'verified, or fall back' -> after phase/direct-unpack returns: Devin pass adding verification gate (MD5 or unarc CRC + script sizes), automatic retry with original helpers/settings, last resort guided setup under Wine, helper hash allowlist for native replacements, regression corpus harness (byte-identical compare).

APPROVED verification UX: levels full/partial(sizes)/unavailable; Stop during verify -> not verified; badge 'Installed, not verified' + 'Verify Files…' menu; failure sheet Retry standard (default)/Keep Anyway/Cancel; no skip checkbox. Backend -> Devin verification pass; UI (badge, failure sheet, menu item) -> frontend-sol.

Verification UI API (phase/verify-ui, Sol): app/Sources/NotProtonApp/Library/Verification/GameVerification.swift: @MainActor protocol GameVerificationPresenting: AnyObject, Observable { status(for:), progress(for:), mismatch, verify(Game), stop(_:), retryStandard(_:), keepAnyway(_:), cancelMismatch(_:) }; inject .environment(\.gameVerification, adapter). Devin verification backend must implement it.

APPROVED ORDER (2026-10-21): 1) finish in-flight (menu crash -> merge+rebuild+Steam sync test; crossover merge; archives merge + adapter wiring; verify UI + Devin verification backend). 2) Devin in parallel: Steam downloads progress/pause/cancel (P7); performance comparison per setup runner x graphics + accuracy (P8); console game uninstall; Mac-native launch check. Sol: Compare Setups screen + downloads UI. 3) Later on decision: store cloud saves (P10), 0.1.0 release pipeline (P0/P9/P18).

2026-10-21 ~01:50: user going to sleep. Killed step-2 Devin tasks (steam-downloads, perf-compare, console-uninstall, mac-native) right after start; briefs saved in .claude/briefs/, worktrees kept (empty). Relaunch tomorrow.

Seam (settings rework): requestCompatibilityTool() moved unchanged to Settings > Steam > Advanced; still disabled without setupSource (legacy CrossOver.app source). fix/steam-compat-tools must make it work with Cartouche runners (our Wine CrossOver / WineHQ) or remove it if registration becomes automatic.
