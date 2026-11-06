# Template cask. Replace @VERSION@ and @SHA256@ with the release values.
# Only a notarized, stapled app may satisfy this cask; the release workflow
# gates rendering on tools/verify_macos_attestation.py.
cask "xsprof-app" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/meillaya/xsprof/releases/download/v#{version}/Xsprof-#{version}-macos.zip"
  name "Xsprof"
  desc "Read-only scheduler and memory profiler"
  homepage "https://github.com/meillaya/xsprof"
  depends_on macos: ">= :sonoma"

  app "Xsprof.app"
end
