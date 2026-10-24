cask "cartouche" do
  version "0.1.0"
  sha256 "88d1fe9fdfb6b9963e3b6f93c7bd106139e9328ffdcf0f1da39c321b2effe2cb"

  url "https://github.com/BRYANN2K/cartouche/releases/download/v#{version}/Cartouche-#{version}.zip"
  name "Cartouche"
  desc "Game launcher for Windows games through Steam Play on Apple silicon"
  homepage "https://github.com/BRYANN2K/cartouche"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Cartouche.app"

  caveats <<~EOS
    Cartouche is signed with its own certificate and is not notarized by Apple,
    so macOS blocks the first open. To open it the first time:
      1. Open Cartouche. macOS says it can't check it. Click Done.
      2. Open System Settings > Privacy & Security, scroll down, click Open Anyway.
      3. Confirm with your password. Updates won't ask again.
    The certificate does not remove this warning, but it keeps updates and the
    permissions you grant from resetting. The install script avoids the warning:
      https://github.com/BRYANN2K/cartouche#install
  EOS

  zap trash: [
    "~/Library/Application Support/Cartouche",
    "~/Library/Caches/Cartouche",
    "~/Library/Caches/dev.bryann2k.cartouche",
    "~/Library/HTTPStorages/dev.bryann2k.cartouche",
    "~/Library/Logs/Cartouche",
    "~/Library/Preferences/dev.bryann2k.cartouche.plist",
  ]
end
