# Architecture overview

`xsprof` is split so the profiler core, the standalone UI package
([`lib/xsui`](../../lib/xsui/README.md)), and the native surfaces can be
tested independently. There is no browser/WASM/WebGL2 surface in 0.5.0.

```
perf_event_open / tracefs / /proc / /sys / BPF (VM only)
        |
   capture threads -> bounded SPSC rings -> correlator/aggregator -> EventStore
        |                                                        |
        |                                                        +-> compact segments + manifest
        |                                                        +-> canonical NDJSON export
        |                                                        +-> advisor
        v
   app state (replay/live) -> xsui (lib/xsui) tree -> layout -> paint -> DrawList
                                                               |
                                      +------------------------+------------------+
                                   CPU raster          Metal (macOS)        GL 3.3 (Linux)
```

## Layers

| Layer | Path | Rule |
|---|---|---|
| Core | `src/core/` | Zig std only; no OS/UI imports |
| Linux OS | `src/os/linux/` | read-only; non-Linux returns SKIP/REFUSE |
| Capture | `src/capture/` | collectors, rings, aggregation, loss markers |
| Analysis | `src/analyze/` | pure advisor over aggregates; suggestions only |
| Viz | `src/viz/` | pure Chrome Trace serialization |
| Stream | `src/stream/` | bounded event store, indexes, derived slices/flows |
| Recorder | `src/recorder/` | compact segments, manifest, retention, extraction, verify |
| UI | `lib/xsui/` | standalone native package; CPU/Metal/GL backends |
| App | `src/app/` | profiler screens and product shell over stream/analysis |
| Platform | `src/platform/` | macOS AppKit, Linux X11/GLX, native effect execution, headless smokes |
| GPU | `lib/xsui/src/gpu/` | one draw list; CPU/Metal/GL backends |
| CLI | `src/cli/`, `src/main.zig` | dispatch only; native UI default, automation verbs hidden |

## Data model

- `RawEvent` is a compact struct: 18 profiler kinds, ns timestamps, CPU/pid/tid,
  packed `a/b/c`, bounded `comm`, bounded/sanitized `detail`.
- `EventStore` is bounded. Overflow emits explicit loss markers; it never
  interpolates or silently drops.
- `Slice`/`Flow` are derived at ingest for the timeline:
  - switch duration = next switch on the same CPU;
  - wakeup flow pairs to the next matching switch; unmatched flows are shown
    explicitly;
  - migration/fault events become instant markers.
- Aggregates are the frozen 21-field advisor input; uncollected signals stay
  zero with collection flags/capabilities, so no false findings fire.
- Raw recorder storage is `xsprof/raw-segment/v1` compact blocks; extraction,
  incident, and UI output remain canonical `xsprof/event/v1` NDJSON.

## Threading

- UI thread owns the tree, input, layout, and frame build.
- Render submission is owned by the platform surface with bounded backpressure.
- Capture/recorder threads feed bounded queues; live data is coalesced to display
  refresh with explicit sampler/loss markers.
- Worker pools for glyph/parse/paint chunks are opt-in; parallel paint must
  equal serial paint (tested).
- Idle means no frames and no polling.

## Surfaces

- **Native macOS:** AppKit window surface + `xsui-metal` (`CAMetalLayer`);
  hand-written Objective-C runtime layer from `xsui-objc`; MSL embedded by the
  package; NSAccessibility bridge.
- **Native Linux:** X11 + GLX surface in `src/platform/linux`; OpenGL 3.3
  renderer in `xsui-gl`, loaded via `dlopen`; Xvfb tests; live capture on
  Linux.
- **Headless:** CPU rasterizer + Tester + PNG snapshots and deterministic
  accessibility-tree dumps on every host.

## Failure posture

Malformed/lost/refused/stale data is an explicit visible state. Capability
probes return READY/DEGRADED/SKIP/REFUSE with a reason. No path elevates,
writes `/proc` or `/sys`, auto-applies advice, or hides an unsafe state.
