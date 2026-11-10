//! Advisor screen: seven evidence-linked cards, severity filters, and the
//! suggestion-only safety copy.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const format = @import("format.zig");

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

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const w = width - stage_x - pad * 2;
    var eyebrow = style(common.text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    var eyebrow_buf: [64]u8 = undefined;
    const eyebrow_text = if (model.advisor.len == 0)
        "OFFLINE JOURNAL  ·  RULES NOT EVALUATED"
    else
        std.fmt.bufPrint(&eyebrow_buf, "{d} RULES  ·  EVIDENCE-LINKED", .{model.advisor.len}) catch "RULES  ·  EVIDENCE-LINKED";
    try label(canvas, x, y + 9.75, eyebrow_text, eyebrow);
    var h1 = style(common.text_13, th.text, .bold);
    h1.size = if (width <= 780) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 28.5, "Advisor", h1);
    try labelRight(canvas, x + w, y, "Suggestion only. xsprof never applies, loads, or attaches anything.", style(common.text_11, th.muted, .regular));
    try borderLine(canvas, x, y + 63.5, w, th.line);
    try drawFilters(model, state, canvas, th, x, y, w);

    const grid_y = y + 75.5;
    const gap: f32 = 12;
    if (width <= 1024) {
        var cy = grid_y;
        var single_shown: usize = 0;
        for (model.advisor, 0..) |card, card_index| {
            if (!matches(state.advisor_filter, card.severity)) continue;
            try drawCard(canvas, th, card, .{ .x = x, .y = cy, .w = w, .h = 225.72 }, card_index);
            cy += 225.72 + gap;
            single_shown += 1;
        }
        if (single_shown == 0) {
            var empty_buf: [96]u8 = undefined;
            const empty_text = std.fmt.bufPrint(&empty_buf, "No rules match this filter. Choose “All {d}” to see the full set.", .{model.advisor.len}) catch "No rules match this filter.";
            try common.labelWrapped(canvas, .{ .x = x, .y = grid_y + 16, .w = w, .h = 40 }, style(common.text_11, th.dim, .regular), empty_text);
        }
        return;
    }
    const card_w = (w - gap) / 2;
    const row_heights = [_]f32{ 225.72, 225.72, 206.53, 158.67 };
    var row_offsets = [_]f32{ 0, 0, 0, 0 };
    var row_y = grid_y;
    for (0..row_offsets.len) |i| {
        row_offsets[i] = row_y;
        row_y += row_heights[i] + gap;
    }
    var shown: usize = 0;
    for (model.advisor, 0..) |card, card_index| {
        if (!matches(state.advisor_filter, card.severity)) continue;
        const col = shown % 2;
        const row = shown / 2;
        if (row < row_heights.len) {
            try drawCard(canvas, th, card, .{
                .x = x + @as(f32, @floatFromInt(col)) * (card_w + gap),
                .y = row_offsets[row],
                .w = card_w,
                .h = row_heights[row],
            }, card_index);
        }
        shown += 1;
    }
    if (shown == 0) {
        var empty_buf: [96]u8 = undefined;
        const empty_text = std.fmt.bufPrint(&empty_buf, "No rules match this filter. Choose “All {d}” to see the full set.", .{model.advisor.len}) catch "No rules match this filter.";
        try common.labelWrapped(canvas, .{ .x = x, .y = grid_y + 16, .w = w, .h = 40 }, style(common.text_11, th.dim, .regular), empty_text);
    }
}

fn matches(filter: state_mod.AdvisorFilter, severity: []const u8) bool {
    return switch (filter) {
        .all => true,
        .warning => std.mem.eql(u8, severity, "WARNING"),
        .info => std.mem.eql(u8, severity, "INFO"),
        .clear => std.mem.eql(u8, severity, "CLEAR"),
        .skip => std.mem.eql(u8, severity, "SKIP"),
    };
}

fn drawFilters(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32, w: f32) !void {
    var buf: [32]u8 = undefined;
    const labels = [_][]const u8{
        std.fmt.bufPrint(&buf, "All {d}", .{model.advisor.len}) catch "All",
        "Warning",
        "Info",
        "Clear",
        "Skip",
    };
    const filters = [_]state_mod.AdvisorFilter{ .all, .warning, .info, .clear, .skip };
    var widths: [5]f32 = undefined;
    var total: f32 = 0;
    for (labels, 0..) |text_value, i| {
        widths[i] = 18 + measure(canvas, text_value, style(common.text_105, th.muted, .regular));
        total += widths[i];
    }
    total += 4 * 4;
    var cx = x + w - total;
    for (labels, 0..) |text_value, i| {
        const on = state.advisor_filter == filters[i];
        try canvas.rounded(.{ .x = cx, .y = y + 24.5, .w = widths[i], .h = 26 }, 3, if (on) th.tint_live else .{ .r = 0, .g = 0, .b = 0, .a = 0 }, if (on) th.control_pressed_border else th.line, 1);
        try label(canvas, cx + 9, y + 30.75, text_value, style(common.text_105, if (on) th.live else th.muted, .regular));
        _ = canvas.choice(400 + @as(u32, @intCast(i)), .{ .x = cx, .y = y + 24.5, .w = widths[i], .h = 26 }, text_value, on);
        cx += widths[i] + 4;
    }
}

