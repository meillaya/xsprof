//! Timeline screen: ruler, CPU/thread lanes, loss bands, playback, brush and
//! minimap, with the inspector panel.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const format = @import("format.zig");
const icons = @import("icons.zig");
const common = @import("common.zig");

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
const borderLine = common.borderLine;

const ruler_h: f32 = 28;
const cpu_row_h: f32 = 40;
const thread_row_h: f32 = 30;
const lane_gap: f32 = 20;
const label_w: f32 = 78;
const right_pad: f32 = 12;
const bottom_pad: f32 = 8;

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const head_y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const content_w = width - stage_x - pad * 2;
    try drawHead(model, state, canvas, th, x, head_y, content_w);
    const plot_y = head_y + 53.75 + 12;
    if (width <= 1140) {
        try drawPlot(model, state, canvas, th, .{ .x = x, .y = plot_y, .w = content_w, .h = 338 });
        try drawInspector(model, state, canvas, th, .{ .x = x, .y = plot_y + 350, .w = content_w, .h = 338 });
        try drawLegend(model, state, canvas, th, x, plot_y + 696, content_w);
        try drawFoot(model, state, canvas, th, x, plot_y + 696 + 15.75 + 12, content_w);
        try drawHover(model, state, canvas, th);
        return;
    }
    const inspector_w: f32 = 286;
    const plot_w = content_w - inspector_w - 12;
    try drawPlot(model, state, canvas, th, .{ .x = x, .y = plot_y, .w = plot_w, .h = 338 });
    try drawInspector(model, state, canvas, th, .{ .x = x + plot_w + 12, .y = plot_y, .w = inspector_w, .h = 338 });
    try drawLegend(model, state, canvas, th, x, plot_y + 338 + 8, content_w);
    try drawFoot(model, state, canvas, th, x, plot_y + 338 + 8 + 15.75 + 12, content_w);
    try drawHover(model, state, canvas, th);
}

