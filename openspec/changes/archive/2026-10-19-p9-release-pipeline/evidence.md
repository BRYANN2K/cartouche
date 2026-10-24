# Evidence: p9-release-pipeline

Branch `phase/p9-release-pipeline`, from main a81a5b1, with main 3febbf1 (P1 and P17) merged in. Machine: Apple silicon, macOS 27, Xcode 27.0, Swift 6.4, Python 3.14, Sparkle 2.10.0 tools from `app/.build/artifacts`. Nothing was pushed, tagged or run on GitHub, and no secret was set.

Local app builds use `make -o app-payload app`: the real build minus the payload, which needs Dobby and the Wine bridge built in CI.

## Tests

| Suite | Before (main a81a5b1) | After |
|---|---|---|
| `make -s app-tests` | 554 tests in 60 suites, 34 fail (43 issues) | 656 tests in 77 suites after merging main 3febbf1, the same 34 fail (43 issues) |
| Hermetic C suites from `app.yml` (19), `mincheck`, `l10ncheck`, `runcheck`, `scriptcheck` | 23 pass (`mincheck` and `l10ncheck` after a local app build) | 23 pass |
| `make -s l10ncheck` | 433 strings | 509 strings with main merged, all translated (same one zh-Hans string left in English) |
| `make -s packagingcheck` (new) | – | pass: redistribution scan test, workflow check, signing test, 50 Python tests |
| `make -s redistscan` (new) | – | pass, no toolkit file in the repository |
| `openspec validate --all --strict` | 19 passed | 19 passed |

- The 34 failing Swift tests are the ones that need the staged payload ("This build carries no components at all"). The sorted list of failing test names is identical before and after (`diff` empty).
- New Swift tests: `ReleaseFeedTests.swift` ("Release feed", 4), `UpdateChannelTests.swift` ("Update channel", 5, one of them run twice with arguments) and `VersionOrderTests.swift` ("Version order", 6).
- New Python tests under `packaging/tests/`: `test_release.py` (29), `test_appcast.py` (9), `test_upstream_watch.py` (12).
- `runcheck` and `scriptcheck` skip here because shellcheck is not installed. The new shell scripts pass `sh -n`. They have not been through shellcheck; `lint.yml` runs it in CI.
- actionlint is not installed. `packaging/tests/workflow_check.py` stands in: it parses every workflow, checks jobs, steps, `needs`, reusable workflow triggers, and runs `bash -n` on every `run` block. It is not a substitute for actionlint.
- No test was deleted or skipped.

## Review fixes

- **Version order.** `DeploymentContent` compared versions with `String.compare(options: .numeric)`, which puts `0.2.0-beta.1` after `0.2.0`: a beta user would have been refused the release as older. `CartoucheVersion.compare` (semver order) now does all three comparisons, and `release.py version_key` orders the same way. Both are tested against the shared list `packaging/tests/version-order.txt` (`0.0.1-test.1 < 0.0.1-test.2 < 0.0.1 < 0.1.0-dev < 0.1.0 < 0.1.1 < 0.2.0-beta.1 < 0.2.0-beta.2 < 0.2.0-beta.10 < 0.2.0 < 0.10.0 < 1.2.0`). Test `VersionOrderTests.betaToRelease`: installed `0.2.0-beta.2`, bundled `0.2.0` gives `.update`; the reverse gives `.newerInstalled`, with a build record or a legacy `dylib.version` alike. `release.py meta` now refuses a tag that is not newer than the last published release (`test_a_release_must_be_newer_than_the_last_one`).
- **Version 0.1.0.** `dylib/version.h` says `0.1.0` instead of NotProton's `1.2.0`. The local build reports `Built out/Cartouche.app (0.1.0)`, `CFBundleShortVersionString` and `CFBundleVersion` are `0.1.0`. Nothing else read the old number: `release.py`, the Makefile and the dylib's log line read the header. Test `VersionOrderTests.versionHeader` keeps it a 0.x version that a release tag can carry.
- **NotProton 1.2.0 on the same Mac.** This Mac has NotProton deployed: `~/Library/Application Support/notproton/dylib.version` is `1.2.0` and its `install-build.json` records `1.2.0`, while `~/Library/Application Support/Cartouche` holds neither. Cartouche reads `SupportPaths.deployedVersion` and the record beside it, both under its own folder since P0. Test `VersionOrderTests.notProtonRecordIsIgnored` builds the same layout in a scratch folder: Cartouche 0.1.0 reads no record and is `.current`; the same inspection fed NotProton's file would have answered `.newerInstalled`, which is what the separate folders prevent.

