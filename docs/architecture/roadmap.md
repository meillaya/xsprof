# Rewrite roadmap and status

Status is updated only when a phase gate actually passes.

| Phase | Scope | Status |
|---|---|---|
| P0 | Archive C++; pin Zig 0.17; vendor stdlib text; skeleton build/CI; guidance docs | **complete** |
| P1 | Core event/JSON/privacy/safety/path/time; proc/sysfs; capabilities; advisor; Chrome Trace; CLI parity | in progress |
| P2 | `xsui` kernel: draw list, CPU raster, TTF text, layout, theme, core widgets, Tester, demo snapshots | planned |
| P3 | Web profiler UI on replay: EventStore/index, Overview/Timeline/Advisor/Events, wasm/WebGL2, `serve`, e2e | planned |
| P4 | Live capture: perf collectors, rings, loss, aggregation, `record`, live SSE, VM validation | planned |
| P5 | Native macOS AppKit/Metal, offscreen parity, hidden smoke, `ui` | planned |
| P6 | Native Linux X11/GL, Xvfb CI, packaging, performance/a11y polish | planned |
| P7 | VM-only BPF `dlopen` gate, final safety/privacy/golden sweep, docs | planned |

## P0 gate (passed)

- C++ archive branch/tag verified.
- Zig 0.17.0 pinned and bootstrapped.
- Stdlib sources/reference/langref vendored as text with offline SHA-256 check.
- `./tools/zig build check` green on macOS: fmt, 600-line limit, vendor hashes,
  9 unit tests.
- No C++ build files on `main`; `simulator/` untouched.

## P1 entry criteria

- Golden fixtures restored to `tests/golden/root/`.
- Schemas for event/preflight/aggregates/advisor/capture-summary under
  `schemas/xsprof/`.
- CLI commands currently exit 2 with “not implemented in this build yet”.
