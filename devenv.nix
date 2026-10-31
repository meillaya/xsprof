{ pkgs, ... }:
{
  # Zig stays pinned at 0.17.0 through ./tools/zig; do not put nixpkgs' Zig on
  # PATH. These are the host tools the bootstrap and gates need.
  packages = with pkgs; [
    curl
    git
    xz
  ];

  enterShell = ''
    printf 'xsprof dev shell\n'
    printf 'Zig: %s\n' "$(./tools/zig version 2>/dev/null || echo 'run ./tools/zig build')"
  '';

  enterTest = ''
    ./tools/zig build check
  '';

  scripts.check.exec = "./tools/zig build check";
  scripts.fuzz.exec = "./tools/zig build fuzz";
}
