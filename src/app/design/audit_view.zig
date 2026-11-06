//! Audit: read-only provenance. Session/manifest lifecycle, segments, loss,
//! history/retention coverage, capture-gate results, and the bounded UI action
//! log. No mutation controls.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const hits = @import("hits.zig");
const audit_mod = @import("audit.zig");
const recorder = @import("recorder.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Theme = xsui.Theme;
const Model = model_mod.Model;
const State = state_mod.State;
const text_10 = common.text_10;
const text_95 = common.text_95;
const text_105 = common.text_105;
const text_11 = common.text_11;
const text_12 = common.text_12;
const text_13 = common.text_13;
const style = common.style;
const label = common.label;
const labelRight = common.labelRight;
const labelWrapped = common.labelWrapped;
const borderLine = common.borderLine;
const panelHead = common.panelHead;

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const w = width - stage_x - pad * 2;

    var eyebrow = style(text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    try label(canvas, x, y, "PROVENANCE  ·  READ-ONLY  ·  HOST_MUTATION=FALSE", eyebrow);
    var h1 = style(text_13, th.text, .bold);
    h1.size = if (compact) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Audit", h1);
    try labelRight(canvas, x + w, y + 24.25, "verify, copy, or export the local action log", style(text_11, th.muted, .regular));
    try borderLine(canvas, x, y + 53.75, w, th.line);

    const left_w = (w - 12) * 0.54;
    const right_x = x + left_w + 12;
    const right_w = w - left_w - 12;
    var cy = y + 65.75;
    try drawProvenance(model, state, canvas, th, .{ .x = x, .y = cy, .w = left_w, .h = 250 });
    try drawLifecycle(model, canvas, th, .{ .x = x, .y = cy + 262, .w = left_w, .h = 250 });
    try drawRetention(model, canvas, th, .{ .x = x, .y = cy + 524, .w = left_w, .h = 150 });
    cy = y + 65.75;
    try drawActionLog(state, canvas, th, .{ .x = right_x, .y = cy, .w = right_w, .h = 438 });
    try drawGates(state, canvas, th, .{ .x = right_x, .y = cy + 450, .w = right_w, .h = 336 });
}

fn drawProvenance(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "01", "SESSION", model.meta.source);
    const rows = [_][2][]const u8{
        .{ "Source", if (model.meta.source.len > 0) model.meta.source else "EMPTY" },
        .{ "Host", if (model.meta.host.len > 0) model.meta.host else "not provided" },
        .{ "Kernel", if (model.meta.kernel.len > 0) model.meta.kernel else "not provided" },
        .{ "Fixture", if (model.meta.fixture.len > 0) model.meta.fixture else "not provided" },
        .{ "Window", if (model.meta.captureWindow.len > 0) model.meta.captureWindow else "excerpt" },
        .{ "Session", if (model.meta.sessionLabel.len > 0) model.meta.sessionLabel else "unlabelled" },
        .{ "host_mutation", "false" },
        .{ "Recorder", if (state.recorder.external) "attached (external)" else "not attached" },
    };
    var y = rect.y + 40;
    for (rows, 0..) |row, index| {
        if (index != 0) try borderLine(canvas, rect.x + 1, y, rect.w - 2, th.line);
        try label(canvas, rect.x + 14, y + 6, row[0], style(text_10, th.dim, .regular));
        try labelRight(canvas, rect.x + rect.w - 14, y + 6, row[1], style(text_10, th.text, .regular));
        y += 25;
    }
}

fn drawLifecycle(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "02", "LIFECYCLE MARKERS", "loss is explicit");
    var shown: usize = 0;
    var y = rect.y + 38;
    var i = model.events.len;
    while (i > 0 and shown < 8) {
        i -= 1;
        const event = model.events[i];
        const text = event.detail;
        const relevant = std.mem.indexOf(u8, text, "capture_start") != null or
            std.mem.indexOf(u8, text, "capture_stop") != null or
            std.mem.indexOf(u8, text, "capture_interrupted") != null or
            std.mem.indexOf(u8, text, "retention_loss") != null or
            std.mem.indexOf(u8, text, "sample_loss") != null;
        if (!relevant) continue;
        const color = if (std.mem.indexOf(u8, text, "loss") != null or std.mem.indexOf(u8, text, "interrupted") != null) th.refuse else th.pass;
        var tb: [32]u8 = undefined;
        try label(canvas, rect.x + 14, y, clock(&tb, event.ts), style(text_10, th.dim, .regular));
        try label(canvas, rect.x + 84, y, text, style(text_10, color, .regular));
        y += 24;
        shown += 1;
    }
    if (shown == 0) {
        try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 50, .w = rect.w - 28, .h = 40 }, style(text_11, th.dim, .regular), "No capture lifecycle markers in this source. A replay journal created without a recorder cannot show start/stop provenance.");
    }
}

fn drawRetention(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "03", "RETENTION", if (model.retention != null) "manifest" else "unavailable");
    const retention = model.retention;
    var buf: [128]u8 = undefined;
    const text = if (retention) |value|
        std.fmt.bufPrint(&buf, "{s} used · {s} covered · cap {s}", .{ value.used, value.age, value.excerpt }) catch "unavailable"
    else
        "No recorder retention metadata in this source; the raw window bounds are unknown.";
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 44, .w = rect.w - 28, .h = 48 }, style(text_11, th.dim, .regular), text);
}

