# Tasks

## 1. Frame counter

- [x] 1.1 Frame counter library for x86_64 and arm64 hooking Metal presentation; unit test with a Metal test app
- [ ] 1.2 Injection through the launch script; fallback when refused; integration test on each runner
- [ ] 1.3 Accuracy and overhead runs per backend; numbers in evidence.md

## 2. Sessions

- [x] 2.1 SQLite store for samples and sessions with frontmost and warm-up filtering; unit tests
- [x] 2.2 Weighted averages and per-setup aggregation; tests including the 54 fps case

## 3. UI and sharing

- [x] 3.1 Your Play section and Compare Setups sheet; snapshot tests
- [x] 3.2 Opt-in sharing payload; tests on the payload fields; network capture with sharing off

## 4. Acceptance

- [ ] 4.1 Evidence per scenario; PRIVACY doc updated by the docs agent; `openspec validate p8-performance-tracking --strict` passes
