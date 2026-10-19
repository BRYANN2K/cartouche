# Releasing Cartouche

How a Cartouche release is built, signed and published, and what the maintainer sets up once. Read by the maintainer and by contributors who change the release pipeline.

## Signing certificate

Every release is signed with one self-signed certificate (ADR 0003). Its SHA-1 is part of the app's designated requirement, so macOS keeps controller access, folder access and Keychain items across updates only while the certificate stays the same.

### Create it once

1. Run `packaging/signing/make-cert.sh ~/CartoucheSigning` on your Mac. The folder must be outside the repository; the script refuses otherwise.
2. It writes `cartouche-signing.p12`, its password, `cartouche-signing.p12.base64` and the certificate in PEM. It prints the SHA-1.
3. In the GitHub repository, Settings > Secrets and variables > Actions:
   - Secret `SIGNING_CERT_P12`: the content of `cartouche-signing.p12.base64`.
   - Secret `SIGNING_CERT_PASSWORD`: the content of `cartouche-signing.password`.
   - Variable `SIGNING_IDENTITY`: `Cartouche Self-Signed` (the certificate's common name).
4. Copy the whole folder to an offline place (an encrypted disk image on a USB drive, for example). Then delete it from the Mac.
5. Put the SHA-1 it printed, in lowercase, on the `cert_sha1=` line of `install.sh` and merge that change. The script refuses any app signed with another certificate, and the release workflow refuses a release whose certificate `install.sh` does not name (test tags only get a warning).

The certificate is valid for 20 years. It does not need to be trusted in any keychain: `codesign` signs with it from a throwaway keychain, as `packaging/tests/signing-test.sh` shows.

### Check it

The release workflow prints the designated requirement of every build. It must read the same for every release:

```
identifier "dev.bryann2k.cartouche" and certificate leaf = H"<SHA-1 of the certificate>"
```

To check two published releases by hand: unzip both, then run `codesign -d -r- Cartouche.app` on each and compare.

### Rotate it

Rotate only if the private key leaked or was lost. A new certificate gives the app a new identity:

- Users must allow controllers, folders and other permissions again, and the Keychain asks once more for store tokens.
- Sparkle still installs the update, because the EdDSA key does not change. Never rotate the certificate and the EdDSA key in the same release: Sparkle needs one of the two to match the installed copy.

Steps:

1. Create a new certificate with `make-cert.sh` into a new folder, with a new name: `CARTOUCHE_CERT_NAME="Cartouche Self-Signed 2" packaging/signing/make-cert.sh ~/CartoucheSigning2`.
2. Replace the two secrets and the `SIGNING_IDENTITY` variable.
3. Say in the release notes of the next release that macOS will ask for permissions again.
4. If the old key leaked, also say which releases were signed with it.

## Sparkle key

The EdDSA private key signs every archive, delta and the appcast. It was created in P0 and its public half is `SUPublicEDKey` in `app/Info.plist`.

- Secret `SPARKLE_PRIVATE_KEY`: the content of the exported key file (one base64 line). Kept as a repository secret, never committed; the `release` and `runner-manifest` workflows read it.
- If it is lost, installed copies can no longer update and a remote runner manifest is no longer trusted. Users must download the next release by hand.

### Runner manifest

The `runner-manifest` workflow publishes the shipped `runners.json` on the `compat-data` release when it changes on `main`. It signs the file with `sign_update` and `SPARKLE_PRIVATE_KEY` — the same key as the appcast — and uploads the signature as `runners.json.sig` next to it. The app fetches both once a day and accepts the remote manifest only when the signature verifies against `SUPublicEDKey`; a manifest whose signature is missing or wrong is refused, and the bundled `runners.json` stays in use.

## Homebrew tap

The tap is the repository `BRYANN2K/homebrew-cartouche`, so users run `brew install --cask bryann2k/cartouche/cartouche`. Set the `TAP_REPOSITORY` variable to use another name.

### Set it up once

1. Create the public repository `BRYANN2K/homebrew-cartouche` on GitHub, with a `main` branch. Copy `packaging/homebrew/tap-README.md` into it as `README.md`.
2. Create a fine-grained personal access token: repository access to `homebrew-cartouche` only, permission Contents: Read and write. Give it an expiry date and a reminder to renew it.
3. In the Cartouche repository, add it as the secret `TAP_TOKEN`.

### What a release does

After the GitHub release is published, the `tap` job fills `packaging/homebrew/cartouche.rb.in` with the version and the SHA-256 from `SHA256SUMS`, writes it as `Casks/cartouche.rb` in the tap and pushes it as BRYANN2K. Betas and test releases do not touch the tap.

### Check it

After a release: `brew update && brew install --cask bryann2k/cartouche/cartouche`, then `defaults read /Applications/Cartouche.app/Contents/Info CFBundleShortVersionString` must print the version just released.

## Publishing a release

1. Set `CARTOUCHE_VERSION` in `dylib/version.h` to the new version, for example `0.1.1`.
2. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.1.1] - <date>` and start a new empty `## [Unreleased]` above it. Add ` (critical)` at the end of the heading for a fix users must not skip, such as a dylib fix after a Steam update.
3. Merge to `main` through a pull request, so the checks run.
4. Tag the merge commit and push the tag: `git tag -a v0.1.1 -m 0.1.1 && git push origin v0.1.1`.

