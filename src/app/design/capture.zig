//! Capture screen: read-only recorder status, retention, segments, exact
//! commands, and the fail-closed safety contract.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const format = @import("format.zig");
const hits = @import("hits.zig");
const recorder = @import("recorder.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Color = xsui.Color;
const Theme = xsui.Theme;
const Model = model_mod.Model;
const State = state_mod.State;
const style = common.style;
const measure = common.measure;
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
    var eyebrow = style(common.text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    try label(canvas, x, y, "RECORDER  ·  READ-ONLY CAPTURE  ·  NO HOST MUTATION", eyebrow);
    var h1 = style(common.text_13, th.text, .bold);
    h1.size = if (width <= 780) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Capture", h1);
    const note = if (state.recorder.external) "attached recorder · read-only extraction" else "in-process read-only capture · disable/enable in Settings";
    try labelRight(canvas, x + w, y + 24.25, note, style(common.text_11, th.muted, .regular));
    try borderLine(canvas, x, y + 53.75, w, th.line);
    try drawControls(state, canvas, th, x, y + 62, w);

    const grid_y = y + 132;
    if (width <= 1024) {
        var cy = grid_y;
        try drawRecorder(model, state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 237.55 });
        cy += 249.55;
        try drawRetention(model, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 128 });
        cy += 140.0;
        try drawSegments(model, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 225 });
        cy += 237.0;
        try drawCommands(model, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 361 });
        cy += 373.0;
        try drawSafety(canvas, th, .{ .x = x, .y = cy, .w = w, .h = 242 });
        return;
    }
    const left_w = (w - 12) * 0.4717;
    const right_x = x + left_w + 12;
    const right_w = w - left_w - 12;
    try drawRecorder(model, state, canvas, th, .{ .x = x, .y = grid_y, .w = left_w, .h = 237.55 });
    try drawRetention(model, canvas, th, .{ .x = x, .y = grid_y + 249.55, .w = left_w, .h = 128 });
    try drawSegments(model, canvas, th, .{ .x = x, .y = grid_y + 389.55, .w = left_w, .h = 225 });
    try drawCommands(model, canvas, th, .{ .x = right_x, .y = grid_y, .w = right_w, .h = 361 });
    try drawSafety(canvas, th, .{ .x = right_x, .y = grid_y + 373, .w = right_w, .h = 242 });
}

fn drawControls(state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    const buttons = [_]struct { label: []const u8, id: u32, color: xsui.Color }{
        .{ .label = "start", .id = hits.recorder_start, .color = th.pass },
        .{ .label = "stop", .id = hits.recorder_stop, .color = th.refuse },
        .{ .label = "restart", .id = hits.recorder_restart, .color = th.text },
        .{ .label = "extract window", .id = hits.recorder_extract, .color = th.text },
        .{ .label = "attach dir", .id = hits.recorder_attach, .color = th.muted },
    };
    var cx = x;
    const phase = state.recorder.phase;
    for (buttons) |item| {
        const bw = 18 + common.measure(canvas, item.label, style(common.text_11, th.muted, .regular));
        const rect = Rect{ .x = cx, .y = y, .w = bw, .h = 30 };
        const enabled = switch (item.id) {
            hits.recorder_start => !phase.isActive(),
            hits.recorder_stop => phase.isActive(),
            hits.recorder_extract => !phase.isActive(),
            else => true,
        };
        try canvas.rounded(rect, 4, th.raised, if (enabled) item.color else th.line, 1);
        try label(canvas, rect.x + 9, rect.y + 7, item.label, style(common.text_11, if (enabled) item.color else th.faint, .regular));
        canvas.hit(item.id, rect);
        cx += bw + 6;
    }
    var meta_buf: [96]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s} · {d} events · {d} lost", .{ phase.label(), state.recorder.events, state.recorder.lost }) catch phase.label();
    try labelRight(canvas, x + w, y + 9, meta, style(common.text_10, if (phase == .running) th.pass else th.dim, .regular));
    if (state.recorder.reason_len > 0) {
        try label(canvas, x, y + 36, state.recorder.reasonSlice(), style(common.text_10, th.refuse, .regular));
    }
}

