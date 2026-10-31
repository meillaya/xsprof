# Template cask. Replace @VERSION@ and @SHA256@ with the release values.
cask "xsprof-app" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/meillaya/xsprof/releases/download/v#{version}/Xsprof-#{version}-macos.zip"
  name "Xsprof"
  desc "Read-only scheduler and memory profiler"
  homepage "https://github.com/meillaya/xsprof"

  app "Xsprof.app"
end
