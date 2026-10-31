//! Overview screen: capture brief, capability matrix, per-CPU lanes, advisor
//! preview, top threads, event mix, memory/NUMA, and the loss ledger.

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
const FontWeight = xsui.FontWeight;
const Model = model_mod.Model;
const State = state_mod.State;
const text_10 = common.text_10;
const text_95 = common.text_95;
const text_105 = common.text_105;
const text_11 = common.text_11;
const text_12 = common.text_12;
const text_13 = common.text_13;
const style = common.style;
const measure = common.measure;
const label = common.label;
const labelRight = common.labelRight;
const labelWrapped = common.labelWrapped;
const borderLine = common.borderLine;
const panelBase = common.panelBase;
const panelHead = common.panelHead;
const stateBadge = common.stateBadge;
const severityColor = common.severityColor;

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const content_x = stage_x + pad;
    const content_w = width - stage_x - pad * 2;
    const scroll = state.scroll_y;
    const y0 = stage_top + (if (compact) @as(f32, 14) else 16) - scroll;
    try drawScreenHead(model, state, canvas, th, content_x, y0, content_w);
    const brief_y = y0 + 67.5 + 12;
    const brief_h: f32 = if (compact) 284.44 else 108.97;
    if (compact) {
        try drawBriefCompact(model, canvas, th, content_x, brief_y, content_w);
    } else {
        try drawBrief(model, canvas, th, content_x, brief_y, content_w);
    }
    const grid_y = brief_y + brief_h + 12;
    const wide = content_w >= 1200;
    const primary_base = @max(
        37.0 + @as(f32, @floatFromInt(model.capabilities.len)) * 53.25,
        @max(37.0 + @as(f32, @floatFromInt(model.cpuStats.len)) * 55.0 + 50.0, 283.5),
    );
    const primary_h: f32 = if (compact)
        409.75 + 12 + 292.05 + 12 + 287.05
    else
        primary_base + (if (wide) @as(f32, 0) else 12 + 287.05);
    try drawPrimaryGrid(model, canvas, th, content_x, grid_y, content_w, primary_h);
    const grid2_y = grid_y + primary_h + 12;
    const secondary_h: f32 = if (compact)
        264.25 * 3 + 24
    else
        @max(264.25, @max(
            36.0 + 23.25 + @as(f32, @floatFromInt(@min(model.threads.len, 7))) * 29.0,
            @max(42.5 + @as(f32, @floatFromInt(@min(model.typeCounts.len, 7))) * 26.5, 36.0 + 2 * 69.44),
        )) + (if (wide) @as(f32, 0) else 12 + 210.92);
    try drawSecondaryGrid(model, canvas, th, content_x, grid2_y, content_w, secondary_h);
    const loss_y = grid2_y + secondary_h + 12;
    try drawLossLedger(model, canvas, th, content_x, loss_y, content_w);
}