fn drawHead(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    var eyebrow = style(common.text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    var count_buf: [32]u8 = undefined;
    var ebuf: [128]u8 = undefined;
    const window_text = std.fmt.bufPrint(&ebuf, "window {s} – {s} · {s} switches", .{
        format.secs(&start_buf, state.viewStart(model.summary.windowMs), 3),
        format.secs(&end_buf, state.viewEnd(model.summary.windowMs), 3),
        format.int(&count_buf, model.summary.switches),
    }) catch "window";
    try label(canvas, x, y, window_text, eyebrow);
    var h1 = style(common.text_13, th.text, .bold);
    h1.size = if (w <= 780) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Timeline", h1);
    try borderLine(canvas, x, y + 53.75, w, th.line);

    const right = x + w;
    const btn_y = y + 10.75;
    var bx = right - 68.2;
    try button(canvas, th, .{ .x = bx, .y = btn_y, .w = 68.2, .h = 30 }, "Advisor");
    _ = canvas.button(304, .{ .x = bx, .y = btn_y, .w = 68.2, .h = 30 }, "Open advisor");
    const clock_w: f32 = 86;
    bx = bx - 8 - clock_w;
    try canvas.rounded(.{ .x = bx, .y = btn_y + 1.75, .w = clock_w, .h = 26.5 }, 4, th.field, th.line, 1);
    var clock_buf: [32]u8 = undefined;
    try label(canvas, bx + 8, btn_y + 6.5, format.secs(&clock_buf, state.timeline_playhead, 3), style(common.text_11, th.live, .regular));

    bx = bx - 8 - 66.41;
    try button(canvas, th, .{ .x = bx, .y = btn_y, .w = 66.41, .h = 30 }, if (state.timeline_playing) "Pause" else "Play");
    _ = canvas.button(303, .{ .x = bx, .y = btn_y, .w = 66.41, .h = 30 }, if (state.timeline_playing) "Pause" else "Play");
    bx = bx - 8 - 41.81;
    try button(canvas, th, .{ .x = bx, .y = btn_y, .w = 41.81, .h = 30 }, "Fit");
    _ = canvas.button(302, .{ .x = bx, .y = btn_y, .w = 41.81, .h = 30 }, "Fit timeline");
    bx = bx - 8 - 30;
    try button(canvas, th, .{ .x = bx, .y = btn_y, .w = 30, .h = 30 }, "+");
    _ = canvas.button(301, .{ .x = bx, .y = btn_y, .w = 30, .h = 30 }, "Zoom in");
    bx = bx - 7 - 30;
    try button(canvas, th, .{ .x = bx, .y = btn_y, .w = 30, .h = 30 }, "−");
    _ = canvas.button(300, .{ .x = bx, .y = btn_y, .w = 30, .h = 30 }, "Zoom out");
}

fn button(canvas: *Canvas, th: Theme, rect: Rect, text_value: []const u8) !void {
    try canvas.rounded(rect, 4, if (text_value.len == 1) th.panel else th.raised, th.line_strong, 1);
    var st = style(common.text_11, th.text, .regular);
    st.text_align = .center;
    st.valign = .center;
    _ = try canvas.textIn(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, st, text_value);
}

fn drawPlot(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    canvas.pushClip(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 });
    const inner_w = rect.w - 2;
    const inner_h = rect.h - 2;
    const x0 = label_w;
    const x1 = inner_w - right_pad;
    const plot_w = @max(40.0, x1 - x0);
    const start = state.viewStart(model.summary.windowMs);
    const end = state.viewEnd(model.summary.windowMs);
    const span = @max(1.0, end - start);
    const x_at = struct {
        fn f(ms: f64, s: f64, sp: f64, xx0: f32, pw: f32) f32 {
            return xx0 + @as(f32, @floatCast((ms - s) / sp)) * pw;
        }
    }.f;

    try canvas.fill(.{ .x = rect.x + 1, .y = rect.y + 1, .w = inner_w, .h = ruler_h }, th.panel);
    const step = stepFor(span);
    var tick = @ceil(start / step) * step;
    var guard: usize = 0;
    while (tick <= end and guard < 400) : (guard += 1) {
        const tx = x_at(tick, start, span, x0, plot_w);
        try canvas.fill(.{ .x = rect.x + 1 + tx, .y = rect.y + ruler_h - 5, .w = 1, .h = inner_h - ruler_h - bottom_pad }, th.lane_grid);
        try canvas.fill(.{ .x = rect.x + 1 + tx, .y = rect.y + ruler_h - 7, .w = 1, .h = 7 }, th.line_strong);
        var tb: [32]u8 = undefined;
        const label_text = format.secs(&tb, tick, if (step >= 1000) 1 else 3);
        try labelCenter(canvas, rect.x + 1 + tx, rect.y + 5, label_text, style(common.text_95, th.dim, .regular));
        tick += step;
    }
    try borderLine(canvas, rect.x + 1, rect.y + ruler_h, inner_w, th.line);

    const cpu_count: usize = @min(model.cpuStats.len, 4);
    var cpu_i: usize = 0;
    while (cpu_i < cpu_count) : (cpu_i += 1) {
        const y = rect.y + ruler_h + @as(f32, @floatFromInt(cpu_i)) * cpu_row_h;
        if (cpu_i % 2 == 1) try canvas.fill(.{ .x = rect.x + 1, .y = y, .w = inner_w, .h = cpu_row_h }, th.panel);
        var cb: [24]u8 = undefined;
        try label(canvas, rect.x + 10, y + 12, std.fmt.bufPrint(&cb, "cpu{d}", .{cpu_i}) catch "cpu", style(common.text_105, th.muted, .regular));
        if (model.cpuStats[cpu_i].busy > 0) {
            var bb: [16]u8 = undefined;
            try label(canvas, rect.x + 46, y + 12, format.pct(&bb, model.cpuStats[cpu_i].busy), style(common.text_95, th.dim, .regular));
        }
        try borderLine(canvas, rect.x + 1, y + cpu_row_h, inner_w, th.line);
        for (model.slices) |slice| {
            if (slice.cpu != cpu_i) continue;
            const sx0 = x_at(slice.start, start, span, x0, plot_w);
            const sx1 = x_at(slice.start + slice.dur, start, span, x0, plot_w);
            if (sx1 < 0 or sx0 > plot_w or sx1 - sx0 < 0.4) continue;
            const color = if (slice.lane == 0) th.lane_idle else th.lane(slice.lane % 9);
            const slice_rect = Rect{
                .x = rect.x + 1 + @max(x0, sx0),
                .y = y + 3,
                .w = @max(0.6, @min(plot_w + x0, sx1) - @max(x0, sx0)),
                .h = cpu_row_h - 6,
            };
            try canvas.rounded(slice_rect, 1, .{ .r = color.r, .g = color.g, .b = color.b, .a = 224 }, null, 0);
            if (state.selected_slice != null and state.selected_slice.? == slice.id) {
                try canvas.stroke(slice_rect, 1, th.text, 1.5);
            }
            var slice_buf: [96]u8 = undefined;
            const slice_label = std.fmt.bufPrint(&slice_buf, "{s} pid {d} cpu {d} {d:.2} ms", .{
                slice.comm, slice.pid, slice.cpu, slice.dur,
            }) catch slice.comm;
            _ = canvas.listItem(1000 + slice.id, slice_rect, slice_label, state.selected_slice != null and state.selected_slice.? == slice.id);
        }
    }

    const threads = @min(model.threads.len, 4);
    const thread_top = rect.y + ruler_h + @as(f32, @floatFromInt(cpu_count)) * cpu_row_h + lane_gap;
    var threads_label = style(common.text_85, th.faint, .regular);
    threads_label.tracking = 1.0;
    try label(canvas, rect.x + 10, thread_top - 18, "THREADS", threads_label);
    var t_i: usize = 0;
    while (t_i < threads) : (t_i += 1) {
        const thread = model.threads[t_i];
        const y = thread_top + @as(f32, @floatFromInt(t_i)) * thread_row_h;
        var tc: [32]u8 = undefined;
        try label(canvas, rect.x + 13, y + 6, std.fmt.bufPrint(&tc, "{s}", .{thread.comm}) catch "", style(common.text_105, th.muted, .regular));
        try canvas.fill(.{ .x = rect.x + 4, .y = y + 8, .w = 2, .h = 12 }, th.lane((thread.lane) % 9));
        for (model.slices) |slice| {
            if (!std.mem.eql(u8, slice.comm, thread.comm)) continue;
            const sx0 = x_at(slice.start, start, span, x0, plot_w);
            const sx1 = x_at(slice.start + slice.dur, start, span, x0, plot_w);
            if (sx1 < 0 or sx0 > plot_w or sx1 - sx0 < 0.4) continue;
            const color = th.lane(thread.lane % 9);
            try canvas.rounded(.{
                .x = rect.x + 1 + @max(x0, sx0),
                .y = y + 8,
                .w = @max(0.6, @min(plot_w + x0, sx1) - @max(x0, sx0)),
                .h = thread_row_h - 16,
            }, 1, .{ .r = color.r, .g = color.g, .b = color.b, .a = 178 }, null, 0);
        }
        try borderLine(canvas, rect.x + 1, y + thread_row_h - 1, inner_w, th.line);
    }

    for (model.lostAt) |lost| {
        const lx = x_at(lost, start, span, x0, plot_w);
        if (lx < 0 or lx > plot_w) continue;
        try canvas.fill(.{ .x = rect.x + 1 + lx - 3, .y = rect.y + ruler_h, .w = 6, .h = inner_h - ruler_h - bottom_pad }, th.tint_refuse);
        try canvas.fill(.{ .x = rect.x + 1 + lx, .y = rect.y + ruler_h, .w = 1, .h = inner_h - ruler_h - bottom_pad }, th.refuse);
        try canvas.fill(.{ .x = rect.x + 1 + lx - 1, .y = rect.y + ruler_h - 8, .w = 3, .h = 8 }, th.refuse);
        try canvas.fill(.{ .x = rect.x + 1 + lx - 17, .y = rect.y + ruler_h + 3, .w = 34, .h = 13 }, th.bg);
        try label(canvas, rect.x + 1 + lx - 14, rect.y + ruler_h + 4, "LOSS", style(common.text_95, th.refuse, .regular));
    }

    if (state.brush_from != null and state.brush_to != null) {
        const ba = x_at(state.brush_from.?, start, span, x0, plot_w);
        const bb = x_at(state.brush_to.?, start, span, x0, plot_w);
        const left = rect.x + 1 + @min(ba, bb);
        const bw = @max(1.0, @abs(bb - ba));
        try canvas.fill(.{ .x = left, .y = rect.y + 1 + ruler_h, .w = bw, .h = inner_h - ruler_h - bottom_pad }, .{ .r = th.live.r, .g = th.live.g, .b = th.live.b, .a = 26 });
        try canvas.fill(.{ .x = left, .y = rect.y + 1 + ruler_h, .w = bw, .h = 1 }, th.live);
    }

    const ph = state.timeline_playhead;
    const px = x_at(ph, start, span, x0, plot_w);
    try canvas.fill(.{ .x = rect.x + 1 + px, .y = rect.y + ruler_h, .w = 1.25, .h = inner_h - ruler_h - bottom_pad }, th.live);
    canvas.popClip();
}

