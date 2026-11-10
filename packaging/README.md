# Packaging and release

This directory holds the packaging inputs and templates. The release tooling
never publishes on its own: credentials and publication are separate,
fail-closed steps. Nothing here fakes a signature, notarization, or tap push.

## Source of truth

- `build.zig.zon` `version` is parsed by every packaging script; no version is
  duplicated.
- `tools/bootstrap.sh` is the human source of truth for the pinned Zig 0.17.0
  hashes. `nix/zig.nix` mirrors them and `nix flake check` fails if they drift.
  `tools/zig` honors `XSPROF_ZIG` for hermetic Nix/CI builds and otherwise
  bootstraps into `.tools/`.
- `packaging/homebrew/` holds formula/cask templates rendered by
  `tools/update_homebrew_tap.sh`.
- `tools/fetch_appimagetool.sh` pins appimagetool 1.9.1 with SHA256 values for
  x86_64/aarch64 and caches it in `.tools/downloads` (offline after the first
  verified download). `tools/package_appimage.sh` uses it for the Linux
  AppImage.

## Nix flake

```sh
nix flake lock                    # once on a networked machine; commit flake.lock
nix build .#xsprof                # package for the current system
nix develop                       # pinned Zig + git/curl/xz/node/python/nixfmt/shellcheck
nix flake check                   # package smoke, zig pins, version sync, NixOS-module eval
nix flake check --all-systems --no-build   # evaluate all four systems without building
nix build .#xsprof --offline --option substitute false   # after the store is warm
```

Inputs: `nixpkgs` (`nixos-unstable`) for Linux and aarch64-darwin, plus
`nixpkgs-darwin` (`nixpkgs-26.05-darwin`) for x86_64-darwin, because nixpkgs
26.11 dropped Intel-mac support, plus `microvm` (`github:microvm-nix/microvm.nix`,
nixpkgs followed) for the Linux disposable-VM verification lane. All revisions
are pinned by the committed `flake.lock`; the flake never uses the flake
registry, so these work offline and with a local nixpkgs:

```sh
nix build .#xsprof --no-update-lock-file --override-input nixpkgs path:/path/to/nixpkgs
```

Outputs per system (`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`): `packages.<system>.{xsprof,zig-0.17.0,default}`,
`devShells.<system>.default`, `checks.<system>.*`, `nixosModules.{default,recorder}`,
`overlays.default`, `formatter.<system>`.

Linux-only disposable-VM verification lane (microvm.nix; see
[docs/guides/microvm.md](../docs/guides/microvm.md)):
`nixosConfigurations.{xsprof-verify-<system>,xsprof-verify-<system>-tcg}`,
`packages.<system>.{xsprof-microvm,xsprof-microvm-tcg}`, and
`apps.<system>.{xsprof-microvm,xsprof-microvm-tcg}` (so
`nix run .#xsprof-microvm-tcg` boots the TCG guest on hosts without `/dev/kvm`).
The lane is not part of `nix flake check`; run it with
`sh qa/microvm_verify.sh [--variant auto|kvm|tcg]`.

### Pinned Zig (no nixpkgs Zig, no network in the build)

`nix/zig.nix` fetches the official 0.17.0 tarball with the sha256 values from
`tools/bootstrap.sh` as a fixed-output derivation. That fetch is the only network
step and is substitutable/cacheable; the xsprof build itself is sandboxed and
offline. Prewarm it with
`nix build '.#packages.<system>."zig-0.17.0"'` (quoted attribute). nixpkgs' own `zig` is
deliberately unused (the pinned nixpkgs revision ships only <= 0.16.0).

### Runtime libraries on NixOS

The Linux derivation uses `autoPatchelfHook` for the dynamic-glibc interpreter
and a wrapper that prepends `libx11`, `libglvnd`, and `mesa` to
`LD_LIBRARY_PATH` and sets `XSPROF_FIXTURES_DIR` for the installed replay
fixture. Native-only: no browser/WASM assets are installed. The binary still dlopens only `libX11.so.6` and
`libGL.so.1`; no link-time GUI dependency is added. NixOS users who want
hardware OpenGL also need `hardware.graphics.enable = true` (mesa provides the
llvmpipe fallback).

### NixOS module (opt-in recorder)