## Scenarios

### Pull request checks / Red check blocks merge
- Check: `.github/workflows/ci.yml` runs on every pull request and on main. Jobs: `app` (calls `app.yml`: full build, the 19 hermetic suites, `packagingcheck`, `make -s app-tests`, a scan of the built bundle), `lint` (calls `lint.yml`), `openspec` (`openspec validate --all --strict` with OpenSpec 1.14.3 pinned), `redistribution` (scans the repository, then proves the scan still catches a planted file). The `required` job passes only when every job's result is `success`.
- Check: command `evidence/gate-check.sh`, which runs the `required` job's script on sample results.
- Result: `success success success success -> exit 0`, `success failure success success -> exit 1`, `success skipped success success -> exit 1`, `cancelled success success success -> exit 1`. A failing unit test makes `make -s app-tests` exit 2 (seen on main with the 34 payload tests), so the `app` job fails and `required` fails.
- Check: test `packaging/tests/redist-scan-test.sh`
- Result: pass. A clean tree and a clean zip pass. `D3DMetal.framework/Versions/A/D3DMetal`, `libd3dshared.dylib` and `Game Porting Toolkit 3.0.dmg` are each caught in a folder and inside a zip without folder entries, and the report names the file.
- Result: needs CI for the merge block. MAINTAINER steps:
  1. Merge this branch, then set GitHub > Settings > Branches > Add rule for `main`: Require a pull request, Require status checks to pass, required check `required` (from the `ci` workflow), Require branches to be up to date.
  2. If no self-hosted `xcode-27` runner exists, set the repository variable `MACOS_RUNNER` to a GitHub-hosted macOS image (for example `macos-26`) and `XCODE_APP` to its Xcode path. Otherwise the `app` job waits for a runner that never comes.
  3. Open a pull request that changes one expectation, for example `#expect(UpdateChannel.betaDefaultsKey == "receiveBetaUpdates")` to `"x"` in `UpdateChannelTests.swift`.
  4. Expected: the `app` job fails at "Run the Swift tests", `required` fails, and the Merge button says merging is blocked. Save a screenshot as `evidence/red-check.png`. Close the pull request.

### Stable free signing / Identity is stable
- Check: test `packaging/tests/signing-test.sh` (in `packagingcheck`). It creates a throwaway certificate with `packaging/signing/make-cert.sh`, imports it with `import-cert.sh` into a temporary keychain, signs two different builds with `sign-app.sh`, and compares `codesign -d -r-`.
- Result: pass. Both builds print `identifier "dev.bryann2k.cartouche" and certificate leaf = H"<SHA-1 of the certificate>"`, the hash equals the certificate's SHA-1, and an ad-hoc signature is refused. The keychain search list is the same before and after; the login keychain is not used.
- Check: command `evidence/dr-check.sh`. It builds the real app twice with `make -o app-payload app APP_VERSION=0.0.1-test.1` and `…test.2`, signs both copies through `packaging/signing/` with one throwaway certificate, and runs `codesign -d -r-`, `codesign -dv` and `codesign --verify --deep --strict`.
- Result: pass on two real builds:
  ```
  == 0.0.1-test.1: 0.0.1-test.1 / 0.0.1t1
  designated => identifier "dev.bryann2k.cartouche" and certificate leaf = H"a2c4766460e4239705b6738a0eefd106b5686c03"
  verify --deep --strict: ok
  == 0.0.1-test.2: 0.0.1-test.2 / 0.0.1t2
  designated => identifier "dev.bryann2k.cartouche" and certificate leaf = H"a2c4766460e4239705b6738a0eefd106b5686c03"
  verify --deep --strict: ok
  keychain search list unchanged
  designated requirements identical
  ```
- Result: needs CI for two published releases. MAINTAINER steps:
  1. Create the certificate and secrets as in `docs/RELEASE.md` > Signing certificate, and `SPARKLE_PRIVATE_KEY`.
  2. Set `CARTOUCHE_VERSION` to `0.0.1-test.1`, add a `## [0.0.1-test.1]` CHANGELOG section, merge, tag `v0.0.1-test.1`, push the tag. Repeat with `0.0.1-test.2`.
  3. In each run's summary, read "Designated requirement". Or download both zips and run `codesign -d -r- Cartouche.app` on each.
  4. Expected: both lines are identical and end in the SHA-1 printed by `make-cert.sh`. Paste both in this file.

