# xsui

`xsui` is a compact, flat-instance GPU UI kernel in Zig 0.17. It builds a
per-frame layout tree, paints one instanced draw list, and renders it through a
CPU rasterizer, Metal, OpenGL 3.3, or WebGL2. It is the UI library used by
[`xsprof`](../..), but it has no profiler, capture, or host-policy imports and
can be used on its own.

Design constraints:

- one flat instance stream for every backend;
- deterministic CPU snapshots and framebuffer hashes;
- read-only: no `/proc`, `/sys`, privilege, telemetry, or network access;
- no C shims, no system font/shaping libraries, no third-party runtime
  dependencies;
- monospace-first typography with the bundled OFL JetBrains Mono.

## Package layout

```text
build.zig                 package build
build.zig.zon             package manifest (path dependency friendly)
src/xsui.zig              public root
src/draw.zig              Color, Theme, Instance, Atlas, DrawList
src/layout.zig            Layout tree, Ui, hit testing
src/widgets.zig           panels, chips, stat cards, rules
src/controls.zig          buttons, toggles, list rows, text fields, toasts
src/input.zig             pointer/wheel/key events
src/frame.zig             Frame, FontSet, FrameOptions
src/raster.zig            CPU reference renderer (RGBA8)
src/png.zig               deterministic PNG writer
src/ttf.zig               minimal TrueType reader/rasterizer
src/tester.zig            headless Tester
src/theme.zig             dark/light/high-contrast presets, derive()
src/gpu/renderer.zig      renderer contract, capability states
src/gpu/webgl.zig         WebGL2 instance/attribute/atlas ABI
src/gpu/metal.zig         Metal backend (module xsui-metal)
src/gpu/gl.zig            OpenGL 3.3 backend (module xsui-gl)
src/native/objc.zig       Objective-C runtime helpers (module xsui-objc)
src/gpu/shaders/          Metal, GLSL 330, and WebGL2 shader sources
assets/fonts/             JetBrains Mono Regular/Bold + OFL license
examples/snapshot.zig     public-API-only PNG example
```

## Use as a path dependency

```zig
// build.zig.zon
.dependencies = .{
    .xsui = .{ .path = "lib/xsui" },
},
```

```zig
// build.zig
const xsui_dep = b.dependency("xsui", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "xsui", .module = xsui_dep.module("xsui") }},
});
```

Native surfaces opt into a backend module separately:

```zig
// macOS
const metal = xsui_dep.module("xsui-metal");
const objc = xsui_dep.module("xsui-objc");
// Linux
const gl = xsui_dep.module("xsui-gl");
```

The core `xsui` module is target-neutral and works for wasm32-freestanding.
Backends are never imported by the core, so a wasm build stays free of
frameworks and OS calls.

## Quickstart: offscreen PNG

```zig
const std = @import("std");
const xsui = @import("xsui");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var frame: xsui.Frame = undefined;
    try frame.init(arena, 640, 360, xsui.themes.dark);
    defer frame.deinit();

    var ui = xsui.Ui.init(&frame);
    defer ui.deinit();
    var root = try ui.column(.{ .padding = xsui.Edges.all(12), .bg = ui.theme.panel });
    try ui.text(.{ .text = "hello", .size = 16, .color = ui.theme.live, .weight = .bold });
    root.end();
    try ui.finish();

    try frame.savePng(init.io, "hello.png");
}
```

`Frame.render()` returns RGBA8 bytes allocated with `frame.allocator`.
`Frame.savePng(io, path)` writes the same deterministic rasterizer output.

## Quickstart: native draw list

A surface owns the window/context; `xsui` owns the frame and draw list:

```zig
var frame: xsui.Frame = undefined;
try frame.init(allocator, width, height, xsui.themes.dark);
defer frame.deinit();

var ui = xsui.Ui.init(&frame);
defer ui.deinit();
try view(&ui);              // your screen
try ui.finish();            // layout + paint into frame.list

// Metal: attach renderer.layer to the NSView first.
const ok = renderer.present(frame.list.items.items, &frame.atlas, width, height, frame.theme.bg);
// GL: make the context current, then
renderer.paint(frame.list.items.items, &frame.atlas, width, height, frame.theme.bg);
```

For a backend-agnostic host, use the renderer interface:

```zig
const gpu = renderer.interface();
_ = try gpu.drawFrame(&frame.list, .{ .width = width, .height = height }, frame.theme.bg);
```

## Public API map

| Root | Contents |
|---|---|
| `xsui.Color`, `Theme`, `Mode`, `Instance`, `Atlas`, `DrawList` | draw-list core |
| `xsui.Rect`, `Edges`, `Style`, `Ui`, `CustomSpec`, `Hit` | layout and painting |
| `xsui.widgets`, `xsui.controls` | widget vocabulary |
| `xsui.Input`, `Key`, `KeyEvent`, `Mods` | frame input |
| `xsui.Frame`, `FontSet`, `FrameOptions` | offscreen frame + injectable fonts |
| `xsui.raster`, `xsui.png`, `xsui.font` | CPU reference, PNG, TrueType |
| `xsui.Tester`, `ViewFn` | deterministic headless frames and scripted input |
| `xsui.themes` | `dark`, `light`, `high_contrast`, `named`, `derive` |
| `xsui.gpu` | `Backend`, `Status`, `Capability`, `Target`, `Renderer` |
| `xsui.webgl` | instance stride/attributes/atlas/served shader paths |