fn labelCenter(canvas: *Canvas, cx: f32, y: f32, text_value: []const u8, base: common.TextStyle) !void {
    const w = measure(canvas, text_value, base);
    try label(canvas, cx - w * 0.5, y, text_value, base);
}

fn stepFor(visible: f64) f64 {
    const target = @max(1.0, visible / 6.0);
    const power = std.math.pow(f64, 10, @floor(std.math.log10(target)));
    for ([_]f64{ 1, 2, 5, 10 }) |m| {
        if (power * m >= target) return power * m;
    }
    return power * 10;
}

fn drawHover(model: *const Model, state: *const State, canvas: *Canvas, th: Theme) !void {
    const index = state.hover_slice orelse return;
    if (index >= model.slices.len) return;
    const slice = model.slices[index];
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}  pid {d}", .{ slice.comm, slice.pid }) catch slice.comm;
    var detail_buf: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "cpu{d} · {d:.2} ms", .{ slice.cpu, slice.dur }) catch "";
    const width: f32 = @max(measure(canvas, name, style(common.text_11, th.text, .bold)), measure(canvas, detail, style(common.text_10, th.dim, .regular))) + 20;
    var tx = state.hover_x + 14;
    if (tx + width > @as(f32, @floatFromInt(canvas.frame.width)) - 12) tx = state.hover_x - width - 14;
    const ty = @max(8.0, state.hover_y - 44);
    try canvas.rounded(.{ .x = tx, .y = ty, .w = width, .h = 38 }, 4, th.raised2, th.line_strong, 1);
    try label(canvas, tx + 10, ty + 5, name, style(common.text_11, th.text, .bold));
    try label(canvas, tx + 10, ty + 21, detail, style(common.text_10, th.dim, .regular));
}

