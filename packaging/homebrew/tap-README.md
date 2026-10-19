# Homebrew tap for Cartouche

Cartouche is a free game launcher that runs Windows games through Steam Play on Apple silicon Macs. Its source and releases are at https://github.com/BRYANN2K/NotProton.

## Install

```sh
brew install --cask bryann2k/cartouche/cartouche
```

Cartouche is signed with its own free certificate and is not notarized. The first time you open it, macOS says it cannot check the app. Open System Settings > Privacy & Security and click Open Anyway. Updates come through the app itself and do not ask again.

## How this tap is updated

The `release` workflow of the Cartouche repository rewrites `Casks/cartouche.rb` with the new version and SHA-256 after each release. Betas are not published here. Do not edit the cask by hand: the next release overwrites it. Change `packaging/homebrew/cartouche.rb.in` in the Cartouche repository instead.
