//! Shared text, state-badge, and panel helpers for the console screens.

const std = @import("std");
const xsui = @import("xsui");

pub const Canvas = xsui.Canvas;
pub const Rect = xsui.Rect;
pub const Color = xsui.Color;
pub const Theme = xsui.Theme;
pub const TextStyle = xsui.TextStyle;
pub const FontWeight = xsui.FontWeight;

pub const text_10 = TextStyle{ .size = 10, .line_height = 1.5 };
pub const text_85 = TextStyle{ .size = 8.5, .line_height = 1.5 };
pub const text_95 = TextStyle{ .size = 9.5, .line_height = 1.5 };
pub const text_105 = TextStyle{ .size = 10.5, .line_height = 1.5 };
pub const text_11 = TextStyle{ .size = 11, .line_height = 1.5 };
pub const text_12 = TextStyle{ .size = 12, .line_height = 1.5 };
pub const text_13 = TextStyle{ .size = 13, .line_height = 1.5 };

pub fn style(base: TextStyle, color: Color, weight: FontWeight) TextStyle {
    var out = base;
    out.color = color;
    out.weight = weight;
    return out;
}

pub fn measure(canvas: *Canvas, text_value: []const u8, base: TextStyle) f32 {
    var layout: xsui.TextLayout = .{};
    canvas.layoutText(base, text_value, 0, &layout) catch return 0;
    return layout.width;
}

pub fn label(canvas: *Canvas, x: f32, y: f32, text_value: []const u8, base: TextStyle) !void {
    var layout: xsui.TextLayout = .{};
    canvas.layoutText(base, text_value, 0, &layout) catch {};
    const h = if (layout.count == 0) base.size * base.line_height else layout.height();
    _ = try canvas.textIn(.{ .x = x, .y = y, .w = 4096, .h = h }, base, text_value);
}

pub fn labelRight(canvas: *Canvas, right: f32, y: f32, text_value: []const u8, base: TextStyle) !void {
    const w = measure(canvas, text_value, base);
    try label(canvas, right - w, y, text_value, base);
}

pub fn labelWrapped(canvas: *Canvas, rect: Rect, base: TextStyle, text_value: []const u8) !void {
    var st = base;
    st.wrap = true;
    _ = try canvas.textIn(rect, st, text_value);
}

pub fn borderLine(canvas: *Canvas, x: f32, y: f32, w: f32, color: Color) !void {
    try canvas.fill(.{ .x = x, .y = y, .w = w, .h = 1 }, color);
}

pub fn panelBase(canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
}

pub fn panelHead(canvas: *Canvas, th: Theme, rect: Rect, index: []const u8, title: []const u8, meta: []const u8) !void {
    try borderLine(canvas, rect.x + 1, rect.y + 36, rect.w - 2, th.line);
    try label(canvas, rect.x + 15, rect.y + 10.6, index, style(text_95, th.faint, .regular));
    var title_style = style(text_105, th.muted, .bold);
    title_style.tracking = 1.05;
    try label(canvas, rect.x + 35, rect.y + 10.6, title, title_style);
    if (meta.len != 0) try labelRight(canvas, rect.x + rect.w - 14, rect.y + 10.6, meta, style(text_105, th.dim, .regular));
}

pub fn severityColor(th: Theme, severity: []const u8) Color {
    if (std.mem.eql(u8, severity, "WARNING")) return th.skip;
    if (std.mem.eql(u8, severity, "INFO")) return th.live;
    if (std.mem.eql(u8, severity, "CLEAR")) return th.pass;
    return th.faint;
}

pub fn stateBadge(canvas: *Canvas, th: Theme, rect: Rect, state: []const u8, glyph: []const u8, label_text: []const u8) !void {
    const color = if (std.mem.eql(u8, state, "READY") or std.mem.eql(u8, state, "CLEAR"))
        th.pass
    else if (std.mem.eql(u8, state, "DEGRADED") or std.mem.eql(u8, state, "SKIP") or std.mem.eql(u8, state, "WARNING"))
        th.skip
    else
        th.refuse;
    var st = style(text_95, color, .regular);
    st.tracking = 0.855;
    const default_glyph: []const u8 = if (std.mem.eql(u8, state, "READY") or std.mem.eql(u8, state, "CLEAR"))
        "●"
    else if (std.mem.eql(u8, state, "REFUSE"))
        "■"
    else
        "◐";
    const mark = if (glyph.len > 0) glyph else default_glyph;
    const mark_w = measure(canvas, mark, st);
    const label_w = measure(canvas, label_text, st);
    const box_w = 2 + 10 + mark_w + 4 + label_w;
    const box = Rect{ .x = rect.x + rect.w - box_w, .y = rect.y, .w = box_w, .h = 18.25 };
    try canvas.rounded(box, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, color, 1);
    _ = try canvas.textIn(.{ .x = box.x + 6, .y = box.y + 2.0, .w = box.w - 10, .h = 15 }, st, mark);
    _ = try canvas.textIn(.{ .x = box.x + 6 + mark_w + 4, .y = box.y + 2.0, .w = box.w - 12 - mark_w, .h = 15 }, st, label_text);
}