fn drawInspector(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try borderLine(canvas, rect.x + 1, rect.y + 36, rect.w - 2, th.line);
    var title_style = style(common.text_105, th.muted, .bold);
    title_style.tracking = 1.05;
    try label(canvas, rect.x + 15, rect.y + 9, "INSPECTOR", title_style);
    try labelRight(canvas, rect.x + rect.w - 14, rect.y + 9, "idle", style(common.text_95, th.dim, .regular));
    var body = style(common.text_11, th.dim, .regular);
    body.line_height = 1.6;
    if (state.selected_slice) |id| {
        if (id < @as(u32, @intCast(model.slices.len))) {
            const slice = model.slices[id];
            var buf: [64]u8 = undefined;
            try label(canvas, rect.x + 14, rect.y + 48, slice.comm, style(common.text_13, th.text, .bold));
            try label(canvas, rect.x + 14, rect.y + 68, std.fmt.bufPrint(&buf, "cpu{d} · pid {d}", .{ slice.cpu, slice.pid }) catch "", style(common.text_11, th.dim, .regular));
            var db: [32]u8 = undefined;
            var sb: [32]u8 = undefined;
            try label(canvas, rect.x + 14, rect.y + 96, "start", style(common.text_11, th.dim, .regular));
            try labelRight(canvas, rect.x + rect.w - 14, rect.y + 96, format.secs(&sb, slice.start, 3), style(common.text_11, th.text, .regular));
            try label(canvas, rect.x + 14, rect.y + 118, "duration", style(common.text_11, th.dim, .regular));
            try labelRight(canvas, rect.x + rect.w - 14, rect.y + 118, format.ms(&db, slice.dur, 2), style(common.text_11, th.text, .regular));
            try label(canvas, rect.x + 14, rect.y + 140, "previous", style(common.text_11, th.dim, .regular));
            try labelRight(canvas, rect.x + rect.w - 14, rect.y + 140, if (slice.prev.len > 0) slice.prev else "—", style(common.text_11, th.muted, .regular));
            return;
        }
    }
    try labelWrap(canvas, .{ .x = rect.x + 14, .y = rect.y + 48, .w = rect.w - 28, .h = 90 }, body, "Select a slice to read its task, duration, p95 wait, off-CPU time, and switch count.");
    try labelWrap(canvas, .{ .x = rect.x + 14, .y = rect.y + 151, .w = rect.w - 28, .h = 60 }, body, "Drag across lanes to zoom. f restores the full excerpt.");
}

fn labelWrap(canvas: *Canvas, rect: Rect, base: common.TextStyle, text_value: []const u8) !void {
    var st = base;
    st.wrap = true;
    _ = try canvas.textIn(rect, st, text_value);
}

