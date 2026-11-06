//! Settings: appearance, capture defaults, accessibility, storage/retention,
//! diagnostics and about. Persisted locally as xsprof/ui-settings/v1; the host
//! executor performs the write. Session-only when a surface cannot persist.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const hits = @import("hits.zig");
const settings = @import("settings.zig");

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
    _ = model;
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const w = width - stage_x - pad * 2;

    var eyebrow = style(text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    try label(canvas, x, y, "PERSISTED LOCALLY  ·  NO TELEMETRY  ·  READ-ONLY", eyebrow);
    var h1 = style(text_13, th.text, .bold);
    h1.size = if (compact) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Settings", h1);
    try labelRight(canvas, x + w, y + 24.25, "schema xsprof/ui-settings/v1", style(text_11, th.muted, .regular));
    try borderLine(canvas, x, y + 53.75, w, th.line);

    const left_w = (w - 12) * 0.5;
    const right_x = x + left_w + 12;
    const right_w = w - left_w - 12;
    var cy = y + 65.75;
    try drawAppearance(state, canvas, th, .{ .x = x, .y = cy, .w = left_w, .h = 214 });
    try drawAccessibility(state, canvas, th, .{ .x = x, .y = cy + 226, .w = left_w, .h = 182 });
    try drawStorage(state, canvas, th, .{ .x = x, .y = cy + 420, .w = left_w, .h = 214 });
    cy = y + 65.75;
    try drawCapture(state, canvas, th, .{ .x = right_x, .y = cy, .w = right_w, .h = 246 });
    try drawDiagnostics(state, canvas, th, .{ .x = right_x, .y = cy + 258, .w = right_w, .h = 236 });
    try drawAbout(state, canvas, th, .{ .x = right_x, .y = cy + 506, .w = right_w, .h = 128 });
}

fn drawAppearance(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "01", "APPEARANCE", "applies immediately");
    const y = rect.y + 42;
    for (xsui.themes.presets, 0..) |preset, index| {
        if (index >= 6) break;
        const active = state.theme_index == index;
        const cw = (rect.w - 28 - 8) / 2;
        const col = index % 2;
        const row = index / 2;
        const card = Rect{
            .x = rect.x + 14 + @as(f32, @floatFromInt(col)) * (cw + 8),
            .y = y + @as(f32, @floatFromInt(row)) * 38,
            .w = cw,
            .h = 32,
        };
        try canvas.rounded(card, 4, if (active) th.raised else th.field, if (active) th.live else th.line, 1);
        try label(canvas, card.x + 8, card.y + 8, preset.name, style(text_10, if (active) th.text else th.muted, .regular));
        if (active) try labelRight(canvas, card.x + card.w - 8, card.y + 8, "✓", style(text_10, th.live, .regular));
        canvas.hit(hits.settings_theme_base + @as(u32, @intCast(index)), card);
    }
    try toggleRow(state, canvas, th, .{ .x = rect.x + 14, .y = y + 120, .w = rect.w - 28, .h = 32 }, "Reduced motion", "snaps animations and transitions", state.settings.reduced_motion, hits.settings_reduced_motion);
    try label(canvas, rect.x + 14, y + 162, "Six palettes share the same 33 semantic tokens; state is never carried by colour alone.", style(text_10, th.faint, .regular));
}

fn drawAccessibility(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "02", "ACCESSIBILITY", "tree is platform-neutral");
    try toggleRow(state, canvas, th, .{ .x = rect.x + 14, .y = rect.y + 44, .w = rect.w - 28, .h = 30 }, "Announce state changes", "status/loss/refusal live regions", state.settings.a11y_announce, hits.settings_a11y_announce);
    try toggleRow(state, canvas, th, .{ .x = rect.x + 14, .y = rect.y + 80, .w = rect.w - 28, .h = 30 }, "Expose accessibility tree", "nodes built from canvas hit ids", state.settings.a11y_tree, hits.settings_a11y_tree);
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 120, .w = rect.w - 28, .h = 50 }, style(text_10, th.dim, .regular), "Native macOS exposes an NSAccessibility tree; the platform-neutral tree also serializes to canonical JSON for tests and tooling. Linux AT-SPI is a DEGRADED/SKIP bridge with an explicit reason, never silently missing.");
}

fn drawCapture(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "03", "CAPTURE DEFAULTS", "read-only recorder");
    try toggleRow(state, canvas, th, .{ .x = rect.x + 14, .y = rect.y + 44, .w = rect.w - 28, .h = 30 }, "Enable capture controls", "start/stop the in-process read-only capture", state.settings.capture_enabled, hits.settings_capture_enabled);
    try label(canvas, rect.x + 14, rect.y + 88, "STATE DIR", style(text_95, th.faint, .regular));
    const field = Rect{ .x = rect.x + 14, .y = rect.y + 104, .w = rect.w - 28, .h = 30 };
    try canvas.rounded(field, 4, th.field, if (state.text_focus == .recorder_dir) th.live else th.line, 1);
    const dir = state.settings.recorderDirSlice();
    try label(canvas, field.x + 9, field.y + 8, if (dir.len > 0) dir else "default state directory (not set)", style(text_11, if (dir.len > 0) th.text else th.faint, .regular));
    canvas.hit(hits.settings_recorder_dir, field);
    var buf: [128]u8 = undefined;
    const preset_text = std.fmt.bufPrint(&buf, "preset {s} · max {d} MiB · age cap {d} min", .{
        if (state.settings.recorder_preset == 1) "memory" else if (state.settings.recorder_preset == 2) "deep" else "scheduler",
        state.settings.max_bytes / (1024 * 1024),
        state.settings.max_age_ms / 60_000,
    }) catch "";
    try label(canvas, rect.x + 14, rect.y + 148, preset_text, style(text_10, th.dim, .regular));
    try label(canvas, rect.x + 14, rect.y + 168, "Recorder window, segments and retention are in the Audit screen.", style(text_10, th.faint, .regular));
}

