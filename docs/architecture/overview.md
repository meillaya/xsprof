# Architecture overview

`xsprof` is split so the profiler core, the standalone UI package
([`lib/xsui`](../../lib/xsui/README.md)), and the native/web surfaces can be
tested independently.

```
perf_event_open / tracefs / /proc / /sys / BPF (VM only)
        |
   capture threads -> bounded SPSC rings -> correlator/aggregator -> EventStore
        |                                                        |
        |                                                        +-> journal NDJSON
        |                                                        +-> advisor
        |                                                        +-> SSE stream
        v
   app state (replay/live) -> xsui (lib/xsui) tree -> layout -> paint -> DrawList
                                                               |
                                      +------------------------+------------------+
                                   CPU raster              WebGL2 (JS)        Metal (macOS)
                                                                              GL 3.3 (Linux)
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
| Serve | `src/serve/` | loopback GET/HEAD, static assets, SSE; no mutation |
| UI | `lib/xsui/` | standalone package; target-neutral core for native + wasm |
| App | `src/app/` | profiler screens over stream/analysis |
| Platform | `src/platform/` | macOS AppKit window, Linux X11/GLX surface, web ABI, headless |
| GPU | `lib/xsui/src/gpu/` | one draw list; CPU/Metal/GL/WebGL2 backends |
| CLI | `src/cli/`, `src/main.zig` | dispatch only |

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

## Threading

- UI thread owns the tree, input, layout, and frame build.
- Render thread owns GPU submission with 2–3 frames in flight and bounded
  backpressure.
- Capture/parse threads feed bounded queues; live data is coalesced to display
  refresh.
- Worker pool for glyph/parse/paint chunks is opt-in; parallel paint must equal
  serial paint (tested).
- Idle means no frames and no polling.

## Surfaces

- **Web first:** `wasm32-freestanding` + WebGL2; tiny JS shim consumes the
  `xsui` instance/atlas ABI; loopback SSE.
- **Native macOS:** AppKit window surface + `xsui-metal` (`CAMetalLayer`);
  hand-written Objective-C runtime layer from `xsui-objc`; MSL embedded by the
  package.
- **Native Linux:** X11 + GLX surface in `src/platform/linux`; OpenGL 3.3
  renderer in `xsui-gl`, loaded via `dlopen`; Xvfb tests; web is the Wayland
  path.
- **Headless:** CPU rasterizer + Tester + PNG snapshots on every host.

## Failure posture

Malformed/lost/refused/stale data is an explicit visible state. Capability
probes return READY/DEGRADED/SKIP/REFUSE with a reason. No path elevates,
writes `/proc` or `/sys`, auto-applies advice, or hides an unsafe state.
