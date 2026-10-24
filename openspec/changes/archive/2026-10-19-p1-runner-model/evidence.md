# Evidence: p1-runner-model

Branch `phase/p1-runner-model`, cut from main a81a5b1. Machine: Apple silicon, macOS 27.0, Swift 6.4. No CrossOver is installed on this Mac and `~/Library/Application Support/Cartouche` is empty, so every runner check below uses fixtures.

The app bundle is built with `make -o app-payload app` (the real build minus the payload, which needs Dobby and the Wine bridge built in CI). `mincheck` and `l10ncheck` need that bundle.

## Baseline (main a81a5b1, before any P1 code)

| Suite | Result |
|---|---|
| `make -s app-tests` | 554 tests in 60 suites, 34 fail (43 issues) |
| Hermetic C suites from `app.yml` (19), plus `runcheck`, `scriptcheck`, `mincheck` | 22 pass |
| `make -s l10ncheck` | 433 strings, all translated for zh-Hans and it, except "The trial version is not supported." still English in zh-Hans |

- The 34 failing tests need the staged payload ("This build carries no components at all"). Their names are in `evidence/baseline-failing-tests.txt`.
- `runcheck` and `scriptcheck` skip because shellcheck is not installed here.
- Per-suite results: `evidence/baseline-suites.txt`.

### Steam tool list

The CrossOver tools Steam is offered come from `SupportedRunners.tools` through the list file `CompatToolList.sync` writes, which the dylib reads. With no CrossOver installed here, the baseline is the list for every pinned build: with FEX available (macOS 26), without it (macOS 15), and with each 1.0.x legacy holder. Full output: `evidence/baseline-tools.txt`.

With FEX available, legacy name held by nobody, in order:

1. `cartouche-proton-fex` (27.0.0.40921-fex, fex)
2. `cartouche-proton-fex-rosetta` (27.0.0.40921-fex, rosetta)
3. `cartouche-proton-preview` (27.0.0.40921, rosetta)
4. `cartouche-proton-fex-41069` (27.0.0.41069-fex, fex)
5. `cartouche-proton-fex-rosetta-41069` (27.0.0.41069-fex, rosetta)
6. `cartouche-proton-preview-41069` (27.0.0.41069, rosetta)
7. `cartouche-proton-fex-41073` (27.0.0.41073-fex, fex)
8. `cartouche-proton-fex-rosetta-41073` (27.0.0.41073-fex, rosetta)
9. `cartouche-proton-preview-41073` (27.0.0.41073, rosetta)
10. `cartouche-proton-26.3` (26.3.0.39832, rosetta)

These lists are pinned by `SteamToolListTests.swift` ("Steam tool list baseline", 4 tests, 7 cases), which passes on the baseline code. One test runs `CompatToolList.sync` on a runners folder holding every pinned build and compares the file it writes.

## After (branch head)

| Suite | Before | After |
|---|---|---|
| `make -s app-tests` | 554 tests in 60 suites, 34 fail (43 issues) | 583 tests in 64 suites, the same 34 fail (43 issues) |
| Hermetic C suites (19), `runcheck`, `scriptcheck`, `mincheck` | 22 pass | 22 pass |
| `make -s l10ncheck` | 433 strings, all translated (1 known English in zh-Hans) | 433 strings, the same |
| Steam tool list (`evidence/baseline-tools.txt`) | 6 lists, 63 lines | identical, `diff` empty |

