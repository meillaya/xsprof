# Packaging and release

This directory holds the packaging *inputs* (unit, sysusers, desktop entry,
icon). The release workflow and `tools/package*.sh` scripts produce Linux-only
artifacts; there are no macOS, Homebrew, cask, or notarization artifacts.

## Source of truth

- `build.zig.zon` `.version` is parsed by every packaging script and the release
  workflow; no version is duplicated.
- `tools/bootstrap.sh` is the human source of truth for the pinned Zig 0.17.0
  version and per-host sha256 values. `nix/zig.nix` mirrors them; `nix flake
  check` fails if they drift. `tools/zig` honors `XSPROF_ZIG` for hermetic
  Nix/CI builds and otherwise bootstraps into `.tools/`.
- `tools/fetch_appimagetool.sh` pins appimagetool 1.9.1 with sha256 values for
  x86_64/aarch64, caching it in `.tools/downloads` (offline after the first
  verified download). `tools/package_appimage.sh` uses it.
- Completions are generated from a host-native build of the same revision by
  `tools/gen_completions.sh` during packaging, so cross-built tarballs ship
  correct bash/zsh/fish completions.

## Nix flake

```sh
nix build .#xsprof                     # current system
nix develop                            # pinned Zig + dev tools
nix flake check                        # package smoke, Zig pins, version sync, NixOS-module eval
nix flake check --all-systems --no-build
nix build .#xsprof --offline --option substitute false   # after the store is warm
```

Systems: `x86_64-linux`, `aarch64-linux` (capture + viewer), `aarch64-darwin`
(viewer only). There is one pinned `nixpkgs` input (`nixos-unstable`) and no
flake-registry lookup, so builds work offline and against a local nixpkgs:

```sh
nix build .#xsprof --no-update-lock-file --override-input nixpkgs path:/path/to/nixpkgs
```

Outputs per system: `packages.<system>.{xsprof,zig-0.17.0,default}`,
`devShells.<system>.default`, `checks.<system>.*`,
`nixosModules.{default,recorder}`. `nix flake check` is deterministic and
KVM-free; it runs the package smoke, Zig pins, version sync, and the NixOS
module evaluation.

### Pinned Zig (no nixpkgs Zig, no network in the build)

`nix/zig.nix` fetches the official 0.17.0 tarball with the sha256 values from
`tools/bootstrap.sh` as a fixed-output derivation. That fetch is the only
network step and is substitutable/cacheable; the xsprof build itself is sandboxed
and offline. Prewarm it with:

```sh
nix build '.#packages.<system>."zig-0.17.0"'   # quoted attribute
```

nixpkgs' own `zig` is deliberately unused (the pinned nixpkgs revision ships an
older version).

### Runtime libraries and the wrapper (Linux)

The Linux derivation uses `autoPatchelfHook` for the dynamic-glibc interpreter
and a wrapper that prepends `libx11`, `libglvnd`, and `mesa` to
`LD_LIBRARY_PATH` and sets `XSPROF_FIXTURES_DIR` for the installed replay
fixture. The binary still `dlopen`s only the system X11/GL libraries; no
link-time GUI dependency is added. NixOS users who want hardware OpenGL also
need `hardware.graphics.enable = true` (mesa provides the llvmpipe fallback).
The raw recorder/CLI never needs X11/GL.

### NixOS module (opt-in recorder)

```nix
{
  inputs.xsprof.url = "github:meillaya/xsprof";
  outputs = { self, nixpkgs, xsprof, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        xsprof.nixosModules.default
        { services.xsprof.recorder.enable = true; }
      ];
    };
  };
}
```

The service is disabled by default. Enabling it creates an unprivileged `xsprof`
user, runs `xsprof daemon --foreground --dir /var/lib/xsprof` with
`--retain`/`--max-bytes`/`--history-*`, grants only `CAP_PERFMON` and
`CAP_DAC_READ_SEARCH`, applies the same hardening as
`packaging/systemd/xsprof-recorder.service`, and rejects unsafe/mutating verbs
in `extraArgs` (the read-only invariant). Options: `user`, `group`, `stateDir`,
`retain`, `maxBytes`, `historyInterval`, `historyRetain`, `package`,
`extraArgs`.

### macOS (viewer only)

Darwin builds take `-Dmacos-sdk=${apple-sdk.sdkroot}` because Zig's SDK
autodetection is skipped under Nix, and `autoSignDarwinBinariesHook` ad-hoc signs
the arm64 binary so it can execute. This is a **viewer-only** build: it cannot
capture, it is not notarized, and it is not published as an artifact. See
[docs/platforms/macos-viewer.md](../docs/platforms/macos-viewer.md). Nix cannot
cross-build Darwin from Linux; the Darwin output needs a macOS builder.

## Linux tarball

```sh
sh tools/package.sh      # host target
XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux XSPROF_ARCH=aarch64 sh tools/package.sh
```

Produces `dist/xsprof-<version>-linux-<arch>.tar.gz` and `.sha256`. Layout:

```text
bin/xsprof
share/xsprof/fixtures/healthy.ndjson
share/applications/xsprof.desktop
share/icons/hicolor/scalable/apps/xsprof.svg
share/bash-completion/completions/xsprof
share/zsh/site-functions/_xsprof
share/fish/vendor_completions.d/xsprof.fish
lib/systemd/system/xsprof-recorder.service
lib/sysusers.d/xsprof.conf
share/doc/xsprof/
```

