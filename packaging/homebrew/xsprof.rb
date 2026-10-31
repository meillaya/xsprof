# Template formula. Replace @VERSION@, @SHA256_ARM64@, and @SHA256_X86_64@
# with the release values.
class Xsprof < Formula
  desc "Read-only Linux scheduler and memory profiler"
  homepage "https://github.com/meillaya/exa"
  version "@VERSION@"
  depends_on :linux

  on_arm do
    url "https://github.com/meillaya/exa/releases/download/v#{version}/xsprof-#{version}-linux-aarch64.tar.gz"
    sha256 "@SHA256_ARM64@"
  end

  on_intel do
    url "https://github.com/meillaya/exa/releases/download/v#{version}/xsprof-#{version}-linux-x86_64.tar.gz"
    sha256 "@SHA256_X86_64@"
  end

  def install
    bin.install "bin/xsprof"
    (share/"xsprof").install "share/xsprof/web"
    (share/"xsprof").install "share/xsprof/fixtures"
  end

  test do
    assert_match "xsprof", shell_output("#{bin}/xsprof help")
  end
end