fn drawScreenHead(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    var eyebrow = style(text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    const eyebrow_text = if (model.meta.sessionLabel.len > 0) model.meta.sessionLabel else "JOURNAL  ·  REPLAY  ·  SANITIZED";
    try label(canvas, x, y + 13.75, eyebrow_text, eyebrow);
    var h1 = style(text_13, th.text, .bold);
    h1.size = 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 32.5, state_mod.screenName(state.screen), h1);
    const right = x + w;
    const note = style(text_11, th.muted, .regular);
    var note_buf: [192]u8 = undefined;
    const note_text = if (model.meta.captureStart.len > 0 and model.meta.captureEnd.len > 0)
        std.fmt.bufPrint(&note_buf, "Capture window {s} → {s} · excerpt {s}", .{
            model.meta.captureStart,
            model.meta.captureEnd,
            if (model.meta.excerpt.len > 0) model.meta.excerpt else "not attached",
        }) catch ""
    else
        std.fmt.bufPrint(&note_buf, "Capture window {s} · excerpt {s}", .{
            if (model.meta.captureWindow.len > 0) model.meta.captureWindow else "not attached",
            if (model.meta.excerpt.len > 0) model.meta.excerpt else "not attached",
        }) catch "";
    if (note_text.len != 0) try labelRight(canvas, right, y, note_text, note);
    const action_y = y + 24.5;
    const open_text = "Open journal";
    const reload_text = "Reload fixture";
    const btn_font = style(text_11, th.text, .regular);
    const open_w = 20 + measure(canvas, open_text, btn_font) + 6 + 13;
    const reload_w = 20 + measure(canvas, reload_text, style(text_11, th.muted, .regular));
    const reload_x = right - reload_w;
    const open_x = reload_x - 8 - open_w;
    try canvas.rounded(.{ .x = open_x, .y = action_y, .w = open_w, .h = 30 }, 4, th.raised, th.line_strong, 1);
    try icons.draw(canvas, .folder, .{ .x = open_x + 10, .y = action_y + 8.5, .w = 13, .h = 13 }, th.text);
    try label(canvas, open_x + 10 + 13 + 6, action_y + 6.75, open_text, btn_font);
    canvas.hit(203, .{ .x = open_x, .y = action_y, .w = open_w, .h = 30 });
    try canvas.rounded(.{ .x = reload_x, .y = action_y, .w = reload_w, .h = 30 }, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line_strong, 1);
    try label(canvas, reload_x + 10, action_y + 6.75, reload_text, style(text_11, th.muted, .regular));
    canvas.hit(204, .{ .x = reload_x, .y = action_y, .w = reload_w, .h = 30 });
    try borderLine(canvas, x, y + 67.5, w, th.line);
}

fn drawBrief(model: *const Model, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    try canvas.rounded(.{ .x = x, .y = y, .w = w, .h = 108.97 }, 5, th.panel, th.line, 1);
    const inner_x = x + 1;
    const inner_w = w - 2;
    const lead_w = inner_w * 1.35 / 5.35;
    const other_w = (inner_w - lead_w) / 4;
    const widths = [_]f32{ lead_w, other_w, other_w, other_w, other_w };
    var sx = inner_x;
    for (0..5) |i| {
        if (i > 0) try borderLine(canvas, sx, y + 1, 1, th.line);
        try drawStatCard(model, canvas, th, .{ .x = sx, .y = y + 1, .w = widths[i], .h = 106.97 }, i);
        sx += widths[i];
    }
}

fn drawBriefCompact(model: *const Model, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    try canvas.rounded(.{ .x = x, .y = y, .w = w, .h = 284.44 }, 5, th.panel, th.line, 1);
    const inner_x = x + 1;
    const inner_w = w - 2;
    const half = inner_w * 0.5;
    try drawStatCard(model, canvas, th, .{ .x = inner_x, .y = y + 1, .w = inner_w, .h = 98.38 }, 0);
    try borderLine(canvas, inner_x, y + 99.38, inner_w, th.line);
    try borderLine(canvas, inner_x + half, y + 99.38, 1, th.line);
    try borderLine(canvas, inner_x, y + 191.41, inner_w, th.line);
    for (1..5) |i| {
        const col: f32 = if (i % 2 == 1) 0 else 1;
        const row: f32 = if (i <= 2) 0 else 1;
        try drawStatCard(model, canvas, th, .{
            .x = inner_x + col * half,
            .y = y + 99.38 + row * 92.03,
            .w = half,
            .h = 92.03,
        }, i);
    }
}

