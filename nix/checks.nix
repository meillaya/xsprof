# Flake checks. Deterministic, offline, and deliberately no NixOS VM here so
# nix flake check stays cheap and KVM-free. A VM test can be added later as a
# separate package without changing this gate.
{
  pkgs,
  nixpkgs,
  self,
  system,
}:

let
  inherit (pkgs) lib;
  zig = pkgs.callPackage ./zig.nix { };
  xsprof = pkgs.callPackage ./package.nix { src = self; };

  version = builtins.head (builtins.match
    ".*\\.version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*"
    (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ../build.zig.zon)));
  sourceVersion = builtins.head (builtins.match
    ".*pub const version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*"
    (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ../src/core/version.zig)));

  packageCheck = pkgs.runCommand "xsprof-package-check" { } ''
    export HOME="$TMPDIR"
    ${xsprof}/bin/xsprof version | grep -Fx "xsprof ${version}"
    ${xsprof}/bin/xsprof help > /dev/null
    test -s ${xsprof}/share/xsprof/web/index.html
    test -s ${xsprof}/share/xsprof/fixtures/healthy.ndjson
    test -f ${xsprof}/share/applications/xsprof.desktop
    test -f ${xsprof}/share/bash-completion/completions/xsprof
    test -f ${xsprof}/lib/systemd/system/xsprof-recorder.service
    ${xsprof}/bin/xsprof snapshot --replay ${self}/fixtures/ui/healthy.ndjson \
      --out "$TMPDIR/snapshot.png" --width 320 --height 240
    test -s "$TMPDIR/snapshot.png"
    touch $out
  '';

  zigPins = pkgs.runCommand "xsprof-zig-pins" { } ''
    grep -F 'VERSION=${zig.version}' ${../tools/bootstrap.sh}
    grep -F '${zig.passthru.sha256}' ${../tools/bootstrap.sh}
    touch $out
  '';

  versionSync = assert version == sourceVersion;
    pkgs.runCommand "xsprof-version-sync" { } ''
      echo ${lib.escapeShellArg "xsprof ${version}"} > $out
    '';

  moduleCheck =
    let
      enabled = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          (import ./module.nix self)
          { services.xsprof.recorder.enable = true; }
        ];
      }).config;
      defaults = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ (import ./module.nix self) ];
      }).config;
      service = enabled.systemd.services.xsprof-recorder;
      assertions = [
        (service.serviceConfig.User == enabled.services.xsprof.recorder.user)
        (builtins.elem "CAP_PERFMON" service.serviceConfig.AmbientCapabilities)
        (builtins.elem "CAP_DAC_READ_SEARCH" service.serviceConfig.CapabilityBoundingSet)
        (lib.hasInfix "daemon --foreground" service.serviceConfig.ExecStart)
        (service.serviceConfig.StateDirectory == "xsprof")
        (!(defaults.systemd.services ? xsprof-recorder))
      ];
    in
    assert lib.all (assertion: assertion) assertions;
    pkgs.runCommand "xsprof-nixos-module-check" { } ''
      echo ${lib.escapeShellArg (builtins.toJSON {
        inherit version;
        execStart = service.serviceConfig.ExecStart;
        user = service.serviceConfig.User;
      })} > $out
    '';
in
{
  xsprof-package = packageCheck;
  zig-pins = zigPins;
  version-sync = versionSync;
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  nixos-module = moduleCheck;
}
