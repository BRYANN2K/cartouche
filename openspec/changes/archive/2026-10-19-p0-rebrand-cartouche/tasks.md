# Tasks

## 1. Identity

- [x] 1.1 Set CFBundleName, CFBundleIdentifier and display name to Cartouche in `app/Info.plist`; verify with `defaults read` on the built app
- [x] 1.2 Rename user-facing strings in `Localizable.xcstrings` and views; verify with a grep that only the About attribution mentions NotProton
- [ ] 1.3 Add the About window attribution and non-affiliation text; verify by screenshot in evidence.md

## 2. Data and logs

- [x] 2.1 Point `SupportPaths` and the dylib to the Cartouche root through one shared constant; verify with a unit test comparing both values
- [x] 2.2 Move logs to `~/Library/Logs/Cartouche`; verify a fresh launch creates the folder
- [x] 2.3 Prove coexistence: install NotProton and Cartouche, launch Cartouche, record `stat` of NotProton files before and after in evidence.md
- [x] 2.4 Rename Cartouche's names inside Steam from `cartouche_identity.h` and keep Install, Repair Steam and Remove Everything off NotProton's files; verify with `CoexistenceTests` on a fixture Steam and `IdentityTests.steamNamesShareTheHeader`

## 3. Updates

- [ ] 3.1 Generate the Cartouche EdDSA key pair; store the private key as the `SPARKLE_PRIVATE_KEY` repository secret; put the public key in Info.plist
- [x] 3.2 Set `SUFeedURL` to the Cartouche releases appcast; verify with `defaults read`
- [ ] 3.3 Test a foreign-signed appcast is rejected; record Sparkle's log line in evidence.md

## 4. Icon and docs

- [ ] 4.1 Build the app icon from `mockup/brand/` sources (Default, Dark) and the menu bar template glyph; verify in Finder and Dock in both modes
- [x] 4.2 Update README, NOTICE and LICENSE header with credit, GPL-3.0 and non-affiliation; verify by reading them in review

## 5. Acceptance

- [x] 5.1 Fill evidence.md with one entry per scenario in `specs/app-identity/spec.md`; `openspec validate p0-rebrand-cartouche --strict` passes