fn drawStatCard(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect, i: usize) !void {
    const labels = [_][]const u8{ "P95 WAKE→RUN", "SWITCHES", "EVENTS", "LOST", "CPU BUSY" };
    var value_buf: [64]u8 = undefined;
    var sub_buf: [128]u8 = undefined;
    const value_text = switch (i) {
        0 => std.fmt.bufPrint(&value_buf, "{d:.3}ms", .{model.summary.p95 orelse 0}) catch "?",
        1 => format.int(&value_buf, model.summary.switches),
        2 => format.int(&value_buf, model.summary.events),
        3 => format.int(&value_buf, model.summary.lost),
        else => format.pct(&value_buf, model.summary.cpuBusy orelse 0),
    };
    const sub_text = switch (i) {
        0 => std.fmt.bufPrint(&sub_buf, "p99 {d:.3} ms · {d} CPUs", .{ model.summary.p99 orelse 0, model.summary.cpus }) catch "",
        1 => std.fmt.bufPrint(&sub_buf, "{d:.1} /s · {d} migrations", .{ model.summary.switchRate, model.summary.migrations }) catch "",
        2 => std.fmt.bufPrint(&sub_buf, "{d:.3} s excerpt · {s} capture", .{ model.summary.windowMs / 1000, model.meta.captureWindow }) catch "",
        3 => if (model.summary.lost > 0) "ring overflow · never zero-filled" else "no markers in this journal",
        else => if (model.summary.runqueue) |rq| std.fmt.bufPrint(&sub_buf, "runqueue {d:.1} peak", .{rq}) catch "" else "runqueue not sampled",
    };
    var value_style = style(text_13, if (i == 3 and model.summary.lost > 0) th.refuse else th.text, .bold);
    const phone = rect.w < 250;
    value_style.size = if (i == 0) (if (phone) 28 else 34) else (if (phone) 22 else 27);
    value_style.line_height = 1.05;
    value_style.tracking = -0.8;
    var label_style = style(text_105, th.dim, .regular);
    label_style.tracking = 1.15;
    var sub_style = style(text_11, th.dim, .regular);
    sub_style.line_height = 1.45;
    sub_style.wrap = true;
    var sub_layout: xsui.TextLayout = .{};
    try canvas.layoutText(sub_style, sub_text, rect.w - 32, &sub_layout);
    const sub_h = sub_layout.height();
    const value_h = value_style.size * value_style.line_height;
    const content_h = 15.75 + 2 + value_h + 2 + sub_h;
    const available_h: f32 = rect.h - 27;
    const top = rect.y + 13 + (available_h - content_h) * 0.5;
    canvas.pushClip(.{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 2, .h = rect.h });
    try label(canvas, rect.x + 16, top, labels[i], label_style);
    const shown_value = switch (i) {
        0 => std.fmt.bufPrint(&value_buf, "{d:.3}", .{model.summary.p95 orelse 0}) catch "?",
        4 => std.fmt.bufPrint(&value_buf, "{d}", .{model.summary.cpuBusy orelse 0}) catch "?",
        else => value_text,
    };
    const value_color = if (i == 0) th.live else if (i == 3 and model.summary.lost > 0) th.refuse else th.text;
    try label(canvas, rect.x + 16, top + 17.75, shown_value, style(value_style, value_color, .bold));
    if (i == 0 or i == 4) {
        var unit = style(text_12, th.muted, .regular);
        unit.line_height = 1.5;
        const unit_text = if (i == 0) "ms" else "%";
        try label(canvas, rect.x + 16 + measure(canvas, shown_value, value_style) + 3, top + 17.75 + value_style.size * 0.72, unit_text, unit);
    }
    _ = try canvas.textIn(.{ .x = rect.x + 16, .y = top + 17.75 + value_h + 2, .w = rect.w - 32, .h = sub_h }, sub_style, sub_text);
    canvas.popClip();
}

