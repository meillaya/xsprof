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
  # Disposable-VM verification lane (docs/guides/microvm.md). It is Linux-only
  # and deliberately not part of `nix flake check`: booting a guest needs qemu
  # and a few minutes, while the check gate stays fast and KVM-free.
  inputs.microvm.url = "github:microvm-nix/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixpkgs-darwin, microvm }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      pkgsFor = system:
        if system == "x86_64-darwin"
        then nixpkgs-darwin.legacyPackages.${system}
        else nixpkgs.legacyPackages.${system};
      forAllSystems = f: lib.genAttrs systems (system: f {
        inherit system;
        pkgs = pkgsFor system;
      });
      zigFor = pkgs: pkgs.callPackage ./nix/zig.nix { };
      xsprofFor = pkgs: pkgs.callPackage ./nix/package.nix { src = self; };

      # Package version parsed once from the Zig manifest, mirroring
      # nix/checks.nix and nix/package.nix (no duplicated literal).
      version = builtins.head (builtins.match
        ".*\\.version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*"
        (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ./build.zig.zon)));

      # Disposable microVM verification lane. Linux-only: the guest is a NixOS
      # system with microvm.nixosModules.microvm, no networking, no display,
      # and one root oneshot that runs nix/microvm/guest-verify.sh on the qemu
      # serial console and reboots. `kvm` needs a usable /dev/kvm; `tcg` sets
      # microvm.cpu = "max" so the runner omits -enable-kvm and qemu's
      # accel="kvm:tcg" makes the guest boot without /dev/kvm (container CI).
      guestSystems = [ "x86_64-linux" "aarch64-linux" ];
      isGuestSystem = system: builtins.elem system guestSystems;
      guestConfiguration = system: variant:
        lib.nixosSystem {
          inherit system;
          modules = [
            microvm.nixosModules.microvm
            (import ./nix/microvm/configuration.nix {
              inherit variant;
              inherit version;
              xsprof = xsprofFor (pkgsFor system);
              scenario = "${self}/scenarios/healthy.json";
            })
          ];
        };
      guestConfigurations = lib.genAttrs guestSystems (system: {
        kvm = guestConfiguration system "kvm";
        tcg = guestConfiguration system "tcg";
      });
      runner = system: variant:
        guestConfigurations.${system}.${variant}.config.microvm.declaredRunner;
      microvmPackagesFor = system: {
        xsprof-microvm = runner system "kvm";
        xsprof-microvm-tcg = runner system "tcg";
      };
    in
    {
      packages = forAllSystems ({ pkgs, system }:
        let
          xsprof = xsprofFor pkgs;
        in
        {
          inherit xsprof;
          # Explicit output so offline environments can prewarm the
          # fixed-output toolchain fetch: nix build .#zig-0.17.0
          "zig-0.17.0" = zigFor pkgs;
          default = xsprof;
        } // lib.optionalAttrs (isGuestSystem system) (microvmPackagesFor system));

      apps = forAllSystems ({ system, ... }:
        lib.optionalAttrs (isGuestSystem system) {
          xsprof-microvm = {
            type = "app";
            program = "${runner system "kvm"}/bin/microvm-run";
          };
          xsprof-microvm-tcg = {
            type = "app";
            program = "${runner system "tcg"}/bin/microvm-run";
          };
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

      # The guest systems. `nix flake check` only evaluates these (it never
      # boots them); the lane itself runs through qa/microvm_verify.sh.
      nixosConfigurations = lib.listToAttrs (lib.concatMap (system: [
        {
          name = "xsprof-verify-${system}";
          value = guestConfigurations.${system}.kvm;
        }
        {
          name = "xsprof-verify-${system}-tcg";
          value = guestConfigurations.${system}.tcg;
        }
      ]) guestSystems);

      overlays.default = final: prev: {
        xsprof = final.callPackage ./nix/package.nix { src = self; };
      };
    };
}