fn drawCard(canvas: *Canvas, th: Theme, card: model_mod.AdvisorCard, rect: Rect, card_index: usize) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    const left = rect.x + 13;
    const content_w = rect.w - 32;
    const top = rect.y + 13;
    var badge_w: f32 = 0;
    {
        const color = common.severityColor(th, card.severity);
        var st = style(common.text_95, color, .regular);
        st.tracking = 0.85;
        badge_w = 18 + 8 + measure(canvas, card.severity, st);
        try canvas.rounded(.{ .x = left, .y = top, .w = badge_w, .h = 18 }, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, color, 1);
        if (std.mem.eql(u8, card.severity, "SKIP")) {
            try canvas.stroke(.{ .x = left + 5, .y = top + 6, .w = 6, .h = 6 }, 3, color, 0.8);
        } else if (std.mem.eql(u8, card.severity, "WARNING")) {
            try canvas.circle(left + 8, top + 9, 2.8, color);
            try canvas.fill(.{ .x = left + 8, .y = top + 6, .w = 3, .h = 6 }, th.panel);
        } else {
            try canvas.circle(left + 8, top + 9, 2.4, color);
        }
        try label(canvas, left + 17, top + 2.2, card.severity, st);
    }
    try label(canvas, left + badge_w + 8, top + 1.3, card.id, style(common.text_12, th.text, .bold));
    var conf_buf: [32]u8 = undefined;
    const conf_text = if (card.confidence) |c| std.fmt.bufPrint(&conf_buf, "{d:.0}% conf", .{c * 100}) catch "" else "uncollected";
    try labelRight(canvas, rect.x + rect.w - 16, top + 2, conf_text, style(common.text_10, th.dim, .regular));

    if (card.confidence) |c| {
        try canvas.fill(.{ .x = left, .y = top + 27.25, .w = content_w, .h = 2 }, th.line);
        try canvas.fill(.{ .x = left, .y = top + 27.25, .w = content_w * @as(f32, @floatCast(c)), .h = 2 }, th.live);
    }

    var summary_style = style(common.text_12, th.muted, .regular);
    summary_style.line_height = 1.6;
    summary_style.wrap = true;
    var summary_layout: xsui.TextLayout = .{};
    try canvas.layoutText(summary_style, card.summary, content_w, &summary_layout);
    _ = try canvas.textIn(.{ .x = left, .y = top + 38.25, .w = content_w, .h = summary_layout.height() + 2 }, summary_style, card.summary);

    const evidence_y = top + 38.25 + summary_layout.height() + 9.75;
    var ex = left;
    for (card.evidence) |e| {
        const ew = 10 + measure(canvas, e, style(common.text_10, th.text, .regular));
        if (ex + ew > rect.x + rect.w - 16) break;
        try canvas.rounded(.{ .x = ex, .y = evidence_y, .w = ew, .h = 19 }, 3, th.field, th.line, 1);
        try label(canvas, ex + 5, evidence_y + 2.8, e, style(common.text_10, th.text, .regular));
        ex += ew + 4;
    }

    var rec_style = style(common.text_11, th.dim, .regular);
    rec_style.line_height = 1.55;
    rec_style.wrap = true;
    var rec_buf: [512]u8 = undefined;
    const rec_text = if (std.mem.startsWith(u8, card.recommendation, "Suggestion only"))
        card.recommendation
    else
        std.fmt.bufPrint(&rec_buf, "Suggestion only — never applied. {s}", .{card.recommendation}) catch card.recommendation;
    var rec_layout: xsui.TextLayout = .{};
    try canvas.layoutText(rec_style, rec_text, content_w, &rec_layout);
    const rec_y = evidence_y + 19 + 9;
    try canvas.fill(.{ .x = left, .y = rec_y, .w = content_w, .h = 1 }, th.line);
    _ = try canvas.textIn(.{ .x = left, .y = rec_y + 9, .w = content_w, .h = rec_layout.height() + 2 }, rec_style, rec_text);
    if (card.focus != null) {
        const button_y = rec_y + 9 + rec_layout.height() + 9;
        const button = Rect{ .x = left, .y = button_y, .w = 121, .h = 30 };
        try canvas.rounded(button, 4, th.raised, th.line_strong, 1);
        try label(canvas, left + 10, button_y + 6.5, "Show evidence →", style(common.text_11, th.text, .regular));
        var evidence_buf: [128]u8 = undefined;
        const evidence_label = std.fmt.bufPrint(&evidence_buf, "Show evidence for {s}", .{card.id}) catch "Show evidence";
        _ = canvas.button(900 + @as(u32, @intCast(card_index)), button, evidence_label);
    }
}