fn drawPrimaryGrid(model: *const Model, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32, h: f32) !void {
    const gap = 12.0;
    const wide = w >= 1200;
    if (w < 900) {
        const cap_h = 37.0 + @as(f32, @floatFromInt(model.capabilities.len)) * 53.25;
        try drawCapabilities(model, canvas, th, .{ .x = x, .y = y, .w = w, .h = cap_h });
        try drawCpuPanel(model, canvas, th, .{ .x = x, .y = y + cap_h + gap, .w = w, .h = 292.05 });
        try drawAdvisorMini(model, canvas, th, .{ .x = x, .y = y + cap_h + gap + 292.05 + gap, .w = w, .h = 287.05 });
        return;
    }
    if (wide) {
        const panel_w = (w - gap * 2) / 3;
        const panel_h = @max(283.5, @max(37.0 + @as(f32, @floatFromInt(model.capabilities.len)) * 53.25, 37.0 + @as(f32, @floatFromInt(model.cpuStats.len)) * 55.0 + 50.0));
        try drawCapabilities(model, canvas, th, .{ .x = x, .y = y, .w = panel_w, .h = panel_h });
        try drawCpuPanel(model, canvas, th, .{ .x = x + panel_w + gap, .y = y, .w = panel_w, .h = panel_h });
        try drawAdvisorMini(model, canvas, th, .{ .x = x + (panel_w + gap) * 2, .y = y, .w = panel_w, .h = panel_h });
    } else {
        const panel_w = (w - gap) / 2;
        const panel_h = @max(283.5, @max(37.0 + @as(f32, @floatFromInt(model.capabilities.len)) * 53.25, 37.0 + @as(f32, @floatFromInt(model.cpuStats.len)) * 55.0 + 50.0));
        try drawCapabilities(model, canvas, th, .{ .x = x, .y = y, .w = panel_w, .h = panel_h });
        try drawCpuPanel(model, canvas, th, .{ .x = x + panel_w + gap, .y = y, .w = panel_w, .h = panel_h });
        try drawAdvisorMini(model, canvas, th, .{ .x = x, .y = y + 409.75 + gap, .w = w, .h = 287.05 });
    }
    _ = h;
}

fn drawCapabilities(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try panelBase(canvas, th, rect);
    var meta_buf: [32]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{d} signals", .{model.capabilities.len}) catch "";
    try panelHead(canvas, th, rect, "01", "CAPABILITY MATRIX", meta);
    var y = rect.y + 37;
    for (model.capabilities) |cap| {
        const row = Rect{ .x = rect.x + 1, .y = y, .w = rect.w - 2, .h = 53.25 };
        var cap_style = style(text_12, th.text, .regular);
        cap_style.size = 12.5;
        try label(canvas, row.x + 14, row.y + 8.0, cap.name, cap_style);
        try stateBadge(canvas, th, .{ .x = row.x + row.w - 14 - 76, .y = row.y + 8.0, .w = 76, .h = 18.25 }, cap.state, cap.glyph, cap.state);
        try label(canvas, row.x + 14, row.y + 27.75, cap.detail, style(text_11, th.dim, .regular));
        try borderLine(canvas, row.x, row.y + row.h, row.w, th.line);
        y += 53.25;
    }
}

