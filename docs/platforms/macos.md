# Native macOS

`xsprof ui` opens one AppKit window hosting a `CAMetalLayer`. The renderer is
the same flat instance draw list the CPU and WebGL backends use: four vertices
per rounded rect or glyph quad, one instanced draw per frame.

## Bindings and renderer

- `lib/xsui/src/native/objc.zig` (module `xsui-objc`) — direct Objective-C
  runtime calls. `msg` builds the exact `objc_msgSend` prototype at comptime;
  runtime classes carry one Zig pointer ivar. No C shim, `.m`, or `@cImport`.
  The msg-send pattern is adapted from nanoui (MIT); see
  `THIRD_PARTY_NOTICES.md`.
- `lib/xsui/src/gpu/metal.zig` (module `xsui-metal`) — device/queue/library/
  pipeline, R8 atlas upload on version change, BGRA8Unorm drawable,
  straight-alpha blending, capability probing, the `gpu.Renderer` adapter, and
  an offscreen shared-texture readback path.
- `src/platform/macos/window.zig` — `NSWindow` + `NSView` surface that attaches
  the renderer layer, a coalesced 30 Hz tick that only draws while dirty,
  keyboard screens (`1`–`5`), theme (`t`), quit (`q`), and close-to-quit.
- `lib/xsui/src/gpu/shaders/metal/ui.metal` — the vertex/fragment shader
  mirrored from the WebGL2 pair.

Metal aligns the instance struct to 16 bytes (80 bytes); the shared Zig struct
is 72. The renderer pads each row before upload, so both backends consume the
same `draw.Instance` without changing the WebGL layout.

## Evidence

`zig build xsui-package` (and the package's own `zig build test`) includes a
headless Metal parity test (no window):

```text
metal parity avg=0.15 mismatches=187/57600
```

It renders a package-owned sample view offscreen through the `gpu.Renderer`
readback path and compares BGRA against the CPU reference with tolerance for
AA/blending.

`qa/macos_smoke.sh` creates a hidden `NSWindow`, `CAMetalLayer`, view and
delegate without ordering the window front, then exits:

```text
native smoke: hidden NSWindow/CAMetalLayer created; no frame shown
macos_smoke: PASS
```

`zig build check` runs that hidden smoke on macOS. Agents never open or
activate the visible window; that final visual check is human-only.

## Commands

```sh
./zig-out/bin/xsprof ui
./zig-out/bin/xsprof ui --replay fixtures/ui/healthy.ndjson --view timeline
./zig-out/bin/xsprof ui --theme light
./zig-out/bin/xsprof ui --smoke       # hidden, no window shown
```

## Limits

- The window is fixed at 1280×720 and drawn at 1× for now; Retina 2× text and
  resize handling are a polish item.
- Pointer clicks and wheel scrolling are wired to the shared timeline and
  event-list input. No menu bar or accessibility tree yet.
- Native live streaming is web-only; `ui --replay` and the gallery are native.
