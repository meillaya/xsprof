<p align="center">
  <img src="assets/logo.svg" alt="xsprof logo" width="180">
</p>

<h1 align="center">xsprof</h1>

<p align="center">Read-only Linux scheduler and memory profiler with a GPU operator console.</p>

<p align="center">
  <img src="design/media/xsprof-ui-demo.gif" alt="Replay of a real 110,284-event Linux-VM perf capture" width="900">
</p>

<p align="center"><strong>Replay</strong> of a real 110,284-event Linux-VM perf capture ·
<a href="design/media/xsprof-ui-demo.mp4">full MP4</a></p>

<p align="center">
  <img src="design/media/xsprof-ui-live.gif" alt="Live VM stream captured through the loopback tunnel" width="900">
</p>

<p align="center"><strong>Live</strong> VM stream over the loopback tunnel ·
<a href="design/media/xsprof-ui-live.mp4">full MP4</a></p>

`xsprof` is the product UI: one GPU-rendered console for choosing, viewing,
recording, auditing, and exporting read-only scheduler/memory captures. Launch
it, choose a source, inspect the evidence, manage the recorder, and export a
window without dropping to a terminal. The CLI remains for scripting and CI.

The console has eight routes: Home, Overview, Timeline, Advisor, Events,
Recorder, Audit, and Settings. First run shows a four-step onboarding overlay;
later runs start at Home with recent sources and capability state. Source
choices are Live (Linux perf, capability-gated), Replay (journal file),
Recorder window (1m/5m/10m/retained/custom from a state directory), and the
bundled demo. File and directory selection is drawn by the same GPU UI. The
only OS/browser utilities are clipboard, the browser's file input, and
accessibility APIs.

The GPU surface is the standalone [`lib/xsui`](lib/xsui/README.md) package:
one draw list rendered by CPU, Metal, OpenGL 3.3, or WebGL2. CPU is canonical;
Metal, GL, and WebGL2 consume the same instances and atlas. The historical lab
bench remains a headless developer tool.

## Requirements

Zig 0.17.0 is pinned by `./tools/zig`. `devenv shell` provides git, curl, and
xz but keeps Zig on `tools/zig`. macOS 15+ and Linux 5.10+ are supported.
The native macOS UI needs the Xcode SDK; the native Linux UI loads X11 and GLX
at runtime. The shipped binary has no third-party runtime dependencies.

## Build

```sh
./tools/zig build                # binary plus web assets in zig-out
./tools/zig build check          # fmt, line limit, vendor, tests, QA gates
./tools/zig build web            # wasm/browser assets only
./tools/zig build run -- help
```

## Launch

```sh
./zig-out/bin/xsprof             # native console on an interactive graphical TTY
./zig-out/bin/xsprof demo        # bundled capture (web fallback when no display)
./zig-out/bin/xsprof serve       # loopback browser console
XSPROF_NO_UI=1 ./zig-out/bin/xsprof   # quickstart only; never opens a window
```

Bare `xsprof` opens the console only when stdout is a terminal and a display is
available. Packaged app bundles set `XSPROF_APP_MODE=1` and always open the
console. Scripts must use an explicit verb (or `XSPROF_NO_UI=1`) and stay
headless.

### Live and recorder

```sh
sudo xsprof ui --live --duration 0        # Linux perf; until stopped
xsprof ui --follow-recorder /var/lib/xsprof
xsprof ui --replay session.ndjson
sudo xsprof daemon --foreground --dir /var/lib/xsprof --retain 10m --max-bytes 2G
xsprof verify --dir /var/lib/xsprof --json
```

The native console starts its own in-process, read-only recorder when capture
controls are enabled in Settings and `live.probe` is READY. It writes compact
`.xsraw` segments, keeps a durable manifest, and shows the real covered span,
loss, and sampler state. External systemd/CLI recorders are attach-only; the UI
does not kill them. macOS has no perf backend: it can follow a recorder
directory exported from Linux and shows live capture as SKIP with a reason.

### Compact raw 10-minute tier

Recorder raw segments are `xsprof/raw-segment/v1` compact blocks (64-byte
header, CRC-32C 32 KiB blocks, footer, varint/zigzag events, block-local string
tables). They hold much longer than the old NDJSON raw form under the same
byte budget, while `capture`, `incident`, `why`, and the UI still emit
canonical `xsprof/event/v1` NDJSON. Ten minutes is an age cap, not a promise:
the byte budget and workload binding are reported honestly by the UI and
`verify`. Legacy `.ndjson` state remains readable.

```sh
xsprof capture --last 10m --dir /var/lib/xsprof --out window.ndjson
xsprof incident --last 10m --dir /var/lib/xsprof --max-window-bytes 4G
xsprof history --last 10m --dir /var/lib/xsprof
xsprof watch --dir /var/lib/xsprof
```

`incident` writes `window.ndjson`, `summary.json`, `report.html`, and
`trace.json` into a self-contained folder. Oversized windows refuse rather than
truncate silently. History sidecars cover the longer horizon.

## Console routes

`0` Home · `1` Overview · `2` Timeline · `3` Advisor · `4` Events ·
`5` Recorder · `6` Audit · `7` Settings · `Cmd/Ctrl+K` palette ·
`?` keyboard help · `Esc` close. Every pointer action has a keyboard
equivalent, and every focusable control is in the accessibility tree.

