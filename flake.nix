{
  description = "xsprof - trust-first Linux scheduler flight recorder with an optional viewer";

  # One pinned nixpkgs, no registry lookups, one toolchain (Zig 0.17.0 fetched
  # by hash from ziglang.org in nix/zig.nix). macOS is supported as an optional
  # viewer only; Linux is the capture platform.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });

      zigFor = pkgs: pkgs.callPackage ./nix/zig.nix { };

      # The package closure only needs build inputs, fixtures and packaging
      # install files. Documentation, design assets, evidence and QA material
      # never enter the store path a user installs.
      packageSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./build.zig
          ./build.zig.zon
          ./src
          ./lib
          ./tools
          ./fixtures/ui/healthy.ndjson
          ./packaging/systemd
          ./packaging/sysusers
          ./packaging/linux
        ];
      };

      xsprofFor = pkgs: pkgs.callPackage ./nix/package.nix { src = packageSrc; };

      # Package version parsed once from the Zig manifest (mirrored by
      # nix/checks.nix and nix/package.nix; no duplicated literal).
      version = builtins.head (builtins.match
        ".*\\.version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*"
        (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ./build.zig.zon)));
    in
    {
      packages = forAllSystems ({ pkgs, ... }:
        {
          xsprof = xsprofFor pkgs;
          # Explicit output so offline environments can prewarm the
          # fixed-output toolchain fetch: nix build .#zig-0.17.0
          "zig-0.17.0" = zigFor pkgs;
          default = xsprofFor pkgs;
        });

      devShells = forAllSystems ({ pkgs, ... }:
        let
          zig = zigFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              zig
              pkgs.git
              pkgs.curl
              pkgs.xz
              pkgs.python3
              pkgs.ffmpeg
              pkgs.nixfmt
              pkgs.shellcheck
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.xorg.xvfb
            ];
            # tools/zig honors this instead of downloading into .tools.
            env.XSPROF_ZIG = "${zig}/bin/zig";
            shellHook = ''
              echo "xsprof dev shell: Zig ${zig.version} (pinned by nix/zig.nix)"
              echo "gates: ./tools/zig build check | ./tools/zig build check-ci"
            '';
          };
        });

      checks = forAllSystems ({ system, pkgs }:
        import ./nix/checks.nix {
          inherit self nixpkgs system pkgs packageSrc;
        });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt);

      nixosModules = {
        default = import ./nix/module.nix self;
        recorder = import ./nix/module.nix self;
      };

      overlays.default = final: prev: {
        xsprof = final.callPackage ./nix/package.nix { src = packageSrc; };
      };
    };
}