fn drawStorage(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "04", "STORAGE & RETENTION", "bounded");
    const rows = [_][2][]const u8{
        .{ "Raw byte budget", if (state.settings.max_bytes >= 1024 * 1024 * 1024) "2.0 GiB" else "bounded" },
        .{ "Raw age cap", "10 m" },
        .{ "History interval", "60 s" },
        .{ "History retain", "24 h" },
        .{ "Raw ten-minute tier", "not claimed: byte budget binds first" },
    };
    var y = rect.y + 42;
    for (rows) |row| {
        try label(canvas, rect.x + 14, y, row[0], style(text_10, th.dim, .regular));
        try labelRight(canvas, rect.x + rect.w - 14, y, row[1], style(text_10, th.text, .regular));
        y += 24;
    }
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 166, .w = rect.w - 28, .h = 34 }, style(text_10, th.faint, .regular), "Extraction never zero-fills a window older than retention; it reports retention_loss explicitly.");
}

fn drawDiagnostics(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    var meta_buf: [48]u8 = undefined;
    try panelHead(canvas, th, rect, "05", "DIAGNOSTICS", std.fmt.bufPrint(&meta_buf, "{d} probes", .{state.capability_count}) catch "");
    if (state.capability_count == 0) {
        try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 48, .w = rect.w - 28, .h = 44 }, style(text_11, th.dim, .regular), "No probes recorded on this surface. The host executor reports READY/DEGRADED/SKIP/REFUSE with an exact reason.");
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
        try label(canvas, rect.x + 118, y, cap.label(), style(text_95, color, .regular));
        if (cap.reason_len > 0) try label(canvas, rect.x + 186, y, cap.reasonSlice(), style(text_10, th.dim, .regular));
        y += 22;
    }
}

fn drawAbout(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "06", "ABOUT & SAFETY", "read-only");
    try label(canvas, rect.x + 14, rect.y + 44, "xsprof — read-only scheduler & memory profiler", style(text_11, th.text, .regular));
    try label(canvas, rect.x + 14, rect.y + 62, "host_mutation=false · no telemetry · no network", style(text_10, th.dim, .regular));
    try label(canvas, rect.x + 14, rect.y + 80, "Onboarding version", style(text_10, th.dim, .regular));
    var buf: [24]u8 = undefined;
    try labelRight(canvas, rect.x + rect.w - 14, rect.y + 80, std.fmt.bufPrint(&buf, "{d}", .{state.onboarding.completed_version}) catch "0", style(text_10, th.text, .regular));
    const reset = Rect{ .x = rect.x + rect.w - 116, .y = rect.y + rect.h - 38, .w = 102, .h = 26 };
    try canvas.rounded(reset, 4, th.panel, th.refuse_chip_border, 1);
    try label(canvas, reset.x + 12, reset.y + 5.5, "reset settings", style(text_10, th.refuse, .regular));
    canvas.hit(hits.settings_reset, reset);
}

fn toggleRow(state: *const State, canvas: *Canvas, th: Theme, rect: Rect, title: []const u8, detail: []const u8, value: bool, id: u32) !void {
    try label(canvas, rect.x, rect.y + 3, title, style(text_11, th.text, .regular));
    try label(canvas, rect.x, rect.y + 17, detail, style(text_10, th.dim, .regular));
    const track = Rect{ .x = rect.x + rect.w - 40, .y = rect.y + 6, .w = 40, .h = 18 };
    try canvas.rounded(track, 9, if (value) th.tint_live else th.field, if (value) th.live else th.line, 1);
    const knob = Rect{ .x = if (value) track.x + track.w - 16 else track.x + 1, .y = track.y + 1, .w = 16, .h = 16 };
    try canvas.rounded(knob, 8, if (value) th.live else th.dim, null, 0);
    canvas.hit(id, rect);
    _ = state;
}

test "settings view renders both panels and registers controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    var state = state_mod.State{ .screen = .settings };
    state.setCapability("perf", .ready, "");
    state.setCapability("tracefs", .refuse, "tracefs unreadable");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    try draw(&model, &state, &canvas, frame.theme, 92, 52, 1440);
    try std.testing.expect(canvas.hits.items.len > 0);
    var found_reset = false;
    for (canvas.hits.items) |hit| {
        if (hit.id == hits.settings_reset) found_reset = true;
    }
    try std.testing.expect(found_reset);
}
