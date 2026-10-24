# CrossOver Wine first boot

Research snapshot, 2026-10-20. See ADR 0015 for the accepted decision.

A local CrossOver 26.3 experiment found incomplete prefix initialization, not a missing macOS graphics driver. A repair completed with exit code 0 after 670.94 seconds. Ordinary winecfg then opened after a cold start in 37.5 seconds. These are local diagnostic timings on Apple silicon under Rosetta, macOS 27.0 (26A428), not clean-machine benchmarks.

Wine’s internal five-minute boot wait expired while prefix installation continued. A registry file and .update-timestamp did not prove completion. A game launched too soon failed to start Explorer and reported nodrv_CreateWindow. This generic error alone does not prove a driver build defect.

The launcher must serialize setup per prefix, await boot completion, drain the Wine server, check success and only then enable launch. Show “Preparing Windows environment”, logs, cancellation and retry. Interrupted prefixes need repair, not an assumed-ready state. Do not apply the experiment’s Mono/Gecko-disabling overrides to ordinary launches.

Original local evidence: .claude/reports/research-luna.md section 3 and /tmp/cx-lab/REPORT.md. Those paths are session artifacts, not portable release evidence. Preserve the measurements above in docs; keep real-machine first-boot validation on the release checklist.

## CI follow-up (2026-10-20)

Commit `eb1ae1f` on `cartouche-wine/wine-build` separates prefix initialization from the GUI check. CI runs `wineboot -i` with `WINEDLLOVERRIDES=mscoree,mshtml=` (CI only), then waits for `wineserver -w`. The initialization phase has a 20-minute limit, `BOOT_INIT_LIMIT`, and logs elapsed time. Only after successful initialization does CI run the existing 60-second winecfg window check.

Run `39498286344` was started. Its result is not yet recorded here; the change is not evidence that CI passed. The CI-only overrides and initialization limit do not set app launch policy. ADR 0015 still requires a serialized first-boot gate in Cartouche; its warning concerns counting cold initialization inside the 60-second window check, not removing that post-initialization check.

## Publication follow-up

The wine-crossover-26.3.0-1 release was published from tag commit fef50c2, reusing the archive built by CI run 39472948579. That build passed, but its old cold-prefix window check failed. Later changes affected checking and the publication repository name, not the archive. This publication does not resolve the pending result of run 39498286344. See RELEASE.md for the asset hash and size. App default selection and serialized first boot remain in progress on phase/crossover-default.
