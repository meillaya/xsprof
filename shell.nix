# Non-flake fallback: nix-shell ./shell.nix
# Mirrors the flake devShell for environments where flakes are disabled.
{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    clang
    llvm
    cmake
    ninja
    bear
    pkg-config
    fmt
    nlohmann_json
    catch2_3
    libbpf
    elfutils
    zstd
    linuxHeaders
    numactl
    python3
  ];
  shellHook = ''
    export CC=clang
    export CXX=clang++
    echo "xsprof devshell (shell.nix): configure with cmake -S . -B build -G Ninja"
  '';
}
