# NIX_DEV_ENV — Reproducible Nix Development Environment

Research deliverable for mission `cpp-sched-mem-profiler`. The rewrite builds inside a reproducible
Nix devshell/flake so clang/llvm (for BPF CO-RE), libbpf, cmake, ninja, and the C++ dependencies are
pinned identically for every contributor and CI run.

## 1. Host toolchain evidence (probed)

| Tool | Present | Version / note |
| --- | --- | --- |
| nix | yes | Determinate Nix 3.21.7 (nix 2.34.8), flakes-capable |
| clang/llvm | yes | clang 22.1.8 with `bpf`/`bpfeb`/`bpfel` targets |
| gcc | yes | g++ 16.1.1 |
| cmake | install via nix | (system cmake not on PATH; pin in flake) |
| ninja | install via nix | pin in flake |
| libbpf | yes | 1.7.0 (pkg-config) |
| libelf | yes | 0.195 |
| libzstd | yes | 1.5.7 |
| fmt | yes | 12.2.0 |
| nlohmann_json | install via nix | header-only |
| catch2 / gtest | yes | gtest headers present; standardize on Catch2 v3 from nixpkgs |
| bpftool | yes | `/usr/bin/bpftool` (also pin from nixpkgs for reproducibility) |
| kernel BTF | yes | `/sys/kernel/btf/vmlinux` |

## 2. Flake layout

```
flake.nix            # inputs: nixpkgs, flake-utils; outputs: devShell, packages.xsprof
flake.lock           # pinned input revisions (committed)
nix/
  xsprof.nix         # derivation: cmake + ninja build of libxsprof + xsprof + tests
  bpf.nix            # helper to compile bpf/*.bpf.c with clang -target bpf (CO-RE)
shell.nix            # non-flake fallback: nix-shell ./shell.nix
```

`flake.nix` (sketch):

```nix
{
  inputs = { nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; flake-utils.url = "github:numtide/flake-utils"; };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          hardeningDisable = [ "fortify" ];
          inputsFrom = [ self.packages.${system}.xsprof ];
          packages = with pkgs; [
            clangTools clang llvm libbpf elfutils zstd bpftool
            cmake ninja pkg-config
            fmt nlohmann_json catch2_3
            linuxHeaders numactl
          ];
          shellHook = ''
            export CC=clang CXX=clang++
            export XS_BPF_VMLINUX_H=${pkgs.linuxHeaders}/include
          '';
        };
        packages.xsprof = pkgs.callPackage ./nix/xsprof.nix { };
      });
}
```

## 3. Entering the environment

```bash
nix develop            # flakes (preferred)
nix-shell ./shell.nix  # fallback if flakes are disabled
```

Inside the shell the project configures and builds with:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
ctest --test-dir build --output-on-failure
```

## 4. BPF build inside Nix

`vmlinux.h` is generated from the running kernel BTF for CO-RE:

```bash
bpftool btf dump file /sys/kernel/btf/vmlinux format c > bpf/vmlinux.h
clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -c bpf/xs_sched.bpf.c -o build/xs_sched.bpf.o
```

The CMake `bpf` target wraps this and is skipped (with a printed `SKIP`) when `bpftool`/BTF is
unavailable, so the host build never fails on missing BPF inputs.

## 5. Reproducibility rules

- `flake.lock` is committed; CI builds with `nix develop --command cmake --build ...` so the exact
  pinned toolchain is used.
- No dependency is fetched at build time outside Nix (no `FetchContent` network downloads in the
  default build); all third-party C++ libs come from nixpkgs.
- The build is hermetic: `CC=clang CXX=clang++` are set by the shell hook.

## 6. Evidence vs. inference

Grounded: every "present" row above was probed on the host (versions recorded). Assumption (labeled):
`cmake`, `ninja`, `nlohmann_json`, and `catch2_3` are added via the flake because they are not all on
the bare host PATH; nixpkgs `nixos-unstable` provides current versions. The exact nixpkgs revision is
fixed by `flake.lock` at first `nix develop`/`nix build` and committed thereafter.
