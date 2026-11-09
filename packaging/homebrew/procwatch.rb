cask "procwatch" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Nharu/procwatch/releases/download/v#{version}/procwatch-#{version}.zip"
  name "procwatch"
  desc "Menu bar monitor that flags runaway processes spawned by Claude Code"
  homepage "https://github.com/Nharu/procwatch"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "procwatch.app"

  uninstall signal: [["TERM", "io.github.nharu.procwatch"]]

  zap trash: "~/Library/Preferences/io.github.nharu.procwatch.plist"
end
