//! Timeline brush/pointer conversion kept out of App so the state machine
//! file stays within the repository line limit. Surfaces call these with the
//! current App and Canvas.

const std = @import("std");
const xsui = @import("xsui");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const PlotMetrics = struct {
    x0: f32,
    x1: f32,
    y0: f32,
    y1: f32,
    start: f64,
    span: f64,
};

pub fn plotMetrics(app: *const App) ?PlotMetrics {
    if (app.viewport_w < 320) return null;
    const vw: f32 = @floatFromInt(app.viewport_w);
    const stage_x: f32 = if (vw <= 1024) 0 else 92;
    const pad: f32 = if (vw <= 780) 14 else 24;
    const content_w = vw - stage_x - pad * 2;
    const head_y = 52 + (if (vw <= 780) @as(f32, 14) else 16);
    const plot_y = head_y + 53.75 + 12;
    const plot_w = if (vw <= 1140) content_w else content_w - 286 - 12;
    const x = stage_x + pad;
    const start = app.state.viewStart(app.model.summary.windowMs);
    const span = @max(1.0, app.state.viewEnd(app.model.summary.windowMs) - start);
    return .{ .x0 = x + 78, .x1 = x + plot_w - 12, .y0 = plot_y, .y1 = plot_y + 338, .start = start, .span = span };
}

pub fn pointerDown(app: *App, x: f32, y: f32) void {
    if (app.state.screen != .timeline) return;
    const m = plotMetrics(app) orelse return;
    if (x < m.x0 or x > m.x1 or y < m.y0 + 28 or y > m.y1) return;
    app.state.brush_dragging = true;
    app.state.brush_start_x = x;
    app.state.brush_start_ms = m.start + @as(f64, @floatCast((x - m.x0) / (m.x1 - m.x0))) * m.span;
    app.state.brush_from = null;
    app.state.brush_to = null;
}

pub fn pointerMove(app: *App, x: f32, y: f32) void {
    _ = y;
    if (!app.state.brush_dragging) return;
    const m = plotMetrics(app) orelse return;
    if (@abs(x - app.state.brush_start_x) <= 4) return;
    const clamped = std.math.clamp(x, m.x0, m.x1);
    const ms = m.start + @as(f64, @floatCast((clamped - m.x0) / (m.x1 - m.x0))) * m.span;
    app.state.brush_from = @min(app.state.brush_start_ms, ms);
    app.state.brush_to = @max(app.state.brush_start_ms, ms);
}

pub fn pointerUp(app: *App, canvas: *xsui.Canvas, x: f32, y: f32) void {
    const was_dragging = app.state.brush_dragging;
    app.state.brush_dragging = false;
    if (was_dragging and app.state.brush_from != null and app.state.brush_to != null and app.state.brush_to.? - app.state.brush_from.? > 20) {
        zoomRange(app, app.state.brush_from.?, app.state.brush_to.?);
    } else {
        // A click is a pointer-down/up with no brush movement. This also lets
        // non-timeline controls work through the same pointer API.
        app.click(canvas, x, y);
    }
    app.state.brush_from = null;
    app.state.brush_to = null;
}

fn zoomRange(app: *App, from: f64, to: f64) void {
    const window = app.model.summary.windowMs;
    var a = std.math.clamp(from, 0, window);
    var b = std.math.clamp(to, 0, window);
    if (b - a < 300) {
        const mid = (a + b) * 0.5;
        a = std.math.clamp(mid - 150, 0, @max(0, window - 300));
        b = @min(window, a + 300);
    }
    app.state.timeline_start = a;
    app.state.timeline_end = b;
    app.showToast("zoomed to brush", false);
}

test "timeline brush zooms to the dragged range" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    app.viewport_w = 1440;
    app.viewport_h = 900;
    app.state.screen = .timeline;
    const view_mod = @import("view.zig");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    try view_mod.view(&app.model, &app.state, &canvas);
    pointerDown(&app, 400, 200);
    pointerMove(&app, 700, 200);
    try std.testing.expect(app.state.brush_from != null);
    pointerUp(&app, &canvas, 700, 200);
    try std.testing.expect(app.state.timeline_end > app.state.timeline_start);
    try std.testing.expect(app.state.timeline_end - app.state.timeline_start < app.model.summary.windowMs);
}
