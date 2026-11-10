# Architecture overview

`xsprof` is a trust-first Linux scheduler flight recorder. The core (capture,
recorder, analysis, evidence) is independent of the optional viewer (`xsui` plus
`src/app/design`), which consumes the same data. There is no browser/WASM/
HTTP/server surface.

```
perf_event_open / tracefs / /proc / /sys / cgroup / PSI      (read-only)
        |
   capture threads -> bounded SPSC rings -> ordering/aggregation -> EventStore
        |                                                        |
        |                                                        +-> compact .xsraw segments + manifest
        |                                                        +-> canonical NDJSON export
        |                                                        +-> metrics / advisor / why / incident
        v
   viewer state (replay/live/follow) -> xsui tree -> layout -> DrawList
                                                               |
                                      +------------------------+------------------+
                                   CPU raster          Metal (macOS viewer)   GL 3.3 (Linux)
```

## Layers

| Layer | Path | Rule |
|---|---|---|
| Core | `src/core/` | Zig std only; no OS/UI imports; event model, canonical JSON writer, version, schema helpers |
| Linux OS | `src/os/linux/` | read-only; non-Linux returns SKIP/REFUSE |
| Capture | `src/capture/` | collectors, rings, ordering, loss markers |
| Stream | `src/stream/` | bounded event store, indexes, live feed |
| Recorder | `src/recorder/` | compact segments, manifest, retention, extraction, verify, daemon |
| Incident | `src/incident/` | bounded window scan, summary/trace/report bundle |
| Analysis | `src/analyze/` | pure advisor over aggregates; suggestions only |
| Viz | `src/viz/` | Chrome Trace serialization |
| TUI | `src/tui/` | bounded ANSI `watch`/dashboard views |
| UI | `lib/xsui/` | standalone native package: CPU rasterizer + Metal/GL backends, fonts/shaders |
| Viewer app | `src/app/design/` | optional, frozen viewer routes over stream/analysis |
| Platform | `src/platform/` | macOS AppKit, Linux X11/GLX, native effect execution, headless smokes |
| CLI | `src/cli/`, `src/main.zig` | dispatch only; operator surface + hidden automation verbs |

The lab/experiment lane, the legacy five-screen app, and the browser surface
were removed; historical material is in [`docs/history/`](../history/README.md).

## Data model and formats

- `RawEvent` is a compact struct: profiler event kinds, ns timestamps,
  CPU/pid/tid, packed `a/b/c`, bounded `comm`, bounded/sanitized `detail`.
- `EventStore` is bounded. Overflow emits explicit loss markers; it never
  interpolates or silently drops.
- Canonical wire form is `xsprof/event/v1` NDJSON: keys strictly ascending,
  compact separators, `host_mutation=false` on every row. Twenty canonical
  schemas live in `schemas/xsprof/`.
- Raw recorder storage is `xsprof/raw-segment/v1` compact blocks (`.xsraw`,
  ~12–13 bytes/event); extraction, incident, and viewer output remain canonical
  NDJSON. See [raw-segment-v1.md](raw-segment-v1.md).
- `Slice`/`Flow` are derived at ingest for the timeline: switch duration = next
  switch on the same CPU; wakeup flows pair to the next matching switch;
  unmatched flows and loss are shown explicitly.
- Aggregates are the frozen 21-field advisor input; uncollected signals stay
  zero with collection flags/capabilities so no false findings fire.

## Read-only host probes

Three commands expose host state without capture privileges. All are
read-only, emit canonical JSON, and exit non-zero when a signal is unavailable
instead of inventing zeros.

- **`pressure --json`** reads `/proc/pressure/{cpu,memory,io}` PSI counters.
  `avg*_bp` is basis points (`123` = 1.23%); `full` is absent where the kernel
  does not provide it. Non-Linux/PSI-less kernels return `SKIP` + reason.
- **`cgroup --json`** joins bounded `/proc/<pid>/cgroup` membership with
  `<pid>/comm` on cgroup v2 (≤512 groups, ≤100k tasks, sorted). It is a live
  snapshot, not historical event attribution, and never creates/joins/writes a
  cgroup.
- **Recorder overhead meter:** the daemon samples `/proc/self/schedstat` and
  `VmRSS` before/after, reporting `wall_ms`, `cpu_ms`, `rss_kb`,
  `events_per_sec`, `bytes_per_sec`, and `overhead_bp` (basis points of one
  CPU). `overhead_available=false` when schedstat is unreadable.

## Threading and backpressure

- The viewer thread owns the tree, input, layout, and frame build.
- Render submission is owned by the platform surface with bounded backpressure.
- Capture/recorder threads feed bounded queues; live data is coalesced to
  display refresh with explicit sample/loss markers (half-buffer trim keeps
  stop latency bounded when the feed fills).
- The recorder accumulates metrics while writing, so rotation never re-reads a
  segment while perf rings fill.
- Idle means no frames and no polling.

## Surfaces

- **Linux:** X11 + GLX viewer in `src/platform/linux`; OpenGL 3.3 renderer in
  `xsui-gl`, loaded via `dlopen`; Xvfb smokes; capture on Linux.
- **macOS viewer:** AppKit window + `xsui-metal` (`CAMetalLayer`) through the
  hand-written Objective-C runtime layer; NSAccessibility bridge; replay/follow
  only (no perf backend). See [macOS viewer](../platforms/macos-viewer.md).
- **Headless:** CPU rasterizer + `xsui.Tester` + PNG snapshots and
  deterministic accessibility-tree dumps on every host.

## Verification and evidence

- Fast contract/unit/fuzz gates plus schema conformance (`tests/schema.zig`)
  run in `./tools/zig build check`; CI adds platform/media lanes and strict
  tool requirements (`check-ci`); root-only recorder gates run in a disposable
  KVM VM (`check-vm`). See [maintaining](../maintaining.md).
- Evidence (VM logs, benchmark output, full captures) is attached to releases,
  never committed. Committed fixtures are small deterministic prefixes; the
  full macOS-VM capture is a release asset.

## Failure posture

Malformed/lost/refused/stale data is an explicit visible state. Capability
probes return READY/DEGRADED/SKIP/REFUSE with a reason. No path elevates,
writes `/proc` or `/sys`, auto-applies advice, opens a socket, or hides an
unsafe state.