fn drawCpuPanel(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try panelBase(canvas, th, rect);
    try panelHead(canvas, th, rect, "02", "PER-CPU LANES", "busy · rq · p95");
    var y = rect.y + 37;
    var buf: [48]u8 = undefined;
    for (model.cpuStats, 0..) |cpu, cpu_index| {
        const row_h: f32 = if (cpu_index + 1 == model.cpuStats.len) 54 else 55;
        const row = Rect{ .x = rect.x + 1, .y = y, .w = rect.w - 2, .h = row_h };
        var cpu_buf: [16]u8 = undefined;
        try label(canvas, row.x + 14, row.y + 9, std.fmt.bufPrint(&cpu_buf, "cpu{d}", .{cpu.cpu}) catch "cpu", style(text_11, th.muted, .regular));
        const busy_text = format.pct(&buf, cpu.busy);
        try label(canvas, row.x + 14, row.y + 25.5, busy_text, style(text_13, th.text, .bold));
        const strip = Rect{ .x = row.x + 74, .y = row.y + 8, .w = row.w - 88, .h = 18 };
        try canvas.fill(strip, th.lane_idle);
        const count = @max(@as(usize, 1), cpu.buckets.len);
        for (cpu.buckets, 0..) |bucket, i| {
            const bw = strip.w / 120.0 * 1.7;
            const height: f32 = @floatFromInt(@max(2, @as(i32, @intFromFloat(@round(2 + bucket * 15)))));
            const bx = strip.x + @as(f32, @floatFromInt(i)) * strip.w / @as(f32, @floatFromInt(count));
            const opacity = if (bucket > 0) 0.2 + bucket * 0.8 else 0.06;
            try canvas.fill(.{ .x = bx, .y = strip.y + 18.0 - height, .w = bw, .h = height }, .{ .r = th.live.r, .g = th.live.g, .b = th.live.b, .a = @intFromFloat(@min(1, opacity) * 255) });
        }
        var meta_buf: [96]u8 = undefined;
        const meta_text = if (cpu.runqueue) |rq| std.fmt.bufPrint(&meta_buf, "rq {d:.1}", .{rq}) catch "" else "rq —";
        try label(canvas, strip.x, row.y + 31, meta_text, style(text_10, th.dim, .regular));
        var p95_buf: [48]u8 = undefined;
        const p95_text = if (cpu.p95) |p| std.fmt.bufPrint(&p95_buf, "p95 {d:.2} ms", .{p}) catch "" else "p95 —";
        var p95_style = style(text_10, if ((cpu.p95 orelse 0) > 2) th.skip else th.dim, .regular);
        p95_style.text_align = .center;
        _ = try canvas.textIn(.{ .x = strip.x, .y = row.y + 31, .w = strip.w, .h = 15 }, p95_style, p95_text);
        var sw_buf: [32]u8 = undefined;
        try labelRight(canvas, row.x + row.w - 14, row.y + 31, std.fmt.bufPrint(&sw_buf, "{d} sw", .{cpu.switches}) catch "", style(text_10, th.dim, .regular));
        try borderLine(canvas, row.x, row.y + row.h, row.w, th.line);
        y += row_h;
    }
    const note_y = y + 9;
    var bucket_note: [128]u8 = undefined;
    const bucket_count: usize = if (model.cpuStats.len > 0) model.cpuStats[0].buckets.len else 0;
    const note = std.fmt.bufPrint(&bucket_note, "{d} buckets across the excerpt. Idle spans stay dark — never counted as load.", .{bucket_count}) catch "Buckets across the excerpt.";
    var note_style = style(text_11, th.dim, .regular);
    note_style.line_height = 1.55;
    try labelWrapped(canvas, .{ .x = rect.x + 14, .y = note_y, .w = rect.w - 28, .h = 50 }, note_style, note);
}

fn drawAdvisorMini(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try panelBase(canvas, th, rect);
    try panelHead(canvas, th, rect, "03", "ADVISOR", "");
    try label(canvas, rect.x + 14, rect.y + 45, "Suggestion only — never applied.", style(text_11, th.dim, .regular));
    var y = rect.y + 72.05;
    for (model.advisor) |card| {
        const color = severityColor(th, card.severity);
        try canvas.circle(rect.x + 22, y + 15.05, 3, color);
        try label(canvas, rect.x + 35, y + 6.25, card.id, style(text_11, th.text, .regular));
        try labelRight(canvas, rect.x + rect.w - 14, y + 7.375, card.severity, style(text_95, th.dim, .regular));
        try borderLine(canvas, rect.x + 1, y + 30, rect.w - 2, th.line);
        y += 30;
    }
}

fn drawSecondaryGrid(model: *const Model, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32, h: f32) !void {
    const gap = 12.0;
    const wide = w >= 1200;
    if (w < 900) {
        try drawThreads(model, canvas, th, .{ .x = x, .y = y, .w = w, .h = 264.25 }, true);
        try drawMix(model, canvas, th, .{ .x = x, .y = y + 264.25 + gap, .w = w, .h = 264.25 });
        try drawMemory(model, canvas, th, .{ .x = x, .y = y + (264.25 + gap) * 2, .w = w, .h = 264.25 });
        return;
    }
    if (wide) {
        const panel_w = (w - gap * 2) / 3;
        try drawThreads(model, canvas, th, .{ .x = x, .y = y, .w = panel_w, .h = 264.25 }, false);
        try drawMix(model, canvas, th, .{ .x = x + panel_w + gap, .y = y, .w = panel_w, .h = 264.25 });
        try drawMemory(model, canvas, th, .{ .x = x + (panel_w + gap) * 2, .y = y, .w = panel_w, .h = 264.25 });
    } else {
        const panel_w = (w - gap) / 2;
        try drawThreads(model, canvas, th, .{ .x = x, .y = y, .w = panel_w, .h = 264.25 }, false);
        try drawMix(model, canvas, th, .{ .x = x + panel_w + gap, .y = y, .w = panel_w, .h = 264.25 });
        try drawMemory(model, canvas, th, .{ .x = x, .y = y + 264.25 + gap, .w = w, .h = 210.92 });
    }
    _ = h;
}