- The failing names are in `evidence/after-failing-tests.txt`. `diff evidence/baseline-failing-tests.txt evidence/after-failing-tests.txt` is empty. Per-suite results: `evidence/after-suites.txt`, and `diff` against `baseline-suites.txt` is empty.
- No existing test file was changed, deleted or skipped: `git diff a81a5b1 --stat -- app/Tests` lists only added files.
- The 29 new tests: `SteamToolListTests.swift` (4), `RunnerModelTests.swift` ("Runner model", 10), `RunnerRegistryTests.swift` ("Runner registry", 11), `CrossOverRunnerTests.swift` ("CrossOver on the runner model", 4).
- No new UI string. Runner reasons reuse strings the catalog already has ("Version %@ not supported (supported: %@)", "Build %@" + ", not supported", "The clone has no Wine loader at %@.", and `RunnerPatcher.verify`'s own lines).
- Tool list after: the dump of `SupportedRunners.tools` for the same six cases, written by a throwaway test and compared with `diff /tmp/p1/after-tools.txt evidence/baseline-tools.txt`: identical.

## Task 2.2: every feature reads the registry

- Check: command `grep -rnwE "CrossOverSource|RunnerStore|SupportedRunners" app/Sources/NotProtonApp | grep -vE "Model/(CrossOverSource|CrossOverLicense|RunnerStore|RunnerInstaller|RunnerPatcher|RunnerSetup|SupportedRunner|NtdllPatcher|Runner|RunnerRegistry)\.swift"`; test `RunnerRegistryTests.featuresReadTheRegistry` (fails if a file outside those names contains `CrossOverSource`, `RunnerStore`, `SupportedRunners` or `CompatToolList.installed`)
- Result: pass, 0 lines. The Status pane (`SystemStatus`, `StatusView`, `CrossOverRow`), prefixes (`PrefixesModel`, `PrefixTools`) and the Steam side (`SteamInstaller`, `DeploymentContent`, `PayloadState`) read through `RunnerRegistry`. `CompatToolList.sync` and `CompatToolList.contents` stay where Steam's list is written and hashed, and `RunnerInstaller`'s remove and template cleanup stay where they are: they write, they do not read runners.

## Scenarios

### Runner registry / CrossOver appears as a runner
- Check: test `CrossOverRunnerTests.crossOverAppearsAsARunner` ("A supported CrossOver in Applications is one CrossOver runner, ready once set up"). The fixture is a `CrossOver.app` in a scratch `Applications` folder: Info.plist, a copy of `/usr/bin/true` ad-hoc signed with the dyld entitlement as the Wine loader, clean ntdll for x86_64 and i386, and Steam builtins in a scratch bridge. Its build (FEX flavor, Rosetta and FEX tools) is pinned to the fixture's own hashes and passed as `pins`. The real `CrossOverSource.discover`, `RunnerInstaller.clone`, `RunnerSetup.prepare` (clone verify, `RunnerPatcher.install`, tool list sync) and `RunnerPatcher.verify` run on it. Only the license check and `NtdllPatcher.stage` are replaced, since both need CodeWeavers' real files.
- Result: pass. Before setup, the registry lists exactly 1 runner: kind `crossOver`, id `90.0.0.1-fex`, version `90.0.0.1`, flavors `[rosetta, fex]`, state `available`, not offered. `apply(.install)` gives `installing(from: available)`. After clone and patch, verify finds nothing, the state is `ready`, and a fresh refresh lists 1 runner, `ready`, offered, flavors `[rosetta, fex]`, aggregate state `.ready(builds: ["90.0.0.1-fex"])`, and both live ntdll hashes equal the patched pins.
- Check: test `CrossOverRunnerTests.sequoiaFlavors`; test `RunnerRegistryTests.crossOverIsARunner` (the real pinned build 27.0.0.40921-fex)
- Result: pass. With FEX unavailable (macOS 15) the flavors are `[rosetta]`. With the real pins: id `27.0.0.40921-fex`, version `27.0.0.40921`, flavors `[rosetta, fex]` on macOS 26 and `[rosetta]` on macOS 15.
- Not checked here: a real CrossOver in `/Applications`. None is installed on this Mac. MAINTAINER steps: install a supported CrossOver (26.3 or a pinned Preview), open Cartouche, Status, click Set Up on its row, wait for "Compatibility tool ready.", then quit. The row must read "Build …" with the green tone. The app log `~/Library/Logs/Cartouche/app.log` has no runner list; the registry state is the row.

### Runner registry / Unsupported build is reported, not used
- Check: test `CrossOverRunnerTests.unpinnedBuildIsReported` (2 cases: the fixture's own pin set, and the shipped `SupportedRunners.all`). The fixture's loader hash is not pinned in either.
- Result: pass. The registry lists 1 runner, kind `crossOver`, state `unsupported(reason: "Version 20990101 not supported (supported: 26.3, 20260821, 20261006, 20261015)")`, `reason` equal to that text, no build, no flavors. `registry.offered` is empty. `apply(.install)` is refused. Setting it up throws `StepFailure` before anything is written: the runners folder does not exist afterwards. After `CompatToolList.sync`, the tool list Steam reads and the tool list games pick from (`RunnerRegistry.tools`) are both empty.
- Check: tests `RunnerRegistryTests.unpinnedIsUnsupported`, `orphanIsUnsupported`, `unreadableIsSkipped`
- Result: pass. Next to a supported install, only the supported build is offered and every tool comes from it. A clone whose build left the allow list is `unsupported(reason: "Build 1.0.0.1, not supported")`. An unreadable copy is left out, as the Status pane already leaves it out.

### Behavior parity with NotProton / Existing tests still pass
- Check: command `make -s app-tests`, the 19 hermetic C suites from `.github/workflows/app.yml`, `runcheck`, `scriptcheck`, `mincheck`, `l10ncheck`; `diff` of the failing test names
- Result: pass. 583 tests, the same 34 fail as on the baseline (they need the staged payload), so every test that passed on the baseline still passes. All 22 other suites pass, as on the baseline. No test was deleted, skipped or edited: the existing CrossOver tests (`CrossOverSourceTests`, `RunnerStateTests`, `RunnerSwitchTests`, `RunnerInstallerTests`, `RunnerPatcherTests`, `CrossOverRowTests`, …) run unchanged.
- Check: test `RunnerRegistryTests.refreshMatchesTheStore`
- Result: pass. On a runners folder with two complete clones, one incomplete and one unpinned, `RunnerRegistry.refresh` gives the same aggregate state as `RunnerStore.state` and the same installed builds as `RunnerStore.installedBuilds`.
- Note: `RunnerPatcherTests` only run on a Mac with a real healthy clone and return early otherwise, here as on the baseline.

### Behavior parity with NotProton / Steam sees the same tools
- Check: tests `SteamToolListTests` (4 tests, 7 cases, written and passing on the baseline before any P1 code); test `RunnerRegistryTests.refreshMatchesTheStore`; command `diff /tmp/p1/after-tools.txt evidence/baseline-tools.txt`
- Result: pass. Names and order are identical for every pinned build with FEX, without FEX and with each of the 4 legacy holders, and the list file `CompatToolList.sync` writes is byte for byte the baseline. The tools of the runners the registry offers equal the tools in that list file.
- Not checked here: Steam's own tool menu with a real CrossOver set up (none on this Mac). MAINTAINER steps: with a supported CrossOver set up on main, `cat "$HOME/Library/Application Support/Cartouche/tools" > /tmp/tools-main`; install this branch's build, open Status once, then `diff /tmp/tools-main "$HOME/Library/Application Support/Cartouche/tools"` must be empty, and Steam > a game > Properties > Compatibility must list the same tools in the same order.

### Damage detection / Modified ntdll is caught
- Check: test `CrossOverRunnerTests.flippedByteIsCaught` ("One flipped byte in a set-up runner's ntdll makes it damaged, and Repair restores the pinned hash"), on the same fixture
- Result: pass. After setup the runner is `ready`. XOR 0x01 on the first byte of the clone's `lib/wine/x86_64-windows/ntdll.dll`, then refresh: state `damaged(files: ["x86_64-windows/ntdll.dll is not the patched copy"])`, reason equal to that line, aggregate state `.unpatched(builds: ["90.0.0.1-fex"], problems: ["90.0.0.1-fex: x86_64-windows/ntdll.dll is not the patched copy"])`. The Status row for it is `.unpatched` with `canSetUp`, so the pane shows "Build …, not patched" with its Repair button (`StatusView.crossOverAction`). Running what Repair runs (clone, which only verifies an existing clone, then prepare) rewrites only x86_64 ntdll (`installed.ntdll == [x86_64Windows]`), the live hash equals the patched pin again, and a refresh gives `ready`.
- Check: tests `RunnerModelTests.refreshFollowsPins`, `RunnerRegistryTests.unpatchedIsDamaged`, `incompleteIsDamaged`
- Result: pass. Refresh moves ready to damaged and back. Every file verify names is listed. A clone with no `lib/wine` is damaged ("The clone has no Wine loader at lib/wine.") and not offered.
