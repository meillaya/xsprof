# Rewrite roadmap and status

Status is updated only when a phase gate actually passes.

| Phase | Scope | Status |
|---|---|---|
| P0 | Archive C++; pin Zig 0.17; vendor stdlib text; skeleton build/CI; guidance docs | **complete** |
| P1 | Core event/JSON/privacy/safety; proc/sysfs; capabilities; advisor; Chrome Trace; CLI parity | **complete** |
| P2 | `xsui` kernel: draw list, CPU raster, TTF text, layout, theme, core widgets, Tester, demo snapshots | next |
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

## P1 gate (passed)

- Canonical `xsprof/event/v1` serializer matches both archived event goldens
  byte-for-byte; privacy redaction is enforced at the serializer.
- SafePath and the unsafe-verb matrix are tested.
- `preflight --json` and `capabilities --json` work read-only on macOS with
  explicit SKIP/REFUSE reasons; the Linux branch cross-compiles for
  x86_64/aarch64.
- Advisor JSON/Markdown ports all seven rules, exact thresholds, stable
  ordering, and suggestions-only output.
- Journal ingestion accepts NDJSON and the `journal/v1` wrapper, rejects
  malformed and `host_mutation=true` rows, and feeds the timeline.
- Chrome Trace export has corrected switch durations, paired wakeup flows,
  consistent ns→µs conversion, explicit loss markers, windowing, and chunks.
- `qa/cli_parity.sh` and 36 unit tests pass; `zig build check` is green.
- `record`, `serve`, `snapshot`, and `ui` still exit 2 until their phases.
