# Tasks

## 1. Clients

- [x] 1.1 Bundle pinned legendary, gogdl, comet and nile with licenses; CI check of their hashes
- [x] 1.2 Store adapter interface (sign in, list, install, update, verify, launch, uninstall); contract tests per store with recorded responses

## 2. Sign-in

- [x] 2.1 Web sign-in sheets and Keychain storage; test that no password field is rendered by the app
- [x] 2.2 Expired token handling; UI test with a forced expiry

## 3. Games

- [x] 3.1 Install/launch through runners and setups; integration test on one free game per store
- [ ] 3.2 Cloud saves (Epic, GOG) and comet for GOG; two-Mac test recorded in evidence.md — automated two-library test passes; the real two-Mac run is a maintainer step in evidence.md
- [x] 3.3 Import existing installs; tests with fixture folders

## 4. Acceptance

- [x] 4.1 Evidence per scenario; THIRD-PARTY-LICENSES updated by the docs agent; `openspec validate p10-store-integrations --strict` passes — evidence.md written, validate passes, and THIRD-PARTY-LICENSES lists the clients under "Downloaded, not shipped" with their pins
