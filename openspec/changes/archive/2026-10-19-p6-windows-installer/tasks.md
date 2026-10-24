# Tasks

## 1. Analysis

- [ ] 1.1 Bundle innoextract (pinned, zlib license) and call it from InstallerKit; existing tests still pass
- [x] 1.2 Optional-part handling (orange) vs required (red); unit tests with manifest fixtures
- [x] 1.3 Game identification via the compatibility data name index; tests with 10 folder names
- [ ] 1.4 Prove no execution during analysis with `eslogger exec` capture; save output in evidence.md

## 2. Install runner

- [ ] 2.1 Fresh prefix per game, Rosetta, Inno arguments (/DIR, /LANG, /LOG, mode); integration test with a small sample Inno installer built in CI
- [x] 2.2 Progress from folder size, CPU sampling, stuck watchdog; tests with a fake installer process
- [x] 2.3 Background mode with activity and notification; UI test

## 3. Failure handling

- [x] 3.1 Log parsing for unarc/ISDone errors and exit codes; tests with recorded log fixtures
- [x] 3.2 Retry fixes (verify, threads, memory via CLS.ini overrides, short path, runner); test each changes the next run's inputs

## 4. Result

- [x] 4.1 Executable ranking from .lnk targets, Uninstall registry key and sizes; tests with fixture trees
- [x] 4.2 Redistributable mapping to winetricks verbs; unit tests
- [x] 4.3 Show in Steam shortcut and cleanup to Trash with confirmation; UI test

## 5. Acceptance

- [ ] 5.1 Evidence per scenario, including one real multi-part Inno installer run by the user on their Mac; TROUBLESHOOTING doc by the docs agent; `openspec validate p6-windows-installer --strict` passes