The public root and the new extension surfaces carry doc comments in-source;

## Extension points

### Custom painter / widget

`Ui.custom` reserves a layout node and calls your measure/paint callbacks with
the frame's draw list, the exact rect, and the current clip:

```zig
try ui.custom(.{
    .style = .{ .flex = 1 },
    .user = state,
    .measure = myMeasure,       // optional
    .paint = myPaint,           // fn(user, frame, rect, clip) !void
});
```

Custom painters may use `frame.list.rect`, `roundedRect`, and `text`; they
participate in layout and clipping but never in profiler state.

### Themes

```zig
const theme = xsui.themes.derive(xsui.themes.light, .{
    .live = .{ .r = 0x00, .g = 0xc8, .b = 0xff },
});
```

`xsui.themes.named("light" | "high-contrast" | "dark")` resolves CLI names;
unknown names return `null` so the caller can keep its default.

### Custom fonts

```zig
var frame: xsui.Frame = undefined;
try frame.initWithOptions(allocator, width, height, .{
    .theme = xsui.themes.dark,
    .fonts = .{ .regular = regular_ttf_bytes, .bold = bold_ttf_bytes },
});
```

The byte slices must outlive the frame. Invalid files return `error.BadFont`.
The bundled TrueType reader supports simple glyphs, cmap 4/12, and ASCII/Latin-1.

### Renderer backends

`xsui.gpu.Renderer` is a context + vtable:

```zig
pub const Renderer = struct {
    context: *anyopaque,
    vtable: *const VTable,
    // backend, deinit, resize, draw, optional readback
};
```

`draw` receives the draw list (which owns its atlas pointer), target size, and
clear color; it returns `false` when a window drawable is not available yet.
`readback` is optional; Metal implements it, and `raster` is the CPU
reference used for parity. Capability probing returns READY/DEGRADED/SKIP/
REFUSE plus a reason; a missing device is SKIP, never a fabricated success.

`xsui-metal` and `xsui-gl` expose `capability()` and `interface()` in addition
to their concrete renderer types.

### Headless tests

```zig
var tester = xsui.Tester.init(allocator, 320, 180, xsui.themes.dark);
tester.click(24, 40);
_ = tester.text("a");
const hash = try tester.renderHash(null, myView);
const pixels = try tester.renderPixels(null, myView); // caller frees
```

Scripted input is copied into each frame; transient click/wheel/key events are
consumed after the render while the pointer position persists. PNG snapshots
use `tester.snapshot(io, path, user, view)`.

## Draw and atlas ABI

`xsui.Instance` is an `extern struct` of 72 bytes (18 little-endian f32 lanes):

| Offset | Field | Type |
|---|---|---|
| 0 | `rect` | `[4]f32` x, y, w, h |
| 16 | `clip` | `[4]f32` x0, y0, x1, y1 |
| 32 | `uv` | `[4]f32` u0, v0, u1, v1 |
| 48 | `color` | packed RGBA `u32` |
| 52 | `border_color` | packed RGBA `u32` |
| 56 | `radius` | `f32` |
| 60 | `border_width` | `f32` |
| 64 | `mode` | `0` rect, `1` glyph |
| 68 | `pad` | padding |

The WebGL2 attributes are locations 0–7 with offsets 0/16/32/48/52/56/60/64;
`xsui.webgl` pins these values with comptime assertions. The glyph atlas is
1024×1024 R8 (`r8unorm`); the WebGL2 shim uploads it on version changes.

Metal pads each row to 80 bytes for MSL's 16-byte alignment; the shared struct
stays 72 bytes. Shader sources live under `src/gpu/shaders/` and are embedded
by the native backends; the web build installs the WebGL2 pair at
`shaders/ui.vert.glsl` and `shaders/ui.frag.glsl`.

## Build and test

```sh
../../tools/zig build test       # core + native backend tests
../../tools/zig build example    # render zig-out/xsui-example.png
```

From `xsprof`'s root, `./tools/zig build xsui-package` runs the standalone
package gate (import isolation, version consistency, tests, example PNG).

## Platform notes

- macOS: `xsui-objc` and `xsui-metal` are macOS-only modules. Metal can render
  offscreen for parity tests without a window.
- Linux: `xsui-gl` loads `libGL.so.1` through `std.DynLib`; the host owns the
  X11/GLX context. A static-musl binary can use the CPU path but not GL.
- wasm32-freestanding: only the core module is used. JS owns WebGL2 and consumes
  the exported instance pointer/stride and atlas pointer/version.
- No backend opens a window. Windows, contexts, and event loops belong to the
  host.

## Versioning

The package follows semantic versioning independently of the `xsprof` binary.
Before 1.0, breaking API changes bump the minor version; additions bump the
patch version. Keep `build.zig.zon` and `xsui.version` in lockstep
(`qa/xsui_package.sh` checks this in the `xsprof` tree).

## License and attribution

The UI library is part of the `xsprof` tree; see the repository
`THIRD_PARTY_NOTICES.md`. JetBrains Mono is bundled under the SIL Open Font
License 1.1 (`assets/fonts/OFL.txt`). The Objective-C runtime helper is adapted
from nanoui (MIT); see `THIRD_PARTY_NOTICES.md`.