fn drawActionLog(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    var meta_buf: [48]u8 = undefined;
    try panelHead(canvas, th, rect, "04", "UI ACTION LOG", std.fmt.bufPrint(&meta_buf, "{d}/{d}", .{ state.audit.len, audit_mod.max_entries }) catch "ring");
    const actions_y = rect.y + rect.h - 40;
    try button(canvas, th, .{ .x = rect.x + 14, .y = actions_y, .w = 74, .h = 28 }, "verify", hits.audit_verify, th.raised, th.line_strong, th.text);
    try button(canvas, th, .{ .x = rect.x + 96, .y = actions_y, .w = 62, .h = 28 }, "copy", hits.audit_copy, th.panel, th.line_strong, th.muted);
    try button(canvas, th, .{ .x = rect.x + 166, .y = actions_y, .w = 68, .h = 28 }, "export", hits.audit_export, th.panel, th.line_strong, th.muted);
    if (state.audit.len == 0) {
        try label(canvas, rect.x + 14, rect.y + 52, "No UI actions recorded yet.", style(text_11, th.dim, .regular));
        return;
    }
    var y = rect.y + 40;
    var index = state.audit.len;
    var shown: usize = 0;
    while (index > 0 and shown < 13) {
        index -= 1;
        const entry = state.audit.at(index) orelse break;
        if (shown > 0) try borderLine(canvas, rect.x + 1, y, rect.w - 2, th.line);
        var seq_buf: [16]u8 = undefined;
        try label(canvas, rect.x + 14, y + 6, std.fmt.bufPrint(&seq_buf, "#{d}", .{entry.seq}) catch "#", style(text_95, th.faint, .regular));
        try label(canvas, rect.x + 56, y + 6, entry.actionSlice(), style(text_10, th.text, .regular));
        try label(canvas, rect.x + 230, y + 6, entry.outcome.label(), style(text_95, outcomeColor(th, entry.outcome), .regular));
        if (entry.code_len > 0) try label(canvas, rect.x + 286, y + 6, entry.codeSlice(), style(text_10, th.dim, .regular));
        var t_buf: [24]u8 = undefined;
        try labelRight(canvas, rect.x + rect.w - 14, y + 6, std.fmt.bufPrint(&t_buf, "{d}ms", .{entry.wall_ms}) catch "", style(text_95, th.faint, .regular));
        y += 25;
        shown += 1;
    }
}

fn drawGates(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "05", "CAPABILITY GATES", "READY is scoped");
    if (state.capability_count == 0) {
        try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 48, .w = rect.w - 28, .h = 60 }, style(text_11, th.dim, .regular), "No capability probes recorded. Gates are never implied READY without a probe result and reason.");
        return;
    }
    var y = rect.y + 42;
    for (state.capabilitiesSlice()) |cap| {
        const color = switch (cap.state) {
            .ready => th.pass,
            .degraded, .busy, .skip => th.skip,
            .refuse => th.refuse,
        };
        try label(canvas, rect.x + 14, y, cap.nameSlice(), style(text_10, th.text, .regular));
        try label(canvas, rect.x + 120, y, cap.label(), style(text_95, color, .regular));
        if (cap.reason_len > 0) try label(canvas, rect.x + 190, y, cap.reasonSlice(), style(text_10, th.dim, .regular));
        y += 23;
    }
    try borderLine(canvas, rect.x + 1, rect.y + rect.h - 66, rect.w - 2, th.line);
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + rect.h - 58, .w = rect.w - 28, .h = 46 }, style(text_10, th.dim, .regular), "The console never elevates privileges, applies advisor suggestions, or writes scheduler policy. host_mutation=false is constant.");
}

fn clock(buf: *[32]u8, ts_ms: f64) []const u8 {
    const total_ms: u64 = @intFromFloat(@max(0, ts_ms));
    return std.fmt.bufPrint(buf, "{d}.{d:0>3}s", .{ total_ms / 1000, total_ms % 1000 }) catch "";
}

fn outcomeColor(th: Theme, outcome: audit_mod.Outcome) xsui.Color {
    return switch (outcome) {
        .ok => th.pass,
        .refused => th.refuse,
        .failed => th.refuse,
        .skipped => th.skip,
    };
}

fn button(canvas: *Canvas, th: Theme, rect: Rect, text_value: []const u8, id: u32, fill: xsui.Color, border: xsui.Color, text_color: xsui.Color) !void {
    _ = th;
    try canvas.rounded(rect, 4, fill, border, 1);
    try label(canvas, rect.x + 9, rect.y + 6.5, text_value, style(text_11, text_color, .regular));
    canvas.hit(id, rect);
}

test "audit view renders with and without an action ring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    var state = state_mod.State{ .screen = .audit };
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    try draw(&model, &state, &canvas, frame.theme, 92, 52, 1440);
    try std.testing.expect(canvas.hits.items.len > 0);
    state.audit.append(10, "nav.audit", .ok, "", "demo");
    frame.list.clear();
    canvas.resetHits();
    try draw(&model, &state, &canvas, frame.theme, 92, 52, 1440);
    try std.testing.expect(canvas.hits.items.len > 0);
}
