 (not done — listing only)

**P0 rebrand** (`2026-10-19-p0-rebrand-cartouche/tasks.md`):

- 1.3 About attribution — code exists (`Attribution.credits`, test passes); open part is the screenshot evidence → **maintainer**.
- 3.1 EdDSA key pair + `SPARKLE_PRIVATE_KEY` secret — pubkey already in plist; key generation + repo secret → **maintainer**.
- 3.3 Foreign-signed appcast rejection + Sparkle log line → **maintainer** (needs running app).
- 4.1 Icon from `mockup/brand/` — `make icon` tooling exists; Finder/Dock verification → **maintainer**.

**P9 release pipeline** (`2026-10-19-p9-release-pipeline/tasks.md`):

- 1.1 PR workflow — `ci.yml` is wired (build, tests, `openspec validate --strict`, redist scan); branch protection + failing-PR proof → **maintainer**.
- 2.1 Signing cert — `packaging/signing/make-cert.sh` + `import-cert.sh` exist (code); create cert, store secrets, rotation doc → **maintainer**.
- 2.2 Release workflow — `release.yml` complete (code); verify with `v0.0.1-test` tag → **maintainer**.
- 2.3 Identical designated requirement across releases → **maintainer**.
- 2.4 Update test on a clean account → **maintainer**.
- 3.2 Homebrew tap — cask template + tap bump job exist (code); create `homebrew-cartouche` repo + token + `brew install --cask` verify → **maintainer**.
- 5.1 Evidence + RELEASE/CHANGELOG + `openspec validate` → **maintainer/docs**.
exit=0