fn drawThreads(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect, compact: bool) !void {
    try panelBase(canvas, th, rect);
    try panelHead(canvas, th, rect, "04", "TOP THREADS", "by p95 wake→run");
    if (compact) {
        var row_y = rect.y + 37;
        for (model.threads[0..@min(model.threads.len, 4)]) |thread| {
            try canvas.fill(.{ .x = rect.x + 14, .y = row_y + 7, .w = 2, .h = 13 }, th.lane(thread.lane));
            try label(canvas, rect.x + 22, row_y + 5, thread.comm, style(text_12, th.text, .regular));
            var p95_buf: [32]u8 = undefined;
            const p95_text = if (thread.p95) |p| std.fmt.bufPrint(&p95_buf, "{d:.2} ms", .{p}) catch "—" else "—";
            try labelRight(canvas, rect.x + rect.w - 14, row_y + 5, p95_text, style(text_11, if ((thread.p95 orelse 0) > 2) th.skip else th.text, .regular));
            var meta_buf: [96]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buf, "pid {d} · {d} sw · {d} mig", .{ thread.pid, thread.switches, thread.migrations }) catch "";
            try label(canvas, rect.x + 22, row_y + 23, meta, style(text_10, th.faint, .regular));
            try canvas.fill(.{ .x = rect.x + 14, .y = row_y + 43, .w = rect.w - 28, .h = 3 }, th.line);
            try canvas.fill(.{ .x = rect.x + 14, .y = row_y + 43, .w = (rect.w - 28) * @as(f32, @floatCast(@min(1.0, thread.share / 20.0))), .h = 3 }, th.live);
            try borderLine(canvas, rect.x + 1, row_y + 55, rect.w - 2, th.line);
            row_y += 55;
        }
        return;
    }
    const gap = 6.0;
    const fixed = [_]f32{ 46, 52, 48, 66, 44 };
    const inner_w = rect.w - 28;
    var fixed_sum: f32 = 0;
    for (fixed) |v| fixed_sum += v;
    const first_w = inner_w - fixed_sum - gap * 5;
    var xs: [6]f32 = undefined;
    var widths: [6]f32 = undefined;
    xs[0] = rect.x + 14;
    widths[0] = first_w;
    var cursor = xs[0] + first_w + gap;
    for (fixed, 0..) |v, i| {
        xs[i + 1] = cursor;
        widths[i + 1] = v;
        cursor += v + gap;
    }
    const y = rect.y + 37;
    var head = style(text_95, th.faint, .regular);
    head.tracking = 0.76;
    try label(canvas, xs[0], y + 4, "THREAD", head);
    try labelRight(canvas, xs[1] + widths[1], y + 4, "PID", head);
    try labelRight(canvas, xs[2] + widths[2], y + 4, "SW", head);
    try labelRight(canvas, xs[3] + widths[3], y + 4, "MIG", head);
    try labelRight(canvas, xs[4] + widths[4], y + 4, "P95", head);
    try label(canvas, xs[5], y + 4, "SHARE", head);
    try borderLine(canvas, rect.x + 1, y + 23.25, rect.w - 2, th.line);
    var row_y = y + 23.25;
    var buf: [32]u8 = undefined;
    for (model.threads[0..@min(model.threads.len, 7)]) |thread| {
        try canvas.fill(.{ .x = xs[0], .y = row_y + 8, .w = 2, .h = 13 }, th.lane(thread.lane));
        try label(canvas, xs[0] + 8, row_y + 5.75, thread.comm, style(text_11, th.text, .regular));
        try labelRight(canvas, xs[1] + widths[1], row_y + 5.75, std.fmt.bufPrint(&buf, "{d}", .{thread.pid}) catch "", style(text_11, th.muted, .regular));
        try labelRight(canvas, xs[2] + widths[2], row_y + 5.75, format.int(&buf, thread.switches), style(text_11, th.muted, .regular));
        try labelRight(canvas, xs[3] + widths[3], row_y + 5.75, format.int(&buf, thread.migrations), style(text_11, th.muted, .regular));
        var p95_buf: [32]u8 = undefined;
        const p95_text = if (thread.p95) |p| std.fmt.bufPrint(&p95_buf, "{d:.2} ms", .{p}) catch "—" else "—";
        try labelRight(canvas, xs[4] + widths[4], row_y + 5.75, p95_text, style(text_11, if ((thread.p95 orelse 0) > 2) th.skip else th.text, .regular));
        try canvas.fill(.{ .x = xs[5], .y = row_y + 12.5, .w = widths[5], .h = 3 }, th.line);
        try canvas.fill(.{ .x = xs[5], .y = row_y + 12.5, .w = widths[5] * @as(f32, @floatCast(@min(1.0, thread.share / 20.0))), .h = 3 }, th.live);
        try borderLine(canvas, rect.x + 1, row_y + 29, rect.w - 2, th.line);
        row_y += 29;
    }
}