The Recorder route starts/stops/restarts the owned capture, configures the
state directory and retention, lists compact segments, verifies the state,
streams window/incident/trace/report exports, and shows sidecar history.
Audit shows provenance, manifest lifecycle,
verification, capability/gate evidence, and the bounded operator action log.
Settings persists `xsprof/ui-settings/v1` atomically and includes appearance,
capture defaults, storage, accessibility, and diagnostics. Snapshot mode never
reads user settings.

## Accessibility

The same draw/hit pass produces a bounded `xsprof/a11y-tree/v1` tree (roles,
labels, values, selected/focus flags, focus order, hit testing). Web mirrors it
to a hidden DOM/ARIA tree; macOS exposes it through NSAccessibility; Linux emits
canonical JSON and reports the AT-SPI bridge as DEGRADED with the exact reason.
`snapshot --a11y FILE` writes the deterministic tree. Focus traversal follows
the tree order and dialogs trap focus.

## CLI

Visible workflows: `ui`, `record`, `top`, `why`, `incident`, `doctor`
(plus `serve`, `demo`, `version`, `help`). Every automation verb remains
valid but hidden from the short help: `daemon`, `capture`, `history`,
`watch`, `verify`, `advise`, `metrics`, `compare`, `timeline`,
`snapshot`, `preflight`, `capabilities`, `pressure`, `cgroup`,
`bpf-gate`, `lab`, `completions`. Use `xsprof help --all` for the grouped
list and `xsprof completions <shell> --all` for full completions.

## Safety

Every record carries `host_mutation=false`. The profiler does not write
`/proc` or `/sys`, elevate privileges, enable BPF on a host, or auto-apply
advisor recommendations. The BPF gate remains VM-marker-gated and host-refused.
`load`, `attach`, `enable`, `mutate`, `apply`, `sched-ext-attach`,
`setaffinity`, `setpriority`, and `bind` are refused. Runtime samples never
include argv, environment variables, secrets, or tokens. The UI may start and
stop its own read-only capture, writing only its state/output directories; the
web server remains GET/HEAD-only and loopback/token-gated.

## Package

```sh
nix build .#xsprof                          # Linux/macOS, pinned Zig 0.17.0
nix develop                                 # pinned dev shell
./tools/package.sh                          # Linux/macOS tarball
./tools/package_deb.sh                      # Debian package (dpkg-deb host)
./tools/package_macos_app.sh                # universal macOS app
./tools/package_macos_app.sh                # XSPROF_NOTARIZE=1 for Developer ID
```

`flake.nix` provides Linux x86_64/aarch64 and macOS arm64/x86_64 packages, an
opt-in NixOS recorder module with the documented capability set, checks, and a
devShell. Intel macOS uses the locked `nixpkgs-darwin` input because current
nixos-unstable dropped x86_64-darwin. The macOS release path is fail-closed:
tag releases require Developer ID/notary credentials and a notarization
attestation before the cask is published; unsigned previews use the
`-unsigned` name and never touch the tap. Actual notarization and tap
publication require external Apple/tap credentials and are not claimed here.

## Development

```sh
./tools/zig build check
./tools/zig build fuzz
./tools/zig build web-ui-smoke
./tools/zig build web-smoke
./tools/zig build compact-roundtrip
./tools/zig build release-tooling
(cd lib/xsui && ../../tools/zig build test)   # package in isolation
./tools/zig build service-smoke               # Linux root, disposable VM
sudo ./tools/zig build live-smoke             # Linux root, disposable VM
qa/retention_bench.sh 600000 0 2G yes         # Linux root, disposable VM
```

More: [quickstart](docs/guides/quickstart.md), [top/why](docs/guides/top-why.md),
[event field semantics](docs/architecture/events.md),
[raw segment format](docs/architecture/raw-segment-v1.md),
[retention](docs/architecture/retention.md), [audit](docs/audit/v0.4.0.md).

## Known limits

- Linux AT-SPI2 is not built in this pass; the canonical tree, keyboard focus,
  JSON dump, and a visible DEGRADED reason are provided. Web/macOS bridges are
  implemented; VoiceOver still needs a human-run audit.
- Native capture requires Linux perf tracepoints and `CAP_PERFMON` (or
  `perf_event_paranoid <= 1`). macOS live capture is intentionally SKIP.
- The 10-minute raw tier is workload/budget dependent; the UI/verify report the
  actual covered span, never a configured cap.
- Retina windows draw at 1x for now; resize is supported and tested. X11 IME
  and paste parity remain follow-ups.
- Web is a viewer: capture/recorder control and host directory browsing fail
  closed with explicit reasons. The browser file input is a utility.
- The A/B compare report and lab scenario runner remain headless automation
  tools (`xsprof compare`, `xsprof lab`); they are not console controls.
- Real Developer ID notarization, Gatekeeper acceptance, and tap publication
  require external credentials; the repository ships fail-closed tooling and
  local dry-run tests, not credentials.

## License

MIT. See [LICENSE](LICENSE). The bundled JetBrains Mono font is OFL; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
