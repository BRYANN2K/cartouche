# Tasks

## 1. Wine CrossOver (built by our CI)

- [ ] 1.0 CI job building Wine CrossOver from the pinned CodeWeavers source tarball; artifact published with SHA-256 and source offer; verify by running `wine --version` from the artifact

- [x] 1.1 Add the runner manifest format and the first pinned build; unit test parses it and rejects a wrong hash
- [x] 1.2 Download, verify and unpack into the runners folder; integration test with a local fixture archive
- [ ] 1.3 Resolve and pin ntdll RVAs with `ntdll-patch/resolve.py`; patcher tests cover the new build
- [ ] 1.4 Boot `winecfg` in a fresh prefix; record time and screenshot in evidence.md

## 2. Game Porting Toolkit

- [x] 2.1 Detect the user's GPTK install and version; unit tests with fixture folders for found and absent
- [x] 2.2 Add the CI redistribution scan (file names and hashes); prove it fails on a planted fixture, then passes

## 3. Steam integration

- [ ] 3.1 Launch a Steam API game through the free runner; record lsteamclient log line and Steam "running" state

## 4. Acceptance

- [ ] 4.1 Evidence per scenario; THIRD-PARTY-LICENSES updated by the docs agent; `openspec validate p2-free-runners --strict` passes
