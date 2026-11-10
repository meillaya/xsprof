# Install

Releases are **tag-first**: artifacts are published only from a pushed
`vX.Y.Z` tag that equals the manifest/runtime/CHANGELOG/README version, after
the full `check-ci` gate passes. Linux is the capture platform; the macOS
build is a viewer only and is not published as a signed artifact.

## Nix (recommended)

The flake supports `x86_64-linux` and `aarch64-linux` (capture + viewer) and
`aarch64-darwin` (viewer only).

```sh
nix run github:meillaya/xsprof -- record --duration 10s --output session.ndjson
nix profile install github:meillaya/xsprof
nix develop                                   # pinned Zig + dev tools
nix build .#xsprof                            # from a checkout
nix flake check                               # package smoke, Zig pins, version sync, NixOS module
```

Zig 0.17.0 is fetched by hash from ziglang.org (`nix/zig.nix`, mirrored from
`tools/bootstrap.sh`); nixpkgs' own Zig is deliberately unused. The xsprof build
itself is sandboxed and offline. Offline verification after the store is warm:

```sh
nix build .#xsprof --offline --option substitute false
nix build .#xsprof --no-update-lock-file --override-input nixpkgs path:/path/to/nixpkgs
```

## NixOS recorder service (opt-in)

The module creates an unprivileged `xsprof` user and grants only
`CAP_PERFMON` and `CAP_DAC_READ_SEARCH`. It is disabled by default.

```nix
{
  inputs.xsprof.url = "github:meillaya/xsprof";
  outputs = { self, nixpkgs, xsprof, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        xsprof.nixosModules.default
        {
          services.xsprof.recorder.enable = true;
          # hardware.graphics.enable = true;   # only needed for the viewer
        }
      ];
    };
  };
}
```

Options: `user`, `group`, `stateDir` (default `/var/lib/xsprof`, must live
under `/var/lib`), `retain`/`maxBytes` (default `10m`/`2G`),
`historyInterval`/`historyRetain` (default `60s`/`24h`), `package`, and
`extraArgs` (checked against unsafe verbs; evaluation fails on a mutation
verb).

## Release artifacts (Linux)

Each release publishes checksummed x86_64/aarch64 Linux artifacts plus Sigstore
build provenance; there is no macOS artifact.

| Artifact | Contents |
|---|---|
| `xsprof-0.6.0-linux-<arch>.tar.gz` | binary, fixture, desktop entry/icon, completions, systemd unit, sysusers entry |
| `xsprof_0.6.0-1_<arch>.deb` | same layout under `/usr`; unit installed but not enabled |
| `Xsprof-0.6.0-<arch>.AppImage` | single-file Linux app; host X11/GL for the viewer |

Verify a download:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify Xsprof-0.6.0-x86_64.AppImage -R meillaya/xsprof
```

### AppImage

```sh
chmod +x Xsprof-0.6.0-x86_64.AppImage
./Xsprof-0.6.0-x86_64.AppImage version
./Xsprof-0.6.0-x86_64.AppImage record --duration 10s --output session.ndjson
```

The AppImage links the host glibc and does not bundle glibc, X11, or GL
drivers. Without FUSE (containers, CI):

```sh
APPIMAGE_EXTRACT_AND_RUN=1 ./Xsprof-0.6.0-x86_64.AppImage version
```

### Debian / Ubuntu

```sh
sudo dpkg -i xsprof_0.6.0-1_amd64.deb
xsprof version
```

### Tarball

```sh
tar -xzf xsprof-0.6.0-linux-x86_64.tar.gz
./xsprof-0.6.0-linux-x86_64/bin/xsprof version
```

Copy `bin/xsprof` to `/usr/local/bin`, `share/*` to
`/usr/local/share/xsprof`, and the systemd/sysusers files to their standard
locations for a system install. `XSPROF_FIXTURES_DIR` overrides the bundled
fixture path.

## macOS viewer (build from source only)

macOS has no perf backend: the build is a viewer (replay/follow a recorder
exported from Linux), not a capture tool. It is **not notarized and not
published**: the binary is ad-hoc signed, Gatekeeper warns, and there is no
signed app, cask, tap, or `.dmg`.

```sh
nix build .#xsprof          # aarch64-darwin
./result/bin/xsprof ui --replay session.ndjson
```

Hardware OpenGL is needed for the viewer (`hardware.graphics.enable = true` on
NixOS); macOS uses Metal. The flake evaluates `aarch64-darwin`; Intel macOS is
out of scope.

## From source

```sh
git clone https://github.com/meillaya/xsprof && cd xsprof
./tools/zig build
./zig-out/bin/xsprof version
```

Requirements: Linux with perf tracepoints (the project tests recent 7.x
kernels; `xsprof doctor` reports what an older kernel exposes; the viewer needs
runtime-loaded X11/GLX and a GL 3.3-class driver), or macOS 15+ arm64 for the
viewer. Zig 0.17.0 is pinned by `./tools/zig`; there are no third-party runtime
dependencies. `git`, `curl`,
and `xz` are needed only for the first toolchain bootstrap (`nix develop`
provides them).

## Enable capture

Live capture is capability-gated. The operator chooses between `setcap`, a
privileged foreground daemon, systemd, or the NixOS module — see
[recording permissions](capture-permissions.md). xsprof never elevates, changes
sysctls, or writes tracefs policy.