fn drawMix(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try panelBase(canvas, th, rect);
    var total_buf: [32]u8 = undefined;
    try panelHead(canvas, th, rect, "05", "EVENT MIX", std.fmt.bufPrint(&total_buf, "{d} total", .{model.summary.events}) catch "");
    var y = rect.y + 42.75;
    var max_count: u32 = 1;
    for (model.typeCounts) |t| max_count = @max(max_count, t.count);
    for (model.typeCounts[0..@min(model.typeCounts.len, 7)]) |t| {
        const color = mixColor(th, t.kind);
        try label(canvas, rect.x + 14, y + 5, mixLabel(t.kind), style(text_11, th.muted, .regular));
        const track_x = rect.x + 114;
        const track_w = rect.w - 114 - 44 - 8 - 14;
        try canvas.fill(.{ .x = track_x, .y = y + 11.25, .w = track_w, .h = 4 }, th.line);
        try canvas.fill(.{ .x = track_x, .y = y + 11.25, .w = track_w * @as(f32, @floatFromInt(t.count)) / @as(f32, @floatFromInt(max_count)), .h = 4 }, color);
        try labelRight(canvas, rect.x + rect.w - 27, y + 5, format.int(&total_buf, t.count), style(text_11, th.muted, .regular));
        y += 26.5;
    }
}

fn mixColor(th: Theme, kind: []const u8) Color {
    if (std.mem.eql(u8, kind, "sched_switch")) return th.live;
    if (std.mem.eql(u8, kind, "sched_wakeup")) return th.pass;
    if (std.mem.eql(u8, kind, "sched_migrate")) return th.vm;
    if (std.mem.eql(u8, kind, "page_fault")) return th.skip;
    if (std.mem.eql(u8, kind, "cache_miss")) return th.pending;
    if (std.mem.eql(u8, kind, "loss")) return th.refuse;
    return th.muted;
}

fn mixLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "sched_switch")) return "switch";
    if (std.mem.eql(u8, kind, "sched_wakeup")) return "wakeup";
    if (std.mem.eql(u8, kind, "sched_migrate")) return "migrate";
    if (std.mem.eql(u8, kind, "page_fault")) return "page fault";
    if (std.mem.eql(u8, kind, "cache_miss")) return "cache miss";
    if (std.mem.eql(u8, kind, "loss")) return "loss";
    return kind;
}

