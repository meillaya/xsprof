<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="assets/logo.svg"><img src="assets/logo-light.svg" alt="xsprof logo" width="420"></picture>
  <br>
  <b>A trust-first Linux scheduler flight recorder with an optional native viewer.</b>
</p>

<p align="center">
  <a href="https://github.com/meillaya/xsprof/actions/workflows/zig-ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/meillaya/xsprof/zig-ci.yml?style=flat-square&label=zig-ci" alt="zig-ci status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-72d487?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/version-0.6.1-58d7e8?style=flat-square" alt="version 0.6.1">
</p>

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="design/screenshots/native/dark/home.png"><img src="design/screenshots/native/light/home.png" alt="Home: source selection, capability state, safety contract" width="49%"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="design/screenshots/native/dark/overview.png"><img src="design/screenshots/native/light/overview.png" alt="Overview: capability matrix, per-CPU lanes, evidence" width="49%"></picture>
</p>

`xsprof` records Linux scheduler and memory evidence read-only, keeps a bounded
rolling window on disk, and hands you an offline evidence bundle after an
incident. It never writes scheduler or memory policy, never opens a network
socket, and every serialized record carries `host_mutation=false`. The native
viewer is optional: the recorder, the CLI, and the evidence bundle are the
product.

## 5-minute quickstart

```sh
xsprof record --duration 10s --output session.ndjson   # needs perf permissions
xsprof why --input session.ndjson                      # root-cause report
# rolling recorder + offline incident bundle
sudo xsprof daemon --foreground --dir /var/lib/xsprof --retain 10m --max-bytes 2G
sudo xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
xsprof verify --dir /var/lib/xsprof --json             # segment/state verification
```

The incident folder is self-contained and offline: `window.ndjson`,
`summary.json`, `report.html`, and a Chrome Trace `trace.json` (open it in
Perfetto or `chrome://tracing`; no xsprof server is involved). Without perf
permissions, `xsprof doctor --json`, `xsprof pressure --json`, and
`xsprof cgroup --json` still report read-only host state.

Live capture needs Linux perf tracepoints plus `CAP_PERFMON` (or
`perf_event_paranoid <= 1`) and readable tracefs — see
[recording permissions](docs/guides/capture-permissions.md). The tool shows
`SKIP`/`REFUSE` with the exact reason and never elevates.

## Viewer (optional)

```sh
xsprof                    # native window on a graphical Linux/macOS session
xsprof demo               # bundled replay fixture
xsprof ui --replay session.ndjson
xsprof ui --follow-recorder /var/lib/xsprof   # read-only attach
```

There is no browser, WASM, or HTTP surface. macOS builds a viewer only (Metal
window, replay/follow); macOS cannot capture scheduler events.

## Install

**Nix (Linux x86_64/aarch64, macOS arm64 viewer-only):**

```sh
nix run github:meillaya/xsprof -- record --duration 10s --output session.ndjson
nix profile install github:meillaya/xsprof
nix build .#xsprof                                # from a checkout
```

NixOS recorder service (disabled by default; unprivileged user with only
`CAP_PERFMON` and `CAP_DAC_READ_SEARCH`):

```nix
{
  inputs.xsprof.url = "github:meillaya/xsprof";
  outputs = { nixpkgs, xsprof, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [ xsprof.nixosModules.default { services.xsprof.recorder.enable = true; } ];
    };
  };
}
```

**Release artifacts:** Linux tarballs, Debian packages, and AppImages for
x86_64 and aarch64 (`Xsprof-0.6.1-x86_64.AppImage`,
`xsprof_0.6.1-1_amd64.deb`, `xsprof-0.6.1-linux-x86_64.tar.gz`), published with
`SHA256SUMS` and Sigstore build provenance. Releases are cut from tags only;
verify with `sha256sum -c` and `gh attestation verify <file> -R meillaya/xsprof`.

**macOS is viewer-only and is not a release artifact.** Build it from source
with Nix (`nix build .#xsprof` on aarch64-darwin); the binary is ad-hoc signed
and not notarized. There is no signed app, cask, tap, or `.dmg`, and Gatekeeper
will warn.

**From source:** `./tools/zig build`, then `./zig-out/bin/xsprof`. Zig 0.17.0 is
pinned by `./tools/zig`. Linux with perf tracepoints (the project tests recent
7.x kernels; run `xsprof doctor` on older ones) and runtime-loaded X11/GLX for
the viewer; no third-party runtime dependencies.

## Verification

```sh
./tools/zig build check       # fast local gate: fmt, limits, contracts, unit+fuzz tests
./tools/zig build check-ci    # CI gate: check + platform/media/repo-size/docs-links, no silent SKIPs
./tools/zig build check-vm    # root-only live/service/retention gates, disposable Linux VM
```

`check` and `check-ci` need no network and no privileges. `check-vm` needs a
disposable KVM Linux host with readable tracefs; never run it on a production
host. CI runs `check-ci` on Linux x86_64/aarch64 and `check` on macOS.

## Known limits

- **Read-only by design:** the seven advisor rules are suggestions only; xsprof
  never applies, tunes, or fixes anything.
- **Linux AT-SPI2 is not implemented:** the viewer exposes canonical
  accessibility-tree JSON plus keyboard navigation and reports the AT-SPI2
  bridge as `DEGRADED`. macOS VoiceOver needs a human-run audit before spoken
  navigation can be claimed.
- **Display limits:** the viewer renders at 1x (no Retina 2x), X11 IME/paste
  parity is not implemented, and automation never opens a real window.
- **Capture permissions are external:** enabling live capture is the operator's
  decision; xsprof never elevates or changes kernel policy.
- **Retention is workload-dependent:** the ten-minute age cap is bounded by the
  byte budget and event rate; the recorder and `verify` report the actual
  covered span, never the configured cap.
- **No telemetry, ever:** feedback channels are opt-in and privacy-filtered
  (see the [incident feedback form](.github/ISSUE_TEMPLATE/incident-feedback.yml)).

## Documentation

| Doc | Contents |
|---|---|
| [Quickstart](docs/guides/quickstart.md) | build, first capture, incident, recorder, viewer |
| [Install](docs/guides/install.md) | Nix, NixOS module, AppImage, deb, tarball, macOS viewer |
| [Recording permissions](docs/guides/capture-permissions.md) · [Flight recorder](docs/guides/flight-recorder.md) | `setcap`, daemon, retention, bundles |
| [top & why](docs/guides/top-why.md) · [Compare in CI](docs/guides/compare-ci.md) | live ranking, root cause, regression gates |
| [Architecture](docs/architecture/overview.md) · [Events](docs/architecture/events.md) · [Raw segment](docs/architecture/raw-segment-v1.md) · [Retention](docs/architecture/retention.md) | internals |
| [Safety invariants](docs/safety/invariants.md) · [Maintaining](docs/maintaining.md) | contract, gates, release checklist |
| [Linux](docs/platforms/linux.md) · [macOS viewer](docs/platforms/macos-viewer.md) · [Design contract](DESIGN.md) · [xsui](lib/xsui/README.md) | platform and viewer |
| [History](docs/history/README.md) | superseded roadmaps and audits |

## License

MIT — see [LICENSE](LICENSE). Bundled third-party notices (nanoui, JetBrains
Mono) are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<p align="center"><sub>Read-only by design · host_mutation=false everywhere</sub></p>