fn drawRecorder(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    _ = state;
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "01", "RECORDER STATE", model.meta.source);
    const attached = model.retention != null or model.segments.len > 0 or std.mem.eql(u8, model.meta.source, "LIVE");
    var window_buf: [160]u8 = undefined;
    const window_text = std.fmt.bufPrint(&window_buf, "{s} · excerpt {s}", .{
        if (model.meta.captureWindow.len > 0) model.meta.captureWindow else "window not attached",
        if (model.meta.excerpt.len > 0) model.meta.excerpt else "not attached",
    }) catch "";
    var host_buf: [192]u8 = undefined;
    const host_text = std.fmt.bufPrint(&host_buf, "{s}{s}{s}", .{
        if (model.meta.host.len > 0) model.meta.host else "local host",
        if (model.meta.kernel.len > 0) " · " else "",
        model.meta.kernel,
    }) catch model.meta.host;
    const rows = [_][2][]const u8{
        .{ "Source", model.meta.source },
        .{ "Recorder", if (attached) "attached" else "not attached" },
        .{ "Manifest", if (model.meta.manifest.len > 0) model.meta.manifest else if (model.meta.fixture.len > 0) model.meta.fixture else "not provided" },
        .{ "Window", window_text },
        .{ "Host", host_text },
        .{ "host_mutation", "false" },
    };
    var y = rect.y + 37;
    for (rows, 0..) |row, i| {
        if (i > 0) try borderLine(canvas, rect.x + 1, y, rect.w - 2, th.line);
        try label(canvas, rect.x + 14, y + 8, row[0], style(common.text_11, th.dim, .regular));
        try labelRight(canvas, rect.x + rect.w - 14, y + 8, row[1], style(common.text_11, th.text, .regular));
        y += 33.25;
    }
}

fn drawRetention(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    const ret = model.retention;
    const budget = if (ret) |r| r.budget else "unavailable";
    var budget_meta: [64]u8 = undefined;
    try panelHead(canvas, th, rect, "02", "RETENTION", if (ret) |r| std.fmt.bufPrint(&budget_meta, "{s} budget", .{r.budget}) catch "budget" else "no recorder metadata");
    try label(canvas, rect.x + 14, rect.y + 45, budget, style(common.text_13, th.text, .bold));
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 68, .w = rect.w - 28, .h = 36 }, style(common.text_11, th.dim, .regular), "Oldest closed segments drop first. Each drop is recorded as a loss marker in the journal.");
    const pct: f32 = if (ret) |r| @floatFromInt(r.usedPct) else 0;
    try canvas.fill(.{ .x = rect.x + 14, .y = rect.y + 101, .w = rect.w - 28, .h = 4 }, th.line);
    try canvas.fill(.{ .x = rect.x + 14, .y = rect.y + 101, .w = (rect.w - 28) * pct / 100.0, .h = 4 }, th.skip);
    if (ret) |r| {
        var buf: [128]u8 = undefined;
        try label(canvas, rect.x + 14, rect.y + 112, std.fmt.bufPrint(&buf, "{s} used · {s} covered · {s}", .{ r.used, r.age, r.excerpt }) catch "", style(common.text_10, th.faint, .regular));
    }
}