```nix
{
  inputs.xsprof.url = "github:meillaya/xsprof";
  # inputs.xsprof.inputs.nixpkgs.follows = "nixpkgs";
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

The service is disabled by default. Enabling it creates an unprivileged
`xsprof` user, runs `xsprof daemon --foreground --dir /var/lib/xsprof` with
`--retain`/`--max-bytes`/`--history-*`, grants only `CAP_PERFMON` and
`CAP_DAC_READ_SEARCH`, applies the same hardening as
`packaging/systemd/xsprof-recorder.service`, and rejects unsafe/mutating verbs in
`extraArgs` (the read-only invariant). Options: `user`, `group`, `stateDir`,
`retain`, `maxBytes`, `historyInterval`, `historyRetain`, `package`,
`extraArgs`.

### Platform notes

- Darwin builds take `-Dmacos-sdk=${apple-sdk.sdkroot}` because Zig's SDK
  autodetection is skipped under Nix; `autoSignDarwinBinariesHook` ad-hoc signs
  the arm64 binary so it can execute. The flake produces `bin/xsprof` for
  macOS; the notarized `.app`/cask remain release artifacts.
- Nix cannot cross-build Darwin from Linux. Darwin outputs evaluate on Linux
  (`nix flake check --all-systems --no-build`) but need a macOS or remote
  builder to build.
- `nix flake check` deliberately does not run a NixOS VM (KVM-free, fast).

## Linux tarball

`sh tools/package.sh` (cross: `XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux
XSPROF_ARCH=aarch64`) builds once with `--prefix`, packages the native binary
and data files, then writes `dist/xsprof-<version>-<os>-<arch>.tar.gz` and its
`.sha256`. Layout (native-only; no web assets):

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

Completions are generated from a host-native build of the same revision
(`tools/gen_completions.sh`), so cross tarballs ship correct completions.
GNU tar builds use `--sort=name --mtime=@SOURCE_DATE_EPOCH --owner=0 --group=0
--numeric-owner` for reproducible archives.

## Debian package

`sh tools/package_deb.sh` requires `dpkg-deb` (Debian/Ubuntu). Cross packaging:
`XSPROF_DEB_ARCH=arm64` (defaults to `dpkg --print-architecture`) with an
optional `XSPROF_TARGET`. The package installs the same layout under `/usr`,
plus `/usr/lib/sysusers.d/xsprof.conf`, `/usr/share/applications/xsprof.desktop`,
`/usr/share/icons/hicolor/scalable/apps/xsprof.svg`, md5sums, copyright, and a
Debian changelog. Control fields include `Version: <version>-1`,
`Maintainer: xsprof maintainers <maintainers@xsprof.dev>`, `Homepage`,
`Depends: libc6`, and `Recommends: libx11-6, libgl1` (only `ui` needs X11/GL).
The release workflow builds amd64 and arm64 debs and verifies them with
`qa/package_layout.sh`. No web/WASM assets are included in the deb.

## AppImage (Linux)

`sh tools/package_appimage.sh` builds a single-architecture AppImage on a
matching Linux host. It downloads/verifies the pinned appimagetool 1.9.1
(`tools/fetch_appimagetool.sh`, cached in `.tools/downloads`), stages an AppDir
with the native binary, the replay fixture, the desktop entry, the icon, and
`AppRun`, and writes `dist/Xsprof-<version>-<arch>.AppImage` plus its
`.sha256`. The AppDir contains no web/WASM assets and no bundled
X11/GL/mesa/driver/shared libraries: the binary keeps dlopening the host's
`libX11.so.6`/`libGL.so.1`. glibc is likewise provided by the host (the CI
artifact is built on Ubuntu 24.04, so it targets that glibc baseline). The
release workflow builds and smoke-tests the x86_64 AppImage on the x86_64
runner; aarch64 can be built natively on an aarch64 host.

```sh
sh tools/package_appimage.sh
sh qa/appimage_smoke.sh --appimage dist/Xsprof-<version>-x86_64.AppImage
```

`qa/appimage_smoke.sh` is FUSE-free: it extracts the AppImage, checks the
AppDir contents, runs `version`/`help` and a headless CPU `snapshot` through
`AppRun`, and runs the AppImage runtime with `APPIMAGE_EXTRACT_AND_RUN=1`. It
fails closed if web assets or X11/GL/driver libraries are bundled.

## macOS app: notarized vs unsigned

```sh
# Strict release (macOS + Apple credentials; produces cask-eligible artifacts)
XSPROF_UNIVERSAL=1 XSPROF_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)" \
XSPROF_NOTARIZE=1 [NOTARY_PROFILE=... | APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD] \
sh tools/package_macos_app.sh
# -> dist/Xsprof-<v>-macos.zip + ...-macos-notarization.json (notarized=true)

