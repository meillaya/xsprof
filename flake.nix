{
  description = "xsprof — Linux Scheduler & Memory Profiler (C++ rewrite of zig-scheduler)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        xsprof = pkgs.callPackage ./nix/xsprof.nix { };
      in
      {
        packages = {
          inherit xsprof;
          default = xsprof;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ xsprof ];
          packages = with pkgs; [
            # C++ toolchain
            clang
            llvm
            cmake
            ninja
            bear
            pkg-config
            # C++ deps
            fmt
            nlohmann_json
            catch2_3
            # eBPF / perf toolchain
            libbpf
            elfutils
            zstd
            linuxHeaders
            # NUMA / system
            numactl
            # helpers
            python3
          ];
          shellHook = ''
            export CC=clang
            export CXX=clang++
            echo "xsprof devshell: clang/cmake/ninja/libbpf/bpftool ready"
            echo "build: cmake -S . -B build -G Ninja && bear -- cmake --build build -j && ctest --test-dir build --output-on-failure"
            echo "       (bear generates compile_commands.json for clangd/LSP)"
          '';
        };
      });
}
