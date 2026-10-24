# Tasks

## 1. Status

- [x] 1.1 Game Controller framework monitor (connect, battery); unit tests with simulated controllers

## 2. Remapping

- [ ] 2.1 SDL mapping builder and launch environment for Wine games; test on a controller test app in Wine (code and unit tests done; the Wine run is manual check M2 in evidence.md)
- [x] 2.2 RetroArch remap file writer; test that RetroArch loads it
- [x] 2.3 Steam games route to Steam Input; UI test

## 3. Keyboard and mouse

- [ ] 3.1 Wine Mac driver keys per prefix; test Command-C reaches the game as Control-C (code and unit tests done; the Wine run is manual check M3 in evidence.md)
- [x] 3.2 Controller-to-keyboard helper with Accessibility check and frontmost gating; tests

## 4. Couch mode

- [x] 4.1 Focus navigation with a controller across library, panel and Play; UI test with a simulated controller

## 5. Acceptance

- [x] 5.1 Evidence per scenario; `openspec validate p15-controls --strict` passes
