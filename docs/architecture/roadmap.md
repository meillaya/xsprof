# Rewrite roadmap and status

Status is updated only when a phase gate actually passes.

| Phase | Scope | Status |
|---|---|---|
| P0 | Archive C++; pin Zig 0.17; vendor stdlib text; skeleton build/CI; guidance docs | **complete** |
| P1 | Core event/JSON/privacy/safety; proc/sysfs; capabilities; advisor; Chrome Trace; CLI parity | **complete** |
| P2 | `xsui` kernel: draw list, CPU raster, TTF text, layout, theme, core widgets, Tester, demo snapshots | **complete** |
| P3 | Web profiler UI on replay: EventStore/index, Overview/Timeline/Advisor/Events, wasm/WebGL2, `serve`, e2e | **complete** |
| P4 | Live capture: perf collectors, rings, loss, aggregation, `record`, live SSE, VM validation | next |
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

## P3 gate (passed)

- `Session` replay model: bounded events, per-CPU switch slices, capabilities,
  top tasks, loss/refusal counters, aggregate derivation.
- Real Overview/Timeline/Advisor/Events/Capture screens, selected by
  `snapshot --view` or `?screen=`.
- `xsprof serve` loopback bridge: token-gated `/api/meta` + `/api/journal`,
  whitelisted static assets, no POST, no traversal.
- `wasm32-freestanding` UI core + WebGL2 instanced renderer (one draw call),
  R8 glyph atlas, per-instance clipping, keyboard screen switching.
- Headless Chromium screenshots for Overview and Timeline; `web-smoke` gate.
- Native `snapshot --replay` produces the same views through the CPU renderer.

## P2 gate (passed)

- Flat instance draw list + R8 glyph atlas.
- Bundled JetBrains Mono (OFL) with an in-repo TrueType reader: simple and
  composite glyphs, cmap 4/12, scanline coverage, gamma-corrected alpha.
- CPU reference rasterizer with rounded rects, borders, glyphs, clipping.
- Dependency-free PNG writer and headless `xsprof snapshot` command.
- Flex/column layout with padding, gap, flex, alignment, clipping, custom
  paint nodes, and cached per-frame measures.
- Reusable panel/chip/stat/rule widgets and a layout-driven profiler gallery.
- `xsui.Tester` with deterministic clock + framebuffer hash + snapshot.
- Golden framebuffer hash for the 960x540 gallery; 48 tests pass.
- Native Metal/WebGL2 draw-list consumers remain in P3/P5 by design.

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
