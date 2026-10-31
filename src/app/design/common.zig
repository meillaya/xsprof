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
    try label(canvas, rect.x + 15, rect.y + 9, index, style(text_95, th.faint, .regular));
    var title_style = style(text_105, th.muted, .bold);
    title_style.tracking = 1.05;
    try label(canvas, rect.x + 35, rect.y + 9, title, title_style);
    if (meta.len != 0) try labelRight(canvas, rect.x + rect.w - 14, rect.y + 9, meta, style(text_105, th.dim, .regular));
}

pub fn severityColor(th: Theme, severity: []const u8) Color {
    if (std.mem.eql(u8, severity, "WARNING")) return th.skip;
    if (std.mem.eql(u8, severity, "INFO")) return th.live;
    if (std.mem.eql(u8, severity, "CLEAR")) return th.pass;
    return th.faint;
}

pub fn stateBadge(canvas: *Canvas, th: Theme, rect: Rect, state: []const u8, label_text: []const u8) !void {
    const color = if (std.mem.eql(u8, state, "READY") or std.mem.eql(u8, state, "CLEAR"))
        th.pass
    else if (std.mem.eql(u8, state, "DEGRADED") or std.mem.eql(u8, state, "SKIP") or std.mem.eql(u8, state, "WARNING"))
        th.skip
    else
        th.refuse;
    var st = style(text_95, color, .regular);
    st.tracking = 0.85;
    const w = 2 * 5 + 8 + measure(canvas, label_text, st) + 2;
    const box = Rect{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = 18 };
    try canvas.rounded(box, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, color, 1);
    const cy = box.y + 9;
    if (std.mem.eql(u8, state, "READY") or std.mem.eql(u8, state, "CLEAR")) {
        try canvas.circle(box.x + 7, cy, 2.4, color);
    } else if (std.mem.eql(u8, state, "REFUSE")) {
        try canvas.fill(.{ .x = box.x + 5, .y = cy - 2.5, .w = 5, .h = 5 }, color);
    } else if (std.mem.eql(u8, state, "SKIP")) {
        try canvas.stroke(.{ .x = box.x + 4.5, .y = cy - 3, .w = 6, .h = 6 }, 3, color, 0.8);
    } else {
        try canvas.circle(box.x + 7, cy, 2.8, color);
        try canvas.fill(.{ .x = box.x + 7, .y = cy - 3, .w = 3, .h = 6 }, th.panel);
    }
    try label(canvas, box.x + 13, box.y + 2.2, label_text, st);
}