GNU tar builds use `--sort=name --mtime=@SOURCE_DATE_EPOCH --owner=0 --group=0
--numeric-owner` for reproducible archives. No browser/WASM assets are included.

## Debian package

```sh
sh tools/package_deb.sh   # requires dpkg-deb; XSPROF_DEB_ARCH=arm64 to cross-package
```

Installs the same layout under `/usr`, plus
`/usr/lib/sysusers.d/xsprof.conf`, the desktop entry/icon, md5sums, copyright,
and a Debian changelog. Control fields include `Version: <version>-1`,
`Maintainer: xsprof maintainers <maintainers@xsprof.dev>`, `Homepage`,
`Depends: libc6`, and `Recommends: libx11-6, libgl1` (only the viewer needs
X11/GL). The unit is installed but not enabled.

## AppImage (Linux)

```sh
sh tools/package_appimage.sh
sh qa/appimage_smoke.sh --appimage dist/Xsprof-<version>-x86_64.AppImage --version <version>
```

The script downloads/verifies the pinned appimagetool, stages an AppDir with the
native binary, replay fixture, desktop entry, icon, and `AppRun`, and writes
`dist/Xsprof-<version>-<arch>.AppImage` plus `.sha256`. The AppDir contains no
X11/GL/mesa/driver/shared libraries: the binary keeps `dlopen`ing the host's
`libX11.so.6`/`libGL.so.1`. glibc is likewise the host's (the CI artifact targets
the Ubuntu 24.04 baseline). The AppImage is unsigned; there is no code-signing
claim for Linux artifacts beyond checksums and build provenance.

### Baseline-CPU portability

Every packaged binary is a **baseline-CPU build**:

- `tools/package.sh`, `tools/package_deb.sh`, and `tools/package_appimage.sh`
  pass `-Dcpu=baseline` to every Zig build, native or cross. A default native
  build uses the build host's (or CI runner's) CPU features: the v0.6.0 AppImage
  was built that way and trapped with `SIGILL` (exit 132; `gdb` showed
  `vmovups %zmm0` in `start.main`) on an AMD Zen3 host, because it required
  AVX-512.
- `qa/cpu_portability.sh --binary FILE` disassembles a packaged binary and fails
  on VEX/EVEX-encoded x86_64 instructions (mnemonics beginning with `v`, except
  legacy `verr`/`verw`) and on SVE/SVE2 instructions or vector/predicate
  registers on aarch64; other architectures SKIP with a reason.
- `qa/appimage_smoke.sh` and `qa/package_layout.sh` call the gate on the AppImage
  binary, the tarball binary, and (when `dpkg-deb` is available) the deb binary.
  The release lane runs those gates with `XSPROF_REQUIRE_TOOLS=1`, so a missing
  `readelf`/`objdump` is a hard failure, never a silent skip.

The v0.6.0 AppImage smoke only *executed* the artifact on the build host, whose
CPU supports the same features the compiler targeted, so a host-native binary
passed; it never inspected the machine code for instructions older hosts cannot
run. The portability gate is independent of where it runs: a capable x86_64
runner still rejects AVX/AVX-512 code in a shipped binary.

## Release workflow

`.github/workflows/release.yml` is a **Linux-only, tag-first** lane:

- Publishing happens only for a pushed `vX.Y.Z` tag. Preflight refuses the run
  unless the tag equals `build.zig.zon`, the runtime version, the CHANGELOG top
  heading, and the README version (via `qa/version_sync.sh`), and unless the
  full `check-ci` gate passes.
- `workflow_dispatch` is a dry run by construction: it builds and smoke-tests
  packages but can never run the publish job.
- The `linux` job builds x86_64/aarch64 tarballs and debs, packages and
  FUSE-free-smokes the AppImages, and verifies all layouts with
  `qa/package_layout.sh`. Packaging/smoke steps run with
  `XSPROF_REQUIRE_TOOLS=1`, so each artifact's CPU-portability check is
  fail-closed: a missing `readelf`/`objdump` fails the lane instead of skipping
  the check.
- `publish` verifies per-artifact checksums, builds `SHA256SUMS`, attests build
  provenance with Sigstore, and creates the GitHub release. There is no macOS
  job, no notarization secret handling, no Homebrew tap, and no token-bearing
  clone URL.

`.github/workflows/nix.yml` runs `nix flake check` and a package smoke on Linux
(macOS on explicit dispatch). `.github/workflows/zig-ci.yml` runs `check-ci` on
Linux x86_64/aarch64 and `check` on macOS.

## Local verification (no network, no credentials)

```sh
sh qa/appimage_smoke.sh --appimage dist/<artifact>.AppImage --version <version>
sh qa/package_layout.sh --tarball <tar.gz> --deb <deb> --appimage <AppImage>
```

Both extract/execute the artifacts without FUSE and without a window, check the
native-only layout, and fail closed on browser/WASM assets or bundled drivers.
Real publication (GitHub release, provenance attestation) happens only in the
tag-driven workflow with repository credentials; never claim an unpublished
artifact.

## Evidence policy

Benchmark logs, KVM VM acceptance output, and full captures are **not committed**.
They are attached to the corresponding GitHub release (see
[docs/maintaining.md](../docs/maintaining.md)). The repository stays within the
tracked-tree size budget enforced by `qa/repo_size.sh`.

## Out of scope

macOS signed/notarized distribution, Homebrew/cask/tap, AUR, and any
network-serving/browser packaging are out of scope. They were removed rather
than left fail-closed, because a trust-first recorder should not ship tooling it
cannot honestly exercise.
