<p align="center">
  <img src="assets/logo.svg" alt="xsprof logo" width="180">
</p>

<h1 align="center">xsprof</h1>

<p align="center">Read-only Linux scheduler and memory profiler.</p>

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

`xsprof` correlates scheduler and page-fault events without changing the host.
It records perf tracepoints into bounded rotating segments, extracts the recent
window after an incident, and writes a self-contained offline bundle (raw
window, canonical summary, static HTML report, Chrome Trace). It runs a
seven-rule advisor that reports `SKIP` when a rule's signal was not captured.
The recorder's own task is identified and excluded from rankings and
wakeup-churn analysis. Its operator console is the prototype from
[`design/index.html`](design/index.html): overview, timeline, advisor, events,
and capture status, fed by real replay/live data with no fabricated metrics.
The GPU surface is the standalone [`lib/xsui`](lib/xsui/README.md) package:
one draw list rendered by CPU, Metal, OpenGL 3.3, or WebGL2. The historical
lab bench remains available as a headless developer tool, not the main UI.

## Requirements

Zig 0.17.0 is pinned by `./tools/zig`. `devenv shell` provides git, curl, and
xz but keeps the pinned Zig on `tools/zig`. macOS 15+ and Linux 5.10+ are
supported.
The native macOS UI needs the Xcode SDK; the native Linux UI loads X11 and GLX
at runtime. The shipped binary has no third-party runtime dependencies.

## Build

```sh
./tools/zig build                # binary plus web assets in zig-out
./tools/zig build check          # fmt, line limit, vendor, tests, QA gates
./tools/zig build web            # wasm/browser assets only
./tools/zig build run -- help
```

`./tools/zig build` includes the web console assets, so a clean checkout can run
`./zig-out/bin/xsprof demo` immediately.

## Use: three workflows

### 1. Try it with no privileges

```sh
./zig-out/bin/xsprof demo
# opens a loopback URL; the token is in the fragment (#token=…)
```

### 2. Live view and root-cause in one command

```sh
sudo xsprof top                          # live 5s ranked view
sudo xsprof top --duration 10s --json    # scriptable snapshot
sudo xsprof why --last 10m --dir /var/lib/xsprof
sudo xsprof why --input session.ndjson --json
```

`top` and `why` fail closed with `SKIP`/`REFUSE` and a reason when perf is
unavailable. `why` reports the top wait tasks, waker→woken chains, faults, and
advisor rule status.

### 3. Flight recorder and incident bundle

```sh
sudo xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G --history-interval 60s --history-retain 24h
sudo xsprof incident --last 10m --dir /var/lib/xsprof   # defaults to ./xsprof-incident-<timestamp>
xsprof history --last 10m --dir /var/lib/xsprof
xsprof capture --last 5m --dir /var/lib/xsprof --out window.ndjson
xsprof watch --dir /var/lib/xsprof
```

`incident` writes `window.ndjson`, `summary.json`, `report.html`, and
`trace.json` into a self-contained folder. `report` is an alias. Raw segments
are bounded by `--max-bytes`; history sidecars are written on the interval and
retained for the history horizon. SIGTERM stops the daemon cleanly.

### Other commands

```sh
xsprof record --duration 2s                 # session-<timestamp>.ndjson
xsprof record --duration 2s --output -      # NDJSON to stdout
xsprof advise --input session.ndjson --json
xsprof metrics --input session.ndjson
xsprof compare --base before.ndjson --candidate after.ndjson --fail-on wait.p95=10%
xsprof serve --journal session.ndjson
xsprof ui --replay session.ndjson
xsprof snapshot --replay session.ndjson --view timeline --theme mocha
xsprof lab --scenario scenarios/healthy.json --out /tmp/lab --json
```

CPU is the canonical renderer; Metal, OpenGL, and WebGL2 consume the same draw
list and browser-generated text atlas. The web console reads `/api/journal`,
`/api/meta`, `/api/recorder`, and the live SSE stream. Replay and live sessions
use the journal/recorder APIs; `?demo=1` is only for design comparison.
`snapshot --demo-model` is the corresponding developer flag.

`record` needs perf tracepoints and `CAP_PERFMON`; without them it reports
`SKIP` and exits non-zero. `daemon` keeps one capture open, rotates segments,
and writes an atomic manifest. `serve` is loopback-only and token-gated. Unknown
verbs fail closed.

## Safety

Every record carries `host_mutation=false`. The profiler does not write
`/proc` or `/sys`, elevate privileges, enable BPF on a host, or auto-apply
advisor recommendations. The BPF gate remains VM-marker-gated and host-refused. `load`, `attach`, `enable`, `mutate`, `apply`,
`sched-ext-attach`, `setaffinity`, `setpriority`, and `bind` are refused.
Runtime samples never include argv, environment variables, secrets, or tokens.

## Package

```sh
./tools/package.sh              # Linux/macOS tarball
./tools/package_macos_app.sh    # universal macOS app, ad-hoc signed
```

## Development

```sh
./tools/zig build check
./tools/zig build fuzz
./tools/zig build web-ui-smoke
./tools/zig build web-smoke
(cd lib/xsui && ../../tools/zig build test)   # package in isolation
./tools/zig build service-smoke               # Linux root, disposable VM
sudo ./tools/zig build live-smoke             # Linux root, disposable VM
qa/retention_bench.sh 600000 0 2G yes         # Linux root, disposable VM
```

More: [quickstart](docs/guides/quickstart.md), [top/why](docs/guides/top-why.md),
[event field semantics](docs/architecture/events.md), [audit](docs/audit/v0.3.0.md).

## License

MIT. See [LICENSE](LICENSE). The bundled JetBrains Mono font is OFL; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