# No-credential local path (honest label, never cask-eligible)
sh tools/package_macos_app.sh
# -> dist/Xsprof-<v>-macos-unsigned.zip + ...-unsigned-notarization.json
```

The notarized path signs the binary and bundle with hardened runtime, waits for
`notarytool`, staples, checks Gatekeeper with `spctl`, and then
`tools/verify_macos_artifact.sh` re-extracts the zip and verifies codesign,
TeamIdentifier, hardened-runtime flag, `stapler validate`, universal archs,
Info.plist version, and the zip hash before writing the attestation. The result
JSON from `tools/notarize_macos.sh` is required input; without it the verifier
fails closed. Unsigned builds are ad-hoc signed, named `-unsigned.zip`, and carry
`notarized:false`; they can never satisfy the cask gate.

Attestation `xsprof/macos-notarization/v1` (canonical compact JSON, sorted keys):

```json
{"artifact":{"name":"Xsprof-<v>-macos.zip","sha256":"<64hex>","size_bytes":N},"created_at":"<RFC3339Z>","notarized":true,"notarization":{"gatekeeper":"accepted","stapled":true,"status":"Accepted","submission_id":"<uuid>"},"schema":"xsprof/macos-notarization/v1","signing":{"hardened_runtime":true,"identity":"Developer ID Application: ... (TEAMID)","team_id":"TEAMID"},"version":"<v>"}
```

`tools/verify_macos_attestation.py` is the portable gate (Linux/macOS, stdlib
only): exit 0 valid, 10 malformed/unknown schema, 11 version/name/sha/size
mismatch, 12 not notarized unless `--allow-unnotarized`. CI and the tap updater
both call it.

## Homebrew tap

`tools/update_homebrew_tap.sh` renders `Formula/xsprof.rb` (always) and
`Casks/xsprof-app.rb` only after the attestation verifies as notarized and its
sha256/size match the macOS zip. `--require-notarized` fails before writing,
committing, or pushing if the cask cannot be rendered. Modes:
`--tap-dir DIR` (git checkout; commits and pushes), `--dry-run` (render, no
commit), `--no-push` (commit locally), `--render-dir DIR` (no git at all).
`--attestation FILE --macos-size BYTES` gate the cask. The formula is Linux-only
(`depends_on :linux`, MIT license) and installs the fixtures/completions/
desktop/icon files and a reference systemd unit under `share/xsprof/systemd`.
No web assets are installed.

## Release workflow

`.github/workflows/release.yml`:

- `preflight` resolves the version (must equal `build.zig.zon`), chooses
  `channel=release|unsigned`, and for strict releases fails before any build
  if any required secret is missing: `MACOS_CERTIFICATE_P12`,
  `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`,
  `NOTARY_PROFILE` or `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`, and
  `HOMEBREW_TAP_TOKEN`.
- `linux` builds the x86_64/aarch64 tarballs and debs, the x86_64 AppImage
  (with a FUSE-free smoke test), and verifies all layouts.
- `macos` imports the certificate into a temporary keychain only on strict
  releases, notarizes/verifies/attests, deletes the keychain always, and on a
  dry run asserts that the tap gate rejects the labelled unsigned artifact.
- `release` verifies per-file checksums, builds `SHA256SUMS`, verifies the
  attestation, publishes the GitHub release, and (strict only) updates the tap
  with `--require-notarized`. Unsigned dispatches are prereleases labelled
  "AD-HOC SIGNED, NOT NOTARIZED", never touch the tap, and are not cask-eligible.

`.github/workflows/nix.yml` runs the flake check/build/devShell on Linux (macOS
on dispatch). `zig-ci.yml` runs the offline `qa/release_tooling.sh` gate.

## Local, no-credential verification

```sh
sh qa/release_tooling.sh     # sh -n, attestation fixtures, tap render + local bare-remote push
sh qa/homebrew_dry_run.sh    # renderer/gate tests only
sh tools/update_homebrew_tap.sh --render-dir /tmp/tap \
  --version <v> --linux-arm64 <sha> --linux-x86_64 <sha> --macos <sha> \
  --macos-size <bytes> --attestation packaging/testdata/macos-attestation-valid.json
```

`sh qa/appimage_smoke.sh --appimage FILE` extracts and executes a built
AppImage without FUSE (version/help/CPU snapshot) and fails closed on web
assets or bundled drivers. `qa/package_layout.sh --tarball FILE [--deb FILE]
[--appimage FILE]` checks the real release layouts, native-only contents, and
checksums. Real notarization/stapling/Gatekeeper and any tap push
require external Apple and GitHub credentials; they are never exercised by these
local gates and must not be claimed.

## Deferred

AUR is out of scope for now: it needs a separate repo/credentials and can
follow later without changing these artifacts. AppImage is shipped (native
x86_64 release artifact, buildable on a matching Linux host); the Nix flake
covers NixOS/Nix, tarballs+deb cover generic Linux, and the Homebrew
formula/cask cover Linuxbrew/macOS.
