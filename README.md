<p align="center">
  <img src="assets/logo.svg" alt="xsprof logo" width="180">
</p>

<h1 align="center">xsprof</h1>

<p align="center">Read-only Linux scheduler and memory profiler.</p>

<p align="center">
  <img src="docs/media/watch.gif" alt="xsprof watch running over a real four-CPU perf capture" width="900">
</p>

`xsprof` correlates scheduler and memory events without changing the host. It
records perf tracepoints into bounded rotating segments, extracts the last few
minutes after an incident, exports Chrome Trace, and runs a seven-rule
performance advisor. The UI is one draw list rendered by CPU, Metal, or WebGL2.

## Requirements

Zig 0.17.0 is pinned by `./tools/zig`. `devenv shell` provides git, curl, and
xz but keeps the pinned Zig on `tools/zig`. macOS 15+ and Linux 5.10+ are
supported.
The native macOS UI needs the Xcode SDK; the native Linux UI loads X11 and GLX
at runtime. The shipped binary has no third-party runtime dependencies.

## Build

```sh
./tools/zig build          # zig-out/bin/xsprof
./tools/zig build check    # formatting, line limit, vendor hashes, 90 tests
./tools/zig build web      # wasm UI and browser assets
./tools/zig build run -- help
```

## Use

```sh
xsprof record --duration 2000 --output session.ndjson
xsprof daemon --foreground --dir /var/lib/xsprof
xsprof capture --last 5m --dir /var/lib/xsprof
xsprof watch --dir /var/lib/xsprof
xsprof serve --journal session.ndjson
xsprof ui --replay session.ndjson
xsprof demo
```

`record` needs perf tracepoints and `CAP_PERFMON`; without them it reports
`SKIP` and exits non-zero. `daemon` keeps one capture open, rotates segments,
and writes an atomic manifest. `watch` is the SSH view shown above. `serve`
exposes a loopback replay or live view behind a random token. `ui` opens the
native profiler. Unknown verbs fail closed.

## Safety

Every record carries `host_mutation=false`. The profiler does not write
`/proc` or `/sys`, elevate privileges, enable BPF on a host, or auto-apply
advisor recommendations. `load`, `attach`, `enable`, `mutate`, `apply`,
`sched-ext-attach`, `setaffinity`, `setpriority`, and `bind` are refused.
Runtime samples never include argv, environment variables, secrets, or tokens.

## Package

```sh
./tools/package.sh              # Linux/macOS tarball
./tools/package_macos_app.sh    # universal macOS app, ad-hoc signed
```

## Release status

No `v0.2.0` tag, public release, or Homebrew tap has been published. Packaging,
notarization, and release workflows are in the tree, but publication is blocked
on three external items:

- no Developer ID certificate or notary credentials, so the local macOS app is
  ad-hoc signed;
- exhausted GitHub Actions minutes, so the tag-driven release workflow has not
  run end-to-end;
- no `meillaya/homebrew-xsprof` tap or `HOMEBREW_TAP_TOKEN`.

The Linux tarballs and universal app build locally, and `zig build check`
passes. To publish, configure the signing and tap secrets, push a `v*` tag, and
let the release workflow build, notarize, publish, and update the tap.

## Development

```sh
./tools/zig build test
./tools/zig build fuzz
./tools/zig build service-smoke    # Linux root, disposable VM
```

The demo GIF uses a real capture fixture. Regenerating it needs Go, ffmpeg,
and ttyd:

```sh
go install github.com/charmbracelet/vhs@main
vhs docs/media/watch.tape
```
