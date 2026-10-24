# Tasks

## 1. Setup model

- [x] 1.1 Per-game setup store with defaults from the global settings; unit tests for read, write and invalid pairs
- [x] 1.2 Backend manifest (DXMT, DXVK) with download and SHA-256 check; tests with fixtures

## 2. Launch

- [x] 2.1 `compat_run.sh` applies DLL overrides and env per backend; shell test (`make compatcheck`) extended per backend
- [ ] 2.2 Launch a DirectX 11 test game with each backend; record loaded libraries per backend in evidence.md

## 3. Steam

- [ ] 3.1 Register one tool per valid pair with "<runner> · <backend>" names; verify in Steam's menu (screenshot)
- [x] 3.2 Write the per-game choice through SpecifyCompatTool and read it back; test both directions

## 4. Mac or Windows version

- [x] 4.1 Detect native macOS builds from appinfo; unit test with appinfo fixtures
- [ ] 4.2 Switch versions and verify the depot Steam installs (Windows vs macOS) on one real game

## 5. Acceptance

- [ ] 5.1 Evidence per scenario; `openspec validate p3-graphics-backends --strict` passes
