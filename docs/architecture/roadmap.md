# Rewrite roadmap and status

Status is updated only when a phase gate actually passes.

| Phase | Scope | Status |
|---|---|---|
| P0 | Archive C++; pin Zig 0.17; vendor stdlib text; skeleton build/CI; guidance docs | **complete** |
| P1 | Core event/JSON/privacy/safety; proc/sysfs; capabilities; advisor; Chrome Trace; CLI parity | **complete** |
| P2 | `xsui` kernel: draw list, CPU raster, TTF text, layout, theme, core widgets, Tester, demo snapshots | **complete** |
| P3 | Web profiler UI on replay: EventStore/index, Overview/Timeline/Advisor/Events, wasm/WebGL2, `serve`, e2e | **complete** |
| P4 | Live capture: perf collectors, rings, loss, aggregation, `record`, live SSE, VM validation | **complete** |
| P5 | Native macOS AppKit/Metal, offscreen parity, hidden smoke, `ui` | **complete** |
| P6 | Native Linux X11/GL, Xvfb CI, packaging, performance/a11y polish | **complete** |
| P7 | VM-only BPF `dlopen` gate, final safety/privacy/golden sweep, docs | **complete** |
| M1 | Flight recorder: daemon, segments, retention, `capture --last`, `watch`, `doctor`, systemd unit | **complete** |
| M2 | Interaction: metrics index, pointer/scroll, filters, selections, live controls | **complete** |
| M3 | Analysis: metrics, compare, reports, CI budget | **complete (first slice)** |
| M4 | Live pipeline: recorder-spool tailing, incremental WASM store, pause/follow | **complete** |
| M5 | Packaging: release CI, universal app, notarization script, Homebrew tap | **tooling complete; publication blocked on external credentials** |
| M6 | Depth: presets, cgroup/PSI probes, overhead meter, fuzz, real fixtures | **complete** |
| M7 | GUI lab: action reducer, source/capture controls, transport, scenarios, headless runner | **in progress** |

## P7 gate (passed)

- `bpf-gate` refuses every host before a BPF syscall; only explicit hypervisor
  markers (Apple Virtualization/QEMU/KVM/Virtual/VMware/Xen/Hyper-V) pass.
- VM evidence: `BPF_PROG_LOAD` + `PERF_EVENT_IOC_SET_BPF` attached a no-op
  `sched_switch` tracepoint program for 200 ms, `host_mutation:false`,
  `libbpf:true` (`libbpf.so.1` dlopen probe).
- The unsafe `bpf` verb remains refused; the safe read-only gate is separate.
- `schemas/xsprof/bpf-gate.v1.schema.json` and CLI parity cover the wire form.
- Final sweep: fmt, 600-line limit, vendor hashes, 58 tests, web smoke,
  hidden macOS smoke, CLI parity, aarch64/x86_64 glibc cross-builds, and
  archive checks all green.

## P0 gate (passed)

- C++ archive branch/tag verified.
- Zig 0.17.0 pinned and bootstrapped.
- Stdlib sources/reference/langref vendored as text with offline SHA-256 check.
- `./tools/zig build check` green on macOS: fmt, 600-line limit, vendor hashes,
  9 unit tests.
- No C++ build files on `main`; the archived simulator stayed untouched through
  the rewrite and was later deleted from `main`.

## P6 gate (passed)

- Native X11 `NSWindow`-equivalent surface with a GLX OpenGL 3.3 context;
  X11/GL loaded through `std.DynLib`, no build-time GUI dependency.
- One instanced draw over the shared `draw.Instance` list; R8 atlas upload;
  keyboard screens/theme/quit and `WM_DELETE_WINDOW`.
- Headless Xvfb smoke renders one frame without mapping the window; a mapped
  window screenshot is committed at `docs/ui/screenshots/p6-linux.png`.
- Dynamic-glibc packaging target documented; static-musl CLI remains supported.

## P5 gate (passed)

- AppKit `NSWindow` + `NSView` hosting a `CAMetalLayer`; direct Objective-C
  runtime bindings with no C shim.
- One instanced Metal pipeline over the shared `draw.Instance` list; 80-byte
  MSL stride padding; offscreen readback.
- Headless Metal/CPU parity: avg channel diff 0.50 on the gallery, no window.
- Hidden-window smoke (`ui --smoke`) creates NSWindow/view/layer and exits
  without ordering it front; `zig build check` runs it on macOS.
