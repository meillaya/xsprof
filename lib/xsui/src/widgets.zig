//! Small widget vocabulary on top of the layout builder. Static-first; input
//! and focus arrive with the profiler app in P3.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");

pub const Panel = struct {
    outer: layout.Container,
    body: layout.Container,

    pub fn end(self: Panel) void {
        self.body.end();
        self.outer.end();
    }
};

pub fn chip(ui: *layout.Ui, text_value: []const u8, color: draw.Color) !layout.Container {
    const box = try ui.row(.{
        .height = 20,
        .padding = .{ .left = 8, .right = 8 },
        .align_items = .center,
        .bg = ui.theme.raised,
        .border = color,
        .border_width = 1,
        .radius = 4,
    });
    try ui.text(.{ .text = text_value, .size = 10, .color = color, .weight = .bold });
    return box;
}

pub fn statCard(
    ui: *layout.Ui,
    label: []const u8,
    value: []const u8,
    color: draw.Color,
) !layout.Container {
    const card = try ui.column(.{
        .height = 58,
        .padding = .{ .left = 8, .top = 7, .right = 8, .bottom = 7 },
        .gap = 3,
        .bg = ui.theme.raised,
        .border = ui.theme.hairline,
        .border_width = 1,
        .radius = 4,
        .flex = 1,
    });
    try ui.text(.{ .text = label, .size = 9, .color = ui.theme.muted });
    try ui.text(.{ .text = value, .size = 16, .color = color, .weight = .bold });
    return card;
}

pub fn panel(ui: *layout.Ui, title: []const u8, style: layout.Style) !Panel {
    const outer = try ui.column(.{
        .bg = ui.theme.panel,
        .border = ui.theme.hairline,
        .border_width = 1,
        .radius = 4,
        .clip = true,
        .direction = .column,
        .flex = style.flex,
        .height = style.height,
        .width = style.width,
    });
    const header = try ui.row(.{
        .height = 26,
        .padding = .{ .left = 10, .right = 10 },
        .align_items = .center,
        .bg = ui.theme.panel,
    });
    try ui.text(.{ .text = title, .size = 10, .color = ui.theme.muted, .weight = .bold });
    header.end();
    const body = try ui.column(.{
        .flex = 1,
        .padding = layout.Edges.all(10),
        .gap = 6,
    });
    return .{ .outer = outer, .body = body };
}

pub fn rule(ui: *layout.Ui) !void {
    const line = try ui.column(.{ .height = 1, .bg = ui.theme.hairline });
    line.end();
}

pub fn keyHint(ui: *layout.Ui, key: []const u8, label: []const u8) !void {
    try ui.text(.{ .text = key, .size = 9, .color = ui.theme.live, .weight = .bold });
    try ui.text(.{ .text = label, .size = 9, .color = ui.theme.muted });
}
