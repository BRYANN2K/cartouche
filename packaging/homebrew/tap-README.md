# Homebrew tap for Cartouche

Cartouche is a free game launcher that runs Windows games through Steam Play on Apple silicon Macs. Its source and releases are at https://github.com/BRYANN2K/cartouche.

## Install

```sh
brew install --cask bryann2k/cartouche/cartouche
```

Cartouche is free and signed with its own certificate, not notarized by Apple, so macOS blocks the first open. To open it the first time:

1. Open Cartouche. macOS says it can't check it. Click Done.
2. Open System Settings > Privacy & Security, scroll down, click Open Anyway.
3. Confirm with your password. Updates come through the app itself and do not ask again.

The certificate does not remove this warning, but it keeps updates and the permissions you grant from resetting. The install script in the Cartouche README avoids the warning: https://github.com/BRYANN2K/cartouche#install

## How this tap is updated

The `release` workflow of the Cartouche repository rewrites `Casks/cartouche.rb` with the new version and SHA-256 after each release. Betas are not published here. Do not edit the cask by hand: the next release overwrites it. Change `packaging/homebrew/cartouche.rb.in` in the Cartouche repository instead.
