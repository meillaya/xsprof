{
  description = "xsprof - read-only Linux scheduler and memory profiler";

  # The committed flake.lock pins both revisions and the flake never consults
  # the registry, so offline and local path: overrides work in environments
  # where the flake registry is unavailable. Zig 0.17.0 is fetched by
  # nix/zig.nix with hashes that mirror tools/bootstrap.sh.
  #
  # nixpkgs 26.11 (nixos-unstable at pin time) dropped x86_64-darwin support.
  # The Intel mac output therefore uses the maintained 26.05-darwin branch;
  # everything else uses nixos-unstable. Both are locked and committed.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs, nixpkgs-darwin }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      pkgsFor = system:
        if system == "x86_64-darwin"
        then nixpkgs-darwin.legacyPackages.${system}
        else nixpkgs.legacyPackages.${system};
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = pkgsFor system;
      });
      zigFor = pkgs: pkgs.callPackage ./nix/zig.nix { };
      xsprofFor = pkgs: pkgs.callPackage ./nix/package.nix { src = self; };
    in
    {
      packages = forAllSystems ({ pkgs, ... }:
        let
          xsprof = xsprofFor pkgs;
        in
        {
          inherit xsprof;
          # Explicit output so offline environments can prewarm the
          # fixed-output toolchain fetch: nix build .#zig-0.17.0
          "zig-0.17.0" = zigFor pkgs;
          default = xsprof;
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
              pkgs.nodejs
              pkgs.python3
              pkgs.nixfmt
              pkgs.shellcheck
            ];
            # tools/zig honors this instead of downloading into .tools.
            env.XSPROF_ZIG = "${zig}/bin/zig";
            shellHook = ''
              echo "xsprof dev shell: Zig ${zig.version} (pinned by nix/zig.nix)"
            '';
          };
        });

      checks = forAllSystems ({ system, pkgs }:
        import ./nix/checks.nix { inherit self nixpkgs system pkgs; });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt);

      nixosModules = {
        default = import ./nix/module.nix self;
        recorder = import ./nix/module.nix self;
      };

      overlays.default = final: prev: {
        xsprof = final.callPackage ./nix/package.nix { src = self; };
      };
    };
}
