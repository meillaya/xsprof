# Native macOS

`xsprof ui` (or bare `xsprof` in the app bundle) opens one AppKit window
hosting a `CAMetalLayer`. The renderer is the same flat instance draw list the
CPU and GL backends use: four vertices per rounded rect or glyph quad,
one instanced draw per frame. First run starts with the four-step onboarding
overlay; later runs start at Home.

## Bindings and renderer

- `lib/xsui/src/native/objc.zig` (module `xsui-objc`) — direct Objective-C
  runtime calls. `msg` builds the exact `objc_msgSend` prototype at comptime;
  runtime classes carry one Zig pointer ivar. No C shim, `.m`, or `@cImport`.
- `lib/xsui/src/gpu/metal.zig` (module `xsui-metal`) — device/queue/library/
  pipeline, R8 atlas upload on version change, BGRA8Unorm drawable,
  straight-alpha blending, capability probing, the `gpu.Renderer` adapter, and
  an offscreen shared-texture readback path.
- `src/platform/macos/window.zig` — resizable `NSWindow` + `NSView` surface,
  window/layer resize delegates, min-size clamp, mouse move/drag/up tracking,
  wheel/brush input, dirty 30 Hz tick, keyboard routes, theme, quit, and
  close-to-quit.
- `src/platform/macos/a11y.zig` — `NSAccessibility` bridge. The dynamically
  defined `XsprofAXNode` subclasses `NSAccessibilityElement`; children, roles,
  labels, values, frames, focus, hit testing, and press actions come from the
  same bounded tree as the snapshot surface. Notifications are throttled.
- `src/platform/session.zig`, `effect_exec.zig`, `state_paths.zig`,
  `export_writer.zig` — shared native bootstrap: settings, onboarding, GPU
  picker listings, source loads, exports, audit, and atomic settings writes.
- `lib/xsui/src/gpu/shaders/metal/ui.metal` — the vertex/fragment shader
  for the native Metal backend.

Metal aligns the instance struct to 16 bytes (80 bytes); the shared Zig struct
is 72. The renderer pads each row before upload, so both backends consume the
same `draw.Instance` without changing the WebGL layout.

## Live data

macOS has no perf/tracepoint capture backend. `ui --live` is SKIP with a
reason. `ui --follow-recorder DIR` tails a recorder state directory exported
from Linux (legacy NDJSON or compact `.xsraw`) through the same bounded live
controller, re-serializes canonical NDJSON, and shows the live view without
pretending to capture. Capture controls are disabled with the exact reason.

## Evidence

`zig build xsui-package` includes a headless Metal parity test (no window).
`qa/macos_smoke.sh` creates a hidden window, layer, view, delegate, and
accessibility bridge without ordering the window front; it also asserts the
`XSPROF_NO_UI=1` quickstart guard and an optional synthetic resize. It is
wired into `zig build check` on macOS. Agents never open or activate a visible
window; the final visual/VoiceOver check is human-only.

## Commands

```sh
./zig-out/bin/xsprof                         # console (app bundle/bare TTY)
./zig-out/bin/xsprof ui --replay fixtures/ui/healthy.ndjson --view timeline
./zig-out/bin/xsprof ui --follow-recorder /path/to/state --view home
./zig-out/bin/xsprof ui --smoke --resize 900x600
./zig-out/bin/xsprof snapshot --view home --a11y /tmp/tree.json --out /tmp/home.png
```

## Limits

- Windows resize and draw at 1x for now; Retina 2x crispness is a follow-up.
- macOS live capture is SKIP by design; replay and recorder follow are native.
- The accessibility bridge is implemented and smoke-checked; a human VoiceOver
  audit is still required before claiming spoken navigation quality.