fn drawSegments(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    var meta_buf: [32]u8 = undefined;
    try panelHead(canvas, th, rect, "03", "SEGMENTS", std.fmt.bufPrint(&meta_buf, "{d} closed", .{model.segments.len}) catch "");
    if (model.segments.len == 0) {
        try label(canvas, rect.x + 14, rect.y + 50, "No recorder segments in this journal.", style(common.text_11, th.dim, .regular));
        return;
    }
    var y = rect.y + 36;
    for (model.segments[0..@min(model.segments.len, 6)]) |segment| {
        if (segment.open) {
            try canvas.fill(.{ .x = rect.x + 1, .y = y, .w = rect.w - 2, .h = 31 }, th.raised);
        } else if (segment.loss > 0) {
            try canvas.fill(.{ .x = rect.x + 1, .y = y, .w = rect.w - 2, .h = 31 }, th.tint_refuse);
        }
        var name_style = style(common.text_11, th.text, .regular);
        name_style.ellipsis = true;
        _ = try canvas.textIn(.{ .x = rect.x + 14, .y = y + 8, .w = 106, .h = 18 }, name_style, segment.name);
        try label(canvas, rect.x + 124, y + 8, segment.bytes, style(common.text_11, th.dim, .regular));
        try label(canvas, rect.x + 202, y + 8, segment.window, style(common.text_11, th.dim, .regular));
        var loss_buf: [32]u8 = undefined;
        const state_text = if (segment.open) "OPEN" else if (segment.loss > 0)
            std.fmt.bufPrint(&loss_buf, "LOSS {d}", .{segment.loss}) catch "LOSS"
        else
            "CLOSED";
        const color = if (segment.open) th.live else if (segment.loss > 0) th.refuse else th.dim;
        try labelRight(canvas, rect.x + rect.w - 14, y + 8, state_text, style(common.text_95, color, .regular));
        try borderLine(canvas, rect.x + 1, y + 31, rect.w - 2, th.line);
        y += 31;
    }
}

pub const commands = [_][2][]const u8{
    .{ "record a bounded window", "xsprof record --duration <ms> --out <dir>" },
    .{ "render a deterministic snapshot", "xsprof snapshot --replay /tmp/xsprof/journal.ndjson --out /tmp/xsprof.png" },
    .{ "serve the console on loopback", "xsprof serve --journal /tmp/xsprof/journal.ndjson" },
    .{ "replay in the native window", "xsprof ui --replay /tmp/xsprof/journal.ndjson" },
};

fn drawCommands(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "04", "RUN IT YOURSELF", "copy");
    var y = rect.y + 39;
    for (commands, 0..) |cmd, i| {
        try label(canvas, rect.x + 14, y, cmd[0], style(common.text_105, th.dim, .regular));
        try canvas.rounded(.{ .x = rect.x + 14, .y = y + 17, .w = rect.w - 28, .h = 31 }, 3, th.field, th.line, 1);
        try label(canvas, rect.x + 21, y + 24.5, cmd[1], style(common.text_11, th.text, .regular));
        const copy_w: f32 = 54;
        const copy_rect = Rect{ .x = rect.x + rect.w - 14 - copy_w, .y = y + 21, .w = copy_w, .h = 23 };
        try canvas.rounded(copy_rect, 3, th.raised, th.line_strong, 1);
        try label(canvas, copy_rect.x + 9, y + 24.5, "copy", style(common.text_10, th.muted, .regular));
        canvas.hit(800 + @as(u32, @intCast(i)), copy_rect);
        try borderLine(canvas, rect.x + 1, y + 58, rect.w - 2, th.line);
        y += 81.25;
    }
    _ = model;
}

fn drawSafety(canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "05", "SAFETY CONTRACT", "fail-closed");
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 45, .w = rect.w - 28, .h = 58 }, style(common.text_11, th.dim, .regular), "These verbs fail closed. The profiler does not load, attach, enable, or mutate anything on this host.");
    var x = rect.x + 14;
    const chips = [_][]const u8{ "load", "attach", "enable", "mutate", "apply", "sched-ext-attach" };
    for (chips) |chip| {
        const cw = 10 + measure(canvas, chip, style(common.text_105, th.muted, .regular));
        try canvas.rounded(.{ .x = x, .y = rect.y + 105, .w = cw, .h = 20 }, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.refuse_chip_border, 1);
        try label(canvas, x + 5, rect.y + 108, chip, style(common.text_105, th.muted, .regular));
        x += cw + 4;
    }
    try borderLine(canvas, rect.x + 1, rect.y + 137, rect.w - 2, th.line);
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 145, .w = rect.w - 28, .h = 60 }, style(common.text_11, th.dim, .regular), "Runtime samples never include argv, environment, file paths, or unsanitized command names.");
}
