# xsprof derivation. Zig comes from nix/zig.nix (pinned 0.17.0), never from
# nixpkgs. Linux gets an auto-patched glibc interpreter plus a wrapper that
# makes the runtime-dlopened X11/GL libraries and installed data files findable;
# Darwin is built against the nixpkgs Apple SDK and ad-hoc signed by the
# nixpkgs hook so arm64 binaries can execute. No C shims, no new link-time
# dependencies.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  xz,
  autoPatchelfHook,
  makeWrapper,
  makeSetupHook,
  writeText,
  # Guarded defaults keep callPackage evaluation working on nixpkgs revisions
  # where the Darwin package set is not exposed on Linux. They are only
  # referenced under lib.optionals isDarwin.
  apple-sdk ? null,
  darwin ? null,
  libx11,
  libglvnd,
  mesa,
  src,
}:

let
  inherit (stdenv.hostPlatform) isDarwin isLinux;

  zig = import ./zig.nix { inherit lib fetchurl xz stdenvNoCC; };

  version = let
    zon = builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ../build.zig.zon);
    matched = builtins.match ".*\\.version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*" zon;
  in builtins.head matched;

  # postFixupHooks run in nativeBuildInputs order: autoPatchelfHook and the
  # Darwin signing hook come first, then this hook. That ordering lets us run
  # the freshly patched/signed binary to generate completions and wrap it.
  finalizeHookScript = writeText "xsprof-finalize-hook.sh" (''
    postFixupHooks+=(xsprofFinalizeOutput)

    xsprofFinalizeOutput() {
        if [ -e "$out/bin/xsprof" ]; then
            sh "$src/tools/gen_completions.sh" "$out/bin/xsprof" "$out/share"
        fi
    ${lib.optionalString isLinux ''
        if [ -e "$out/bin/xsprof" ] && [ ! -e "$out/bin/.xsprof-wrapped" ]; then
            wrapProgram "$out/bin/xsprof" \
                --set-default XSPROF_FIXTURES_DIR "$out/share/xsprof/fixtures" \
                --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libx11 libglvnd mesa ]}"
        fi
    ''}
    }
  '');
in
stdenv.mkDerivation {
  pname = "xsprof";
  inherit version src;

  nativeBuildInputs = [ zig ]
    ++ lib.optionals isLinux [ autoPatchelfHook makeWrapper ]
    ++ lib.optionals isDarwin [ darwin.autoSignDarwinBinariesHook ]
    # A setup hook (not a postFixup string) so its append to postFixupHooks is
    # sourced after autoPatchelfHook / the Darwin signing hook. Verified with
    # nix derivation show: the hook is part of nativeBuildInputs.
    ++ [ (makeSetupHook { name = "xsprof-finalize-hook"; } finalizeHookScript) ];

  buildInputs = lib.optionals isDarwin [ apple-sdk ];

  dontConfigure = true;
  doCheck = false;
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    XSPROF_ZIG=${zig}/bin/zig ./tools/zig build -Doptimize=ReleaseSafe \
      ${lib.optionalString isDarwin "-Dmacos-sdk=${apple-sdk.sdkroot}"} \
      --prefix $out
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # v0.5 ships the native console only; drop any legacy browser/WASM tree
    # and package the documented share/xsprof layout.
    rm -rf "$out/web"
    mkdir -p $out/share/xsprof/fixtures
    install -Dm644 ${src}/fixtures/ui/healthy.ndjson $out/share/xsprof/fixtures/healthy.ndjson
    install -Dm644 ${src}/packaging/systemd/xsprof-recorder.service $out/lib/systemd/system/xsprof-recorder.service
    install -Dm644 ${src}/packaging/sysusers/xsprof.conf $out/lib/sysusers.d/xsprof.conf
    install -Dm644 ${src}/packaging/linux/xsprof.desktop $out/share/applications/xsprof.desktop
    install -Dm644 ${src}/packaging/linux/xsprof.svg $out/share/icons/hicolor/scalable/apps/xsprof.svg
    runHook postInstall
  '';

  meta = {
    description = "Read-only Linux scheduler and memory profiler";
    homepage = "https://github.com/meillaya/xsprof";
    license = lib.licenses.mit;
    mainProgram = "xsprof";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
