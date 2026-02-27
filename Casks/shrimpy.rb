cask "shrimpy" do
  version "1.1.0"
  sha256 "850e1060b7efdf1794d11b329579c8a080f4baa4730b761de2da03c9969f8d52"

  url "https://github.com/liam-hitchcock-dev/homebrew-shrimpy/releases/download/v#{version}/Shrimpy-#{version}.zip"
  name "Shrimpy"
  desc "macOS menubar notifier for Claude Code"
  homepage "https://github.com/liam-hitchcock-dev/homebrew-shrimpy"

  app "Shrimpy.app"

  postflight do
    system_command "/usr/bin/open",
                   args: ["-gj", "#{appdir}/Shrimpy.app"]
  end
end
