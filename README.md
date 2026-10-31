# exasphere / xsprof

`xsprof` is a read-only Linux scheduler and memory profiler, rewritten from
scratch in **Zig 0.17.0**. It correlates scheduler and memory events, exports
Chrome Trace timelines, runs a seven-rule Performance Advisor, and renders a
dense operator UI on the GPU.

**Status: P0–P7 complete. The full rewrite builds on Zig 0.17.0 with web, native macOS, and native Linux surfaces; the Linux live path and VM-only BPF gate are validated in a disposable VM.** The historical C++ implementation is
preserved on the local branch `archive/cpp-0.1.0` and tag `cpp-0.1.0`. The
archived deterministic simulator under `simulator/` is excluded from this
build and is not modified by the rewrite.

## Safety model

- Read-only by default; every record carries `host_mutation=false`.
- `load`, `attach`, `enable`, `mutate`, `apply`, `sched-ext-attach`,
  `setaffinity`, `setpriority`, and `bind` refuse with a non-zero exit.
- No privilege elevation and no writes to `/proc` or `/sys`.
- Runtime samples never expose argv, environment, secrets, or tokens.
- Advisor recommendations are suggestions only; nothing is auto-applied.
- BPF is VM-marker-gated and refuses on the host.
- The UI is a read-only viewer. It has no controls that mutate the host.

## Requirements

- Zig 0.17.0. `./tools/zig` downloads the verified host toolchain on first use.
- macOS 15+ or Linux 5.10+.
- Native macOS UI additionally needs the Xcode SDK (AppKit/Metal frameworks).
- Native Linux UI needs glibc, X11, and OpenGL/GLX at runtime; they are loaded
  with `dlopen`, not linked at build time.
- No C compiler, Python, npm, or third-party build dependency is required for
  the shipped binary. Python is only used to regenerate vendored Zig text;
  headless browser screenshots use a developer-installed Playwright.

## Build

```sh
./tools/zig build            # build zig-out/bin/xsprof
./tools/zig build check      # fmt + line limit + vendor hashes + tests
./tools/zig build run -- help
./tools/zig build test
./tools/zig build web          # wasm + browser assets into zig-out/web
./tools/zig build web-smoke    # loopback/token/no-POST smoke test
```

The pinned standard-library source and language reference are vendored as
grep-friendly text under `docs/vendor/zig-0.17.0/`. See
`docs/zig-0.17-api-usage.md` before using non-obvious 0.17 APIs.

## Current commands

```text
xsprof help | version
xsprof preflight --json
xsprof capabilities --json
xsprof advise --json|--md
xsprof timeline --input journal.jsonl [--window start:end] [--chunk-size N]
xsprof record --duration ms [--output journal.jsonl]
xsprof serve [--journal journal.jsonl] [--live]
xsprof snapshot [--replay journal.jsonl]
xsprof daemon --foreground --dir /var/lib/xsprof
xsprof capture --last 5m --dir /var/lib/xsprof
xsprof watch --dir /var/lib/xsprof
xsprof doctor --json
xsprof ui [--replay journal.jsonl] [--view overview|timeline|advisor|events|capture]
xsprof bpf-gate --json
```

Native Linux builds use `-Dtarget=<arch>-linux-gnu` for the window path; the
static-musl CLI still works but cannot `dlopen` system X11/GL.

The web replay client is served read-only over loopback:

```sh
./tools/zig build web
./zig-out/bin/xsprof serve --journal fixtures/ui/healthy.ndjson
```

Unknown commands fail closed with a refusal record. The unsafe `bpf` verb is
always refused; `bpf-gate` is the VM-marker-gated read-only lane.

## Layout

```text
src/core/        event, canonical JSON, privacy, safety, paths, time
src/os/linux/    /proc, /sys, tracefs, perf_event_open, BPF (VM only)
src/capture/     preflight, scheduler/memory collectors, live pipeline
src/analyze/     seven-rule Performance Advisor
src/viz/         Chrome Trace export
src/stream/      bounded event store, derived slices/flows, journal
src/serve/       read-only loopback HTTP/SSE bridge
src/ui/          xsui: custom GPU UI library (CPU/Metal/WebGL2)
src/app/         profiler screens
src/platform/    macOS, Linux, web, headless surfaces
web/             dependency-free browser shell and shaders
docs/vendor/     vendored Zig 0.17 reference text
```

## Documentation

- `AGENTS.md` — rules for working in this repository.
- `DESIGN.md` — profiler UI contract and safety copy.
- `docs/architecture/` — overview, parity inventory, roadmap.
- `docs/safety/` — invariants and test gates.
- `docs/zig-0.17-api-usage.md` — pinned Zig API notes.

This project makes no production, release, or performance-capacity claim.
`PASS`/`READY` describes a gate result only.
