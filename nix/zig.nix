# Official Zig 0.17.0 toolchain, hash-pinned from tools/bootstrap.sh.
#
# nixpkgs' zig is deliberately not used: the pinned nixpkgs revision ships only
# <= 0.16.0, while build.zig.zon requires exactly 0.17.0. The pinned official
# tarball is a fixed-output derivation (the only network step in the flake);
# every xsprof build itself is sandboxed and offline.
{
  lib,
  fetchurl,
  stdenvNoCC,
  xz,
}:

let
  version = "0.17.0";
  pins = {
    x86_64-linux = {
      name = "zig-x86_64-linux-${version}.tar.xz";
      sha256 = "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026";
      hash = "sha256-HL6d+fJ+a3jRTMvKQ7ZwOkBO957xxGPekB1/CI1OICY=";
    };
    aarch64-linux = {
      name = "zig-aarch64-linux-${version}.tar.xz";
      sha256 = "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8";
      hash = "sha256-no0RZh1K471XcCo4MngeI60VHd5XmOFqXM1QP2UjT/g=";
    };
    aarch64-darwin = {
      name = "zig-aarch64-macos-${version}.tar.xz";
      sha256 = "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a";
      hash = "sha256-tgfpuSNHkKAIEWrlvbccYkO4S5+0KlOp5w/eQcBsU2o=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  pin = pins.${system} or (throw "nix/zig.nix: unsupported system ${system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "zig";
  inherit version;

  src = fetchurl {
    url = "https://ziglang.org/download/${version}/${pin.name}";
    inherit (pin) hash;
  };

  nativeBuildInputs = [ xz ];

  # Unpacked tarball root, for example zig-x86_64-linux-0.17.0.
  sourceRoot = lib.removeSuffix ".tar.xz" pin.name;
  dontConfigure = true;
  dontBuild = true;
  # Keep the official signed/stripped bytes: do not patch or strip the
  # compiler binary, which would make the toolchain in the store differ from
  # the hash-pinned upstream artifact.
  dontFixup = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec
    cp -a . $out/libexec/
    mkdir -p $out/bin
    ln -s $out/libexec/zig $out/bin/zig
    runHook postInstall
  '';

  passthru = {
    inherit (pin) sha256 hash;
    inherit version;
  };

  meta = {
    description = "Zig ${version} toolchain pinned by xsprof";
    homepage = "https://ziglang.org/";
    license = lib.licenses.mit;
    mainProgram = "zig";
    platforms = builtins.attrNames pins;
  };
})
