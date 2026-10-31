# Template formula. Replace @VERSION@, @SHA256@, and the URL with the release.
class Xsprof < Formula
  desc "Read-only Linux scheduler and memory profiler"
  homepage "https://github.com/meillaya/exa"
  url "https://github.com/meillaya/exa/releases/download/v@VERSION@/xsprof-@VERSION@-linux-x86_64.tar.gz"
  sha256 "@SHA256@"

  def install
    bin.install "bin/xsprof"
    (share/"xsprof").install "share/xsprof/web"
    (share/"xsprof").install "share/xsprof/fixtures"
  end

  test do
    assert_match "xsprof", shell_output("#{bin}/xsprof help")
  end
end
