//! xsui — a compact, flat-instance GPU UI kernel.
//!
//! The library builds a per-frame node tree, lays it out, paints a single flat
//! instance list, and hands that list to one of the renderers:
//!
//! - CPU rasterizer (`raster`) for deterministic snapshots and parity tests;
//! - Metal (`xsui-metal`, macOS);
//! - OpenGL 3.3 (`xsui-gl`, Linux).
//!
//! The core module is target-neutral: it has no profiler, OS, or window
//! imports and compiles for native targets. Native renderer modules are
//! separate imports so the core never pulls in a framework.
//!
//! Extension points:
//! - `Ui.custom` with `CustomSpec.measure` / `CustomSpec.paint` for custom
//!   widgets that reuse the frame draw list;
//! - `themes.derive` / `themes.Overrides` for token-level branding;
//! - `FrameOptions.fonts` for host-supplied TrueType bytes;
//! - `gpu.Renderer` for third-party renderer backends;
//! - `Tester` for deterministic headless frames and scripted input.
//!
//! The library is read-only by construction: it does not touch `/proc`,
//! `/sys`, scheduler policy, or the network.

/// Package semantic version; kept in lockstep with `build.zig.zon`.
pub const version = "0.2.0";

/// Browser-matched mask bytes used by the baked glyph atlas; the profiler
/// hashes this against its formal UI spec.
pub const text_atlas = @import("fonts").chromium_text_atlas;

/// Draw list primitives, theme tokens, glyph atlas, and bundled fonts.
pub const draw = @import("draw.zig");
/// Layout tree, measurement, clipping, hit testing, and the `Ui` builder.
pub const layout = @import("layout.zig");
/// Reusable panels, chips, stat cards, rules, and key hints.
pub const widgets = @import("widgets.zig");
/// Interactive buttons, toggles, list rows, text fields, and toasts.
pub const controls = @import("controls.zig");
/// Pointer, wheel, key, and text input for one frame.
pub const input = @import("input.zig");
/// Offscreen frame, font set, atlas, draw list, CPU raster, and PNG output.
pub const frame = @import("frame.zig");
/// CPU reference rasterizer shared by snapshots and parity tests.
pub const raster = @import("raster.zig");
/// Deterministic PNG writer.
pub const png = @import("png.zig");
/// Minimal TrueType reader and glyph rasterizer.
pub const font = @import("ttf.zig");
/// Deterministic headless frame tester with scripted input.
pub const tester = @import("tester.zig");
/// Dark, light, and high-contrast presets plus token overrides.
pub const themes = @import("theme.zig");
/// Renderer extension contract and capability vocabulary.
pub const canvas = @import("canvas.zig");
/// Platform-neutral accessibility tree built from the canvas draw/hit pass.
pub const a11y = @import("a11y.zig");
pub const gpu = @import("gpu/renderer.zig");

/// Packed RGBA color with a default opaque alpha.
pub const Color = draw.Color;
/// Semantic theme token set; `themes.dark` is the default.
pub const Theme = draw.Theme;
/// Instance mode: flat rounded rect or glyph quad.
pub const Mode = draw.Mode;
/// One 72-byte instance shared by every backend.
pub const Instance = draw.Instance;
/// Atlas entry describing a rasterized glyph.
pub const GlyphEntry = draw.GlyphEntry;
/// 1024x1024 R8 glyph atlas.
pub const Atlas = draw.Atlas;
/// Flat per-frame instance list; the single input to every renderer.
pub const DrawList = draw.DrawList;

/// Axis-aligned rectangle in logical pixels.
pub const Rect = layout.Rect;
/// Per-side padding.
pub const Edges = layout.Edges;
/// Flex direction.
pub const Direction = layout.Direction;
/// Main/cross-axis alignment.
pub const Align = layout.Align;
/// Layout node style.
pub const Style = layout.Style;
/// Font weight selector for the two bundled faces.
pub const FontWeight = layout.FontWeight;
/// Text node specification.
pub const TextSpec = layout.TextSpec;
/// Custom painter/measure node specification.
pub const CustomSpec = layout.CustomSpec;
/// Measure callback for a custom node.
pub const MeasureFn = layout.MeasureFn;
/// Paint callback for a custom node.
pub const PaintFn = layout.PaintFn;
/// Measured size returned by a custom measure callback.
pub const Size = layout.Size;
/// Hit rectangle registered by a layout node.
pub const Hit = layout.Hit;
/// Open layout container; call `end()` when its children are complete.
pub const Container = layout.Container;
/// Immediate-feeling builder over a per-frame node tree.
pub const Ui = layout.Ui;

/// Platform-neutral pointer/wheel/key state for one frame.
pub const Input = input.Input;
/// Stable key codes, including the web ABI mapping.
pub const Key = input.Key;
/// Modifier bits for key events.
pub const Mods = input.Mods;
/// Bounded key or text event.
pub const KeyEvent = input.KeyEvent;

/// Offscreen frame owning fonts, atlas, draw list, and input.
pub const Frame = frame.Frame;
/// Host-supplied TrueType pair; defaults to the bundled fonts.
pub const FontSet = frame.FontSet;
/// Theme and font source for `Frame.initWithOptions`.
pub const FrameOptions = frame.FrameOptions;

/// Parsed TrueType font.
pub const Font = font.Font;
/// Rasterized glyph bitmap and metrics.
pub const Glyph = font.Glyph;

/// Headless tester: build, render, hash, snapshot, and script input.
pub const Canvas = canvas.Canvas;
/// Semantic role for an accessible hit node.
pub const Role = a11y.Role;
/// Static state flags for an accessible hit node.
pub const NodeFlags = a11y.Flags;
/// One accessible node derived from the canvas hit pass.
pub const A11yNode = a11y.Node;
/// Bounded accessibility tree: focus order, hit test, canonical JSON.
pub const A11yTree = a11y.Tree;
pub const TextStyle = canvas.TextStyle;
pub const TextLayout = canvas.TextLayout;
pub const TextAlign = canvas.HorizontalAlign;
pub const Tester = tester.Tester;
/// View callback signature accepted by `Tester`.
pub const ViewFn = tester.ViewFn;

test {
    _ = draw;
    _ = layout;
    _ = widgets;
    _ = controls;
    _ = input;
    _ = frame;
    _ = raster;
    _ = png;
    _ = font;
    _ = tester;
    _ = themes;
    _ = canvas;
    _ = a11y;
    _ = gpu;
}
