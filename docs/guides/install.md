# Install

The native GPU console is the only product surface in v0.5.0; there is no
browser/WASM build and packaged artifacts do not include web assets.

## Nix / NixOS (flake)

```sh
nix run github:meillaya/xsprof/v<version> -- help
nix profile install github:meillaya/xsprof/v<version>
# or from a checkout:
nix build .#xsprof && ./result/bin/xsprof ui
nix develop            # pinned Zig 0.17.0 and the packaging tools
```

The flake supports `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and
`aarch64-darwin`. Linux and aarch64-darwin use the pinned nixos-unstable
`nixpkgs`; Intel macOS uses the maintained `nixpkgs-26.05-darwin` input because
nixpkgs 26.11 dropped x86_64-darwin. Both revisions are committed in
`flake.lock`. Zig 0.17.0 is fetched from ziglang.org by hash (never nixpkgs'
Zig) and the xsprof build itself needs no network. Offline/local-nixpkgs
verification:

```sh
nix build .#xsprof --offline --option substitute false       # after the store is warm
nix build .#xsprof --no-update-lock-file --override-input nixpkgs path:/path/to/nixpkgs
```

NixOS users can enable the optional read-only recorder service:

```nix
{
  inputs.xsprof.url = "github:meillaya/xsprof";
  # inputs.xsprof.inputs.nixpkgs.follows = "nixpkgs";

  # in a NixOS configuration:
  imports = [ inputs.xsprof.nixosModules.default ];
  services.xsprof.recorder.enable = true;
}
```

The service is disabled by default. When enabled it creates an unprivileged
`xsprof` user and runs the same hardened unit as the tarball/deb, with only
`CAP_PERFMON` and `CAP_DAC_READ_SEARCH`. Hardware OpenGL for `xsprof ui` also
needs `hardware.graphics.enable = true`; mesa provides a software fallback.

## Linux tarball

```sh
tar -xzf xsprof-<version>-linux-<arch>.tar.gz
cd xsprof-<version>-linux-<arch>
./bin/xsprof ui
```

For a system install, copy `bin/xsprof` to `/usr/local/bin`, `share/xsprof` to
`/usr/local/share/xsprof`, the desktop file to
`/usr/local/share/applications/`, the icon to
`/usr/local/share/icons/hicolor/scalable/apps/`, the sysusers file to
`/usr/local/lib/sysusers.d/`, and the unit to
`/usr/local/lib/systemd/system/`. Bash/zsh/fish completions and the replay
fixture are included under `share/`. Packaged builds ship no browser assets;
`XSPROF_FIXTURES_DIR` overrides the bundled fixture directory if needed.

The recorder needs `CAP_PERFMON` and tracefs read access. Use the provided
unit or grant equivalent capabilities explicitly. `xsprof doctor --json` names
the missing piece.

## AppImage (Linux x86_64)

The release publishes `Xsprof-<version>-x86_64.AppImage` plus a `.sha256`.
The AppImage bundles the native binary, the replay fixture, the desktop entry,
and the icon. It does **not** bundle X11/GL/mesa driver libraries (the binary
dlopens the host's `libX11.so.6`/`libGL.so.1`) and it ships no web assets.

```sh
sha256sum -c Xsprof-<version>-x86_64.AppImage.sha256
chmod +x Xsprof-<version>-x86_64.AppImage
./Xsprof-<version>-x86_64.AppImage ui       # native console
./Xsprof-<version>-x86_64.AppImage version  # CLI
```

Without FUSE (containers, CI, minimal systems):

```sh
APPIMAGE_EXTRACT_AND_RUN=1 ./Xsprof-<version>-x86_64.AppImage version
# or: ./Xsprof-<version>-x86_64.AppImage --appimage-extract-and-run version
```

The AppImage links the host's glibc (the CI artifact uses the Ubuntu 24.04
baseline) and does not bundle glibc, X11, or GL drivers. It is built for the
host architecture; the CI release artifact is x86_64. aarch64 users can build one natively on an aarch64 Linux host with
`sh tools/package_appimage.sh` or use the tarball/deb.

## Debian package

On Debian or Ubuntu, `./tools/package_deb.sh` builds
`dist/xsprof_<version>-1_<arch>.deb` with the binary, replay fixture,
desktop entry, icon, completions, sysusers entry, and systemd unit. The unit is
installed but not enabled. No web assets are packaged.

## Homebrew

The release workflow renders `Formula/xsprof.rb` from
`packaging/homebrew/` and pushes it to `meillaya/homebrew-xsprof` for strict
releases. The formula is Linux-only. The cask is only rendered after a
notarized, stapled app passes the artifact attestation gate; an ad-hoc app is
never published as a cask.

```sh
brew tap meillaya/xsprof
brew install xsprof          # Linux arm64/x86_64 tarball
```

## macOS app

Strict releases publish `Xsprof-<version>-macos.zip`, a universal
(arm64 + x86_64) Developer ID signed, notarized, and stapled bundle with a
`xsprof/macos-notarization/v1` attestation. Unzip it and open `Xsprof.app`.

Local builds without Apple credentials are explicitly different: they are
ad-hoc signed, named `Xsprof-<version>-macos-unsigned.zip`, and their
attestation records `notarized:false`. They are for local testing only and are
not cask-eligible. Verify them structurally with
`tools/verify_macos_artifact.sh --allow-unnotarized`; run
`tools/package_macos_app.sh` without `XSPROF_NOTARIZE` to produce one.

Real notarization requires a Developer ID Application certificate, notary
credentials (`NOTARY_PROFILE` or Apple ID + team ID + app-specific password),
macOS 14+/Xcode command-line tools, and macOS runner minutes. Without them the
release workflow fails the strict preflight rather than publishing an unsigned
build; the `channel=unsigned` dispatch produces only a labelled prerelease and
never updates the tap.

## Release CI

`.github/workflows/release.yml` builds Linux arm64/x86_64 tarballs and debs,
the x86_64 AppImage (with a FUSE-free smoke test), the universal macOS app,
`SHA256SUMS`, and the attestation. Strict tag releases require all Apple and
tap secrets up front and fail closed; unsigned dispatches are labelled
`-unsigned` and never publish a cask. `.github/workflows/nix.yml` checks the
flake and package, and `zig-ci.yml` runs the offline release-tooling gate.

## Verify

```sh
xsprof version
xsprof help
xsprof doctor --json
xsprof snapshot --replay <fixture.ndjson> --out snapshot.png
```
