# Template formula. Replace @VERSION@, @SHA256_ARM64@, and @SHA256_X86_64@
# with the release values. Rendered by tools/update_homebrew_tap.sh.
class Xsprof < Formula
  desc "Read-only Linux scheduler and memory profiler"
  homepage "https://github.com/meillaya/xsprof"
  version "@VERSION@"
  license "MIT"
  depends_on :linux

  on_arm do
    url "https://github.com/meillaya/xsprof/releases/download/v#{version}/xsprof-#{version}-linux-aarch64.tar.gz"
    sha256 "@SHA256_ARM64@"
  end

  on_intel do
    url "https://github.com/meillaya/xsprof/releases/download/v#{version}/xsprof-#{version}-linux-x86_64.tar.gz"
    sha256 "@SHA256_X86_64@"
  end

  def install
    bin.install "bin/xsprof"
    (share/"xsprof").install "share/xsprof/fixtures"
    (share/"applications").install "share/applications/xsprof.desktop"
    (share/"icons/hicolor/scalable/apps").install "share/icons/hicolor/scalable/apps/xsprof.svg"
    bash_completion.install "share/bash-completion/completions/xsprof" => "xsprof"
    zsh_completion.install "share/zsh/site-functions/_xsprof"
    fish_completion.install "share/fish/vendor_completions.d/xsprof.fish"
    # Kept as reference; brew does not enable system services.
    (share/"xsprof/systemd").install "lib/systemd/system/xsprof-recorder.service"
  end

  def caveats
    <<~EOS
      The optional recorder service needs CAP_PERFMON and tracefs access.
      The unit template is installed at #{opt_share}/xsprof/systemd/xsprof-recorder.service
      and is never enabled by Homebrew; review the capability set before enabling it.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/xsprof version")
    assert_match "xsprof", shell_output("#{bin}/xsprof help")
  end
end