### Stable free signing / Permissions survive an update
- Check: none possible here. It needs two published, signed releases and a clean Mac account.
- Result: pending maintainer. MAINTAINER steps, after the two test releases above:
  1. On a new macOS user account (15 and 26), install `v0.0.1-test.1` with `curl -fLO <zip url>`, unzip, move to /Applications, open it (Open Anyway if asked).
  2. Connect a controller and let a game see it (this needs P17 or a Steam game for the controller prompt), and store an Epic token once P10 exists. Until then, record which permissions the app has in System Settings > Privacy & Security.
  3. Cartouche > Check for Updates…, install `0.0.1-test.2`, let it relaunch.
  4. Expected: `defaults read /Applications/Cartouche.app/Contents/Info CFBundleShortVersionString` prints `0.0.1-test.2`, the permissions listed in step 2 are still on, no Keychain prompt appears, and no Gatekeeper prompt appears at relaunch. Record `xattr -l /Applications/Cartouche.app` and `codesign -d -r- /Applications/Cartouche.app` before and after.

### Updates / Update offered
- Check: test `packaging/tests/test_appcast.py` (`AppcastChain`). It runs `packaging/make-appcast.sh` with Sparkle's real `generate_appcast` and `sign_update` for four releases in a row (`0.0.9-test.1`, `0.1.0`, `0.2.0-beta.1`, `0.2.0` critical), fake signed bundles and a throwaway EdDSA key, fetching older archives the way `release.yml` does.
- Result: pass, 9 tests. Every archive and delta has `sparkle:edSignature`. The `0.2.0` item has deltas from `0.1.0` and `0.2.0b1`, and `deltas.txt` lists the files to upload. Older items keep their own release URL (`…/v0.1.0/Cartouche-0.1.0.zip`). Release notes are embedded per item. The `0.2.0` item carries `sparkle:criticalUpdate`. Test items leave the feed at the first real release. `sign_update --verify` accepts the feed and refuses it after one URL is changed.
- Finding: Sparkle's `generate_appcast` points every item it sees at the new release's download folder. Older archives live in their own release, so `release.py merge-appcast` keeps the new item from `generate_appcast` and every older item exactly as published. Without that, every older download link would break at each release.
- Check: tests `ReleaseFeedTests` ("Release feed")
- Result: pass. `SURequireSignedFeed` is true in `app/Info.plist`, so the app refuses an unsigned feed. Sparkle's own comparator orders `0.0.1t1 < 0.0.1t2 < 0.1.0 < 0.1.1 < 0.2.0b1 < 0.2.0b2 < 0.2.0b10 < 0.2.0 < 0.10.0`. It reads `0.2.0-beta.1` as equal to `0.2.0`, which is why the Makefile writes `0.2.0b1` into `CFBundleVersion` for that tag (checked through `make -p`).
- Check: test `packaging/tests/test_release.py` (`Tags`, `Notes`, `Merge`)
- Result: pass. A tag that does not match `dylib/version.h`, a missing or empty CHANGELOG section, an unsigned archive or delta and a wrong download URL all stop the release.
- Result: needs CI and maintainer for the daily check, install and relaunch. MAINTAINER steps:
  1. With the secrets set, publish `v0.0.1-test.1` and then `v0.0.1-test.2` as above.
  2. Install `0.0.1-test.1` on a clean account with the zip from the release, open it once (Open Anyway).
  3. Leave it running, or set `defaults write dev.bryann2k.cartouche SULastCheckTime -date "2000-01-01 00:00:00 +0000"` and relaunch to force the daily check.
  4. Expected within 24 h: Sparkle's window shows `0.0.1-test.2` with the CHANGELOG section as release notes; Install Update relaunches into `0.0.1-test.2`; `xattr -p com.apple.quarantine /Applications/Cartouche.app` prints "No such xattr"; no Gatekeeper dialog. Save `evidence/update-offered.png`.
  5. Delete both test releases and tags afterwards (`docs/RELEASE.md` > Tags).