- `xsprof ui`, `--replay`, `--view`, `--theme`; keyboard screens/theme/quit.

## P4 gate (passed)

- `perf_event_open` sched_switch/wakeup/migrate + software page faults,
  per-CPU mmap rings, tracepoint format offsets, bounded record parsing.
- `record` writes NDJSON journals and a capture summary; every SKIP/REFUSE
  exits non-zero with `host_mutation=false`.
- Validated in a disposable Linux 7.2 aarch64 podman VM: 68,631 switch
  records in 300 ms, matching a simultaneous tracefs count; lost records are
  explicit markers.
- `serve --live` runs a detached-free capture worker, downsamples to a bounded
  store, emits explicit downsample-loss markers, and exposes one-shot SSE
  batches (`Last-Event-ID`/`id`) plus `/api/journal` snapshots.
- The browser appends SSE lines through `web_append_journal`, re-renders while
  preserving the active screen, and reloads on a buffer-reset event.
- Fully validated in the disposable Linux 7.2 aarch64 VM: a headless Chromium
  client showed LIVE READY capabilities, 51k+ events, 4 CPUs, and loss markers.

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


## Productization progress

- **M0 complete:** long-lived `Capture` with per-batch arenas, `recordStream`,
  stable `EventStore`, incremental `Index` proven against a full Session build.
- **M1 complete:** foreground recorder daemon, rotating segments, atomic
  manifest, retention, `capture --last`, ANSI `watch`, `doctor`, opt-in systemd
  unit, manifest/doctor schemas, restart recovery markers, per-segment metrics
  sidecars, and `qa/service_smoke.sh`. The service smoke starts a transient
  unit with the packaged capability set, verifies the single-writer lock,
  extracts a window, SIGKILLs a session, and verifies restart recovery without
  discarding history.
- **M2 complete:** metrics index, Overview p95 panel, web pointer input,
  timeline click selection and wheel zoom, selected-task detail, event
  scrolling, local file open, web pause/follow, event click-to-timeline,
  native macOS/X11 pointer and scroll input, timeline crosshair hover,
  event-row hover, and combined filters (`c` comm, `P` pid, `k` kind, `l`
  loss/refusal, `x` clear). The timeline applies task/pid constraints; the
  ledger applies all four.
- **M3 complete for the first slice:** `metrics`, `compare`, JSON/Markdown/
  self-contained HTML reports, `--fail-on wait.p95`, schemas, CI guide.
- **M4 complete:** one long-lived capture, recorder-spool tailing with
  `--live-dir`, line-aligned bounded store, incremental WASM store/index,
  aggregated loss markers, and pause/follow controls.
- **M5 tooling complete:** release CI (`.github/workflows/release.yml`),
  universal macOS bundle, Developer ID signing/notarization/stapling script,
  Homebrew formula/cask renderer and tap update job. Actual Developer ID
  notarization and public tap publication require an Apple Developer ID
  certificate plus `APPLE_*`/`HOMEBREW_TAP_TOKEN` secrets that are not in the
  repository. The workflow falls back to an ad-hoc-signed app and never
  labels it notarized. A tag-driven publication run also needs available
  GitHub Actions minutes; the packaging scripts and workflow lint pass
  locally without publishing.
- **M7 in progress:** [`gui-lab.md`](gui-lab.md) defines the action/reducer model,
  source and capture controllers, workbench panels, scenario schema, headless
  `lab` runner, and the L0–L6 delivery sequence. L0+L1 landed with input,
  hit testing, controls, the reducer, source loading, live feed, and capture
  worker. L2 added the native lab rail, source buttons, capture controls,
  transport buttons, and a command palette. L3 adds transport window
  advancement and the inspector; L4 adds the scenario schema, headless
  runner, built-in scenarios, and `zig build lab-smoke`. Web parity and the
  remaining export/compare controls are still open. L5 now uses the lab state
  and rail in the wasm replay client with native-only capture controls
  hidden.
- **M6 complete:** presets, cgroup v2 attribution (`xsprof cgroup --json`),
  PSI (`xsprof pressure --json`), recorder overhead meter, deterministic
  parser fuzzing (`zig build fuzz`), and a real multi-process perf fixture
  (`fixtures/real/scheduler-mix.ndjson`). The overhead work also fixed an
  unbounded CLI-arena leak in the long-lived daemon: RSS is now ~2.5 MB after
  hundreds of thousands of events instead of growing to gigabytes.
