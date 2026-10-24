# Tasks

## 1. Catalog and detection

- [x] 1.1 Emulator catalog (bundle IDs, launch arguments) from the research file, each argument verified against the emulator's docs; unit tests
- [x] 1.2 Detection and version reading; tests with fixture bundles

## 2. Launch

- [x] 2.1 Per-console emulator setting and launch; integration test with Dolphin and one homebrew test file
- [x] 2.2 Fallback when the emulator is missing; UI test

## 3. Acceptance

- [x] 3.1 Evidence per scenario; `openspec validate p16-standalone-emulators --strict` passes