The `release` workflow then:

1. Refuses a tag that does not match `version.h`, has no CHANGELOG section, or is already released.
2. Builds the app with the same job as the pull request checks, tests included.
3. Signs it with the certificate in a throwaway keychain and prints the designated requirement in the job summary.
4. Scans the app and the zip for Game Porting Toolkit files.
5. Downloads the live appcast and the last three archives, and runs `packaging/make-appcast.sh`: Sparkle's `generate_appcast` signs the archive and makes deltas, the older items are kept as published, then `sign_update` signs the whole feed. The app requires a signed feed (`SURequireSignedFeed`).
6. Publishes the GitHub release with `Cartouche-<version>.zip`, `Cartouche-<version>.dmg` (made by `packaging/dmg/make-dmg.sh`, the same signed app with the first-open steps in its window), `SHA256SUMS`, the deltas and `appcast.xml`.

### Checksum for install.sh

`SHA256SUMS` holds one line, `<sha256>  Cartouche-<version>.zip`, in the format `shasum -a 256 -c` reads. Its name never changes, so `install.sh` (P18) can fetch `https://github.com/BRYANN2K/cartouche/releases/latest/download/SHA256SUMS`, take the archive name from it, download that archive from the same folder and run `shasum -a 256 -c SHA256SUMS` before installing.

If the run fails after the tag was pushed, fix the cause and run the workflow by hand (Actions > release > Run workflow) with the tag.

### Tags

| Tag | Publishes | Sparkle channel | Bundle version |
|---|---|---|---|
| `v0.1.1` | A release, the new `releases/latest` | none, every user | `0.1.1` |
| `v0.2.0-beta.1` | A pre-release; the live feed on the latest release gains its item | `beta` | `0.2.0b1` |
| `v0.0.1-test.1` | A normal release, refused once a real release exists | none | `0.0.1t1` |

Sparkle compares the bundle version (`CFBundleVersion`). It reads `0.2.0-beta.1` as equal to `0.2.0`, so the Makefile drops the dash for pre-releases. Sparkle then orders `0.1.1 < 0.2.0b1 < 0.2.0b2 < 0.2.0`. `ReleaseFeedTests` checks this order with Sparkle's own comparator.

Everywhere else, the app (`CartoucheVersion`, used by the Steam install record) and `release.py` (`version_key`) compare the version users see in semver order: `0.1.0 < 0.2.0-beta.1 < 0.2.0-beta.2 < 0.2.0`. Both read `packaging/tests/version-order.txt` in their tests, so they cannot drift apart. The release workflow refuses a tag that is not newer than the last published release.

Users opt into betas in Settings > Receive beta updates (`receiveBetaUpdates` in the app's defaults). The updater then allows Sparkle's `beta` channel at its next check. A user who turns it off keeps the installed beta and gets the next release that is newer.

Test tags exist to try the pipeline before v0.1.0, when nobody runs Cartouche yet. Delete the test releases and their tags afterwards. The first real release drops test items from the feed.

## Upstream watch

The `upstream-watch` workflow runs every night at 04:23 UTC. It reads the latest version of each source below and opens one issue, labeled `upstream`, for each version that `packaging/upstream-watch/supported.json` does not list.

| Source | Read from | Issue title |
|---|---|---|
| NotProton | GitHub releases of NotProtonNot/NotProton | `Upstream: NotProton <version>` |
| Mac Steam client, stable and beta | Valve's `steam_client_osx` and `steam_client_publicbeta_osx` manifests | `Upstream: Steam client <version>` |
| CrossOver source | codeweavers.com/crossover/source | `Upstream: CrossOver source <version>` |
| Wine macOS builds | GitHub releases of Gcenx/macOS_Wine_builds | `Upstream: Wine macOS build <version>` |
| DXMT | GitHub releases of 3Shain/dxmt | `Upstream: DXMT <version>` |
| Game Porting Toolkit | Apple's page (major version) and Gcenx's packaged builds | `Upstream: Game Porting Toolkit <version>` |

- An issue with the same title, open or closed, means the version was reported. The watch opens nothing for it again.
- When Cartouche supports a new version, add it to `supported.json` in the same pull request.
- If a source changes its format, the run fails after checking the others. GitHub then emails the maintainer.
- To check without opening issues: Actions > upstream-watch > Run workflow with "Report only".
- Endpoints and formats: `docs/research/upstream-watch-endpoints.md`.