### Updates / Beta channel
- Check: test `UpdateChannelTests.sparkleHonorsTheChannel` (arguments `false`, `true`). A real `SPUUpdater` for a fake copy at `0.1.0` reads, over HTTP on 127.0.0.1, a feed with release `0.1.1` and beta `0.2.0-beta.1` (`sparkle:channel` beta, bundle version `0.2.0b1`). Its delegate is the app's `UpdateChannelDelegate`.
- Result: pass. Not opted in, Sparkle finds `0.1.1`, so the beta is not offered. Opted in, it finds `0.2.0b1`.
- Check: tests `UpdateChannelTests.betaOff`, `betaOn`, `delegateReadsTheSetting`, `toggleSharesTheKey`
- Result: pass. The app's updater reads `receiveBetaUpdates` from the standard defaults at each check, which is the key the Settings toggle writes (`@AppStorage(UpdateChannel.betaDefaultsKey)`).
- Check: test `test_appcast.py` `test_beta_is_on_the_beta_channel_only`
- Result: pass. In the published feed only the beta item carries `<sparkle:channel>beta</sparkle:channel>`.
- Check: screenshots `evidence/settings-updates-light.png` and `evidence/settings-updates-dark.png`, rendered from `UpdatesSettingsView` on macOS 27 with a temporary test that was not committed.
- Result: the pane shows the "Receive beta updates" switch, off, with its explanation, in both appearances. Screenshots on macOS 15 and 26 and the Reduce Motion check are pending maintainer: open Cartouche > Settings… (⌘,) there and save `evidence/settings-updates-<os>-<mode>.png`.

### Homebrew tap / brew installs the latest
- Check: test `test_release.py` `Cask`
- Result: pass. The template fills version and SHA-256, the URL resolves to `https://github.com/BRYANN2K/NotProton/releases/download/v0.1.0/Cartouche-0.1.0.zip` (the archive `release.yml` uploads), and the rendered cask passes `ruby -c`.
- Not run: `brew audit` and `brew style`. Homebrew refuses a cask outside a tap, and a local tap or Homebrew's style gems would change this Mac's Homebrew setup.
- Result: needs CI and maintainer. MAINTAINER steps:
  1. Create `BRYANN2K/homebrew-cartouche` and the `TAP_TOKEN` secret (`docs/RELEASE.md` > Homebrew tap).
  2. Publish the first real release, `v0.1.0`. The `tap` job pushes `Casks/cartouche.rb`.
  3. On a Mac: `brew update && brew install --cask bryann2k/cartouche/cartouche`.
  4. Expected: `defaults read /Applications/Cartouche.app/Contents/Info CFBundleShortVersionString` prints `0.1.0`, and `brew info --cask bryann2k/cartouche/cartouche` shows `0.1.0`. Optional: `brew audit --cask --strict bryann2k/cartouche/cartouche`.

### Upstream watch / New Steam client
- Check: test `test_upstream_watch.py` `test_new_steam_client_opens_one_issue_then_none_the_next_night`. Fake upstream answers equal the 2026-10-19 baseline except a Steam beta manifest at the fake version `1799999999`; a fake tracker stands in for GitHub issues.
- Result: pass. The first run opens exactly one issue, titled `Upstream: Steam client 1799999999`, whose body has `Link: https://client-update.steamstatic.com/steam_client_publicbeta_osx` and `Branch: beta.`. The second run on the same tracker opens nothing.
- Check: the other tests in `test_upstream_watch.py`
- Result: pass. The baseline opens nothing; a closed issue with the same title also stops a new one; the same version on both Steam branches opens one issue; each of the six sources (NotProton, Steam, CrossOver source, Wine macOS builds, DXMT, Game Porting Toolkit from Apple's page and from Gcenx) opens its own titled issue; drafts and pre-releases are skipped; a source whose page changed fails alone and the run exits 1; issues are listed with `state=all` across pages, and the label is created first, ignoring `422 already exists`.
- Not run here: a live run against the real endpoints. The endpoints and formats were checked by the research agent on 2026-10-19 (`docs/research/upstream-watch-endpoints.md`).
- Result: needs CI for the live run. MAINTAINER steps:
  1. After merge, Actions > upstream-watch > Run workflow with "Report only" checked.
  2. Expected: every source prints "supported" or "already reported", and the run is green. A red run names the source whose format changed.
  3. Run it again without "Report only" the day Steam ships a client not in `supported.json`: one `Upstream: Steam client <version>` issue appears. The next nightly run opens no second one.
