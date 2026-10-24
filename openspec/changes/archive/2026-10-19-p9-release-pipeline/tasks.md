# Tasks

## 1. CI

- [ ] 1.1 PR workflow (build, tests, `openspec validate --all --strict`, redistribution scan); branch protection on main; verify with a deliberately failing PR

## 2. Signing and release

- [ ] 2.1 Create the self-signed code signing certificate; store it as an encrypted secret; document rotation in RELEASE
- [ ] 2.2 Release workflow on tag: build, sign, zip, appcast with EdDSA and deltas, GitHub Release; verify with v0.0.1-test
- [ ] 2.3 Check the designated requirement is identical across two test releases; record outputs
- [ ] 2.4 Update test from one release to the next on a clean Mac account; record permissions and Keychain behavior

## 3. Channels and tap

- [x] 3.0 Publish the release SHA-256 next to the zip so `install.sh` (P18) can verify it; test with a tampered file

- [x] 3.1 Beta channel in the appcast and the Settings toggle; test both settings
- [ ] 3.2 Tap repository and automatic cask bump; verify `brew install --cask`

## 4. Upstream watch

- [x] 4.1 Nightly watch with de-duplicated issues; test with a fake upstream version

## 5. Acceptance

- [ ] 5.1 Evidence per scenario; RELEASE and CHANGELOG docs by the docs agent; `openspec validate p9-release-pipeline --strict` passes