fn drawMemory(model: *const Model, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try panelBase(canvas, th, rect);
    try panelHead(canvas, th, rect, "06", "MEMORY & NUMA", "counters");
    const mem = model.memory;
    var page_buf: [64]u8 = undefined;
    var llc_buf: [64]u8 = undefined;
    var reclaim_buf: [64]u8 = undefined;
    var cross_buf: [64]u8 = undefined;
    var page_sub_buf: [64]u8 = undefined;
    var llc_sub_buf: [64]u8 = undefined;
    var reclaim_sub_buf: [64]u8 = undefined;
    var cross_sub_buf: [64]u8 = undefined;
    var page_faults: []const u8 = "uncollected";
    var llc: []const u8 = "uncollected";
    var reclaims: []const u8 = "uncollected";
    var cross: []const u8 = "uncollected";
    var page_sub: []const u8 = "journal has no memory counters";
    var llc_sub: []const u8 = "—";
    var reclaim_sub: []const u8 = "—";
    var cross_sub: []const u8 = "—";
    if (mem) |m| {
        page_faults = format.int(&page_buf, m.pageFaults);
        page_sub = std.fmt.bufPrint(&page_sub_buf, "trace samples", .{}) catch "—";
        if (m.has_llc) {
            llc = format.pctF(&llc_buf, m.cacheMiss, 1);
            llc_sub = std.fmt.bufPrint(&llc_sub_buf, "sampled windows", .{}) catch "—";
        }
        if (m.has_reclaim) {
            reclaims = format.int(&reclaim_buf, m.reclaims);
            reclaim_sub = std.fmt.bufPrint(&reclaim_sub_buf, "max {d:.2} ms", .{m.reclaimMax}) catch "—";
        }
        if (m.has_cross) {
            cross = format.pctF(&cross_buf, m.cross, 1);
            cross_sub = std.fmt.bufPrint(&cross_sub_buf, "{s} · rule skipped", .{m.numa}) catch "—";
        }
    }
    const cells = [_][3][]const u8{
        .{ "PAGE FAULTS", page_faults, page_sub },
        .{ "LLC MISS", llc, llc_sub },
        .{ "DIRECT RECLAIM", reclaims, reclaim_sub },
        .{ "CROSS-CCX", cross, cross_sub },
    };

    const inner = Rect{ .x = rect.x + 1, .y = rect.y + 36.75, .w = rect.w - 2, .h = 69.4375 };
    const cw = inner.w / 2;
    const ch: f32 = 69.4375;
    for (0..4) |i| {
        const col = i % 2;
        const row = i / 2;
        const cell = Rect{ .x = inner.x + @as(f32, @floatFromInt(col)) * cw, .y = inner.y + @as(f32, @floatFromInt(row)) * ch, .w = cw, .h = ch };
        var key_style = style(text_95, th.dim, .regular);
        key_style.tracking = 0.76;
        try label(canvas, cell.x + 14, cell.y + 9, cells[i][0], key_style);
        var value_style = style(text_13, th.text, .bold);
        value_style.size = 16;
        value_style.line_height = 1.2;
        try label(canvas, cell.x + 14, cell.y + 24.25, cells[i][1], value_style);
        try label(canvas, cell.x + 14, cell.y + 44.5, cells[i][2], style(text_10, th.faint, .regular));
        if (col == 0) try borderLine(canvas, cell.x + cw - 1, cell.y, 1, th.line);
        if (row == 0) try borderLine(canvas, cell.x, cell.y + ch - 1, cw, th.line);
    }
}

fn drawLossLedger(model: *const Model, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    try canvas.rounded(.{ .x = x, .y = y, .w = w, .h = 137.5 }, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, .{ .x = x, .y = y, .w = w, .h = 137.5 }, "07", "LOSS LEDGER", "never zero-filled");
    if (model.lostAt.len == 0) {
        try label(canvas, x + 14, y + 50, "No loss markers in this journal.", style(text_11, th.dim, .regular));
        return;
    }
    var row_y = y + 36;
    for (model.lostAt[0..@min(model.lostAt.len, 3)]) |lost| {
        try canvas.fill(.{ .x = x + 1, .y = row_y, .w = w - 2, .h = 33.5 }, th.tint_refuse);
        var buf: [128]u8 = undefined;
        const text_value = std.fmt.bufPrint(&buf, "■ LOSS {s}  ring overflow · not delivered by the recorder", .{format.secs(&buf, lost, 3)}) catch "LOSS";
        try label(canvas, x + 14, row_y + 8.5, text_value, style(text_11, th.muted, .regular));
        try borderLine(canvas, x + 1, row_y + 33.5, w - 2, th.line);
        row_y += 33.5;
    }
}