fn drawLegend(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    _ = state;
    _ = w;
    var cx = x;
    try canvas.stroke(.{ .x = cx, .y = y + 4, .w = 8, .h = 8 }, 1, th.line_strong, 1);
    try label(canvas, cx + 12, y, "idle", style(common.text_105, th.muted, .regular));
    cx += 12 + measure(canvas, "idle", style(common.text_105, th.muted, .regular)) + 14;
    for (model.threads[0..@min(model.threads.len, 6)]) |thread| {
        try canvas.rounded(.{ .x = cx, .y = y + 4, .w = 8, .h = 8 }, 1, th.lane(thread.lane % 9), null, 0);
        try label(canvas, cx + 12, y, thread.comm, style(common.text_105, th.muted, .regular));
        cx += 12 + measure(canvas, thread.comm, style(common.text_105, th.muted, .regular)) + 14;
    }
    try canvas.rounded(.{ .x = cx, .y = y + 4, .w = 8, .h = 8 }, 1, .{ .r = th.refuse.r, .g = th.refuse.g, .b = th.refuse.b, .a = 128 }, null, 0);
    try label(canvas, cx + 12, y, "loss band", style(common.text_105, th.muted, .regular));
}

fn drawFoot(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    var tiny = style(common.text_95, th.faint, .regular);
    tiny.tracking = 0.95;
    try label(canvas, x, y, "FULL EXCERPT", tiny);
    try canvas.rounded(.{ .x = x, .y = y + 18.25, .w = 300, .h = 34 }, 3, th.field, th.line, 1);
    _ = canvas.button(305, .{ .x = x, .y = y + 18.25, .w = 300, .h = 34 }, "Timeline minimap");
    // Density minimap.
    var buckets: [200]u32 = @splat(0);
    const total = @max(1.0, model.summary.windowMs);
    for (model.slices) |slice| {
        if (std.mem.eql(u8, slice.comm, "idle")) continue;
        const index: usize = @intFromFloat(@min(199, @floor(slice.start / total * 200)));
        buckets[index] += 1;
    }
    var max: u32 = 1;
    for (buckets) |b| max = @max(max, b);
    for (buckets, 0..) |b, i| {
        if (b == 0) continue;
        const bh = @max(1.0, @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(max)) * 30);
        try canvas.fill(.{ .x = x + 1 + @as(f32, @floatFromInt(i)) * 1.49, .y = y + 18.25 + 33 - bh, .w = 1.2, .h = bh }, .{ .r = th.live.r, .g = th.live.g, .b = th.live.b, .a = 140 });
    }
    for (model.lostAt) |lost| {
        try canvas.fill(.{ .x = x + 1 + @as(f32, @floatFromInt(@as(usize, @intFromFloat(@min(199, lost / total * 200))))) * 1.49, .y = y + 18.25 + 1, .w = 3, .h = 32 }, .{ .r = th.refuse.r, .g = th.refuse.g, .b = th.refuse.b, .a = 128 });
    }
    const start = state.viewStart(total);
    const end = state.viewEnd(total);
    const vx = x + 1 + @as(f32, @floatCast(start / total)) * 298;
    const vw = @max(4.0, @as(f32, @floatCast((end - start) / total)) * 298);
    try canvas.stroke(.{ .x = vx, .y = y + 18.25 + 0.5, .w = vw, .h = 33 }, 1, th.text, 1);

    const hints = [_][2][]const u8{ .{ "drag", "brush to zoom" }, .{ "click", "inspect slice" }, .{ "space", "playhead" } };
    var hint_x = x + 316;
    for (hints, 0..) |item, i| {
        if (i > 0) {
            try label(canvas, hint_x, y + 18.25, "·", style(common.text_11, th.faint, .regular));
            hint_x += measure(canvas, "·", style(common.text_11, th.faint, .regular)) + 10;
        }
        try label(canvas, hint_x, y + 18.25, item[0], style(common.text_11, th.dim, .regular));
        hint_x += measure(canvas, item[0], style(common.text_11, th.dim, .regular)) + 4;
        try label(canvas, hint_x, y + 18.25, item[1], style(common.text_11, th.dim, .regular));
        hint_x += measure(canvas, item[1], style(common.text_11, th.dim, .regular)) + 10;
    }

    var state_buf: [64]u8 = undefined;
    const state_text = std.fmt.bufPrint(&state_buf, "{s} · {s}", .{ model.meta.source, if (std.mem.eql(u8, model.meta.source, "LIVE")) "following feed" else "no live tail" }) catch model.meta.source;
    const sw = measure(canvas, state_text, style(common.text_10, th.dim, .regular)) + 14;
    try canvas.rounded(.{ .x = x + w - sw, .y = y + 15.63, .w = sw, .h = 23 }, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line, 1);
    try label(canvas, x + w - sw + 7, y + 19, state_text, style(common.text_10, th.dim, .regular));
}
