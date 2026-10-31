//! Interactive controls on top of the immediate layout builder. Controls do
//! not know profiler actions; callers assign a stable hit id and map it after
//! `Ui.finish`.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");

pub const Tone = enum { normal, primary, danger, quiet };

pub const ButtonOptions = struct {
    active: bool = false,
    enabled: bool = true,
    width: ?f32 = null,
    tone: Tone = .normal,
};

fn toneColor(th: draw.Theme, tone: Tone) draw.Color {
    return switch (tone) {
        .normal => th.text,
        .primary => th.live,
        .danger => th.refuse,
        .quiet => th.muted,
    };
}

pub fn button(
    ui: *layout.Ui,
    hit_id: u32,
    label: []const u8,
    options: ButtonOptions,
) !void {
    const th = ui.theme;
    const row = try ui.row(.{
        .height = 26,
        .width = options.width,
        .padding = .{ .left = 10, .right = 10 },
        .align_items = .center,
        .bg = if (options.active) th.raised else th.panel,
        .border = if (options.active) toneColor(th, options.tone) else th.hairline,
        .border_width = 1,
        .radius = 4,
        .hit_id = if (options.enabled) hit_id else 0,
    });
    try ui.text(.{
        .text = label,
        .size = 10,
        .color = if (options.enabled) toneColor(th, options.tone) else th.muted,
        .weight = if (options.active) .bold else .regular,
    });
    row.end();
}

pub fn toggle(
    ui: *layout.Ui,
    hit_id: u32,
    label: []const u8,
    on: bool,
    enabled: bool,
) !void {
    const th = ui.theme;
    const row = try ui.row(.{
        .height = 24,
        .padding = .{ .left = 8, .right = 8 },
        .gap = 8,
        .align_items = .center,
        .hit_id = if (enabled) hit_id else 0,
    });
    try ui.text(.{
        .text = if (on) "[x]" else "[ ]",
        .size = 10,
        .color = if (!enabled) th.muted else if (on) th.pass else th.hairline,
        .weight = .bold,
    });
    try ui.text(.{ .text = label, .size = 10, .color = if (enabled) th.text else th.muted });
    row.end();
}

pub fn listRow(
    ui: *layout.Ui,
    hit_id: u32,
    label: []const u8,
    selected: bool,
) !void {
    const th = ui.theme;
    const row = try ui.row(.{
        .height = 24,
        .padding = .{ .left = 8, .right = 8 },
        .align_items = .center,
        .bg = if (selected) th.raised else null,
        .border = if (selected) th.hairline else null,
        .border_width = if (selected) 1 else 0,
        .radius = 3,
        .hit_id = hit_id,
    });
    try ui.text(.{
        .text = label,
        .size = 10,
        .color = if (selected) th.text else th.muted,
        .weight = if (selected) .bold else .regular,
    });
    row.end();
}

pub fn textField(
    ui: *layout.Ui,
    hit_id: u32,
    value: []const u8,
    focused: bool,
    placeholder: []const u8,
) !void {
    const th = ui.theme;
    const row = try ui.row(.{
        .height = 26,
        .padding = .{ .left = 8, .right = 8 },
        .align_items = .center,
        .bg = th.raised,
        .border = if (focused) th.live else th.hairline,
        .border_width = 1,
        .radius = 3,
        .hit_id = hit_id,
    });
    if (value.len == 0 and !focused) {
        try ui.text(.{ .text = placeholder, .size = 10, .color = th.muted });
    } else {
        const shown = if (focused)
            try std.fmt.allocPrint(ui.allocator, "{s}_", .{value})
        else
            value;
        try ui.text(.{ .text = shown, .size = 10, .color = th.text });
    }
    row.end();
}

pub fn toast(ui: *layout.Ui, text_value: []const u8, color: draw.Color) !void {
    const row = try ui.row(.{
        .height = 24,
        .padding = .{ .left = 10, .right = 10 },
        .align_items = .center,
        .bg = ui.theme.raised,
        .border = color,
        .border_width = 1,
        .radius = 4,
    });
    try ui.text(.{ .text = text_value, .size = 9, .color = color });
    row.end();
}

pub fn focusColor(th: draw.Theme, focused: bool) draw.Color {
    return if (focused) th.live else th.hairline;
}

test "controls register stable hit ids" {
    const frame_mod = @import("frame.zig");
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 260, 160, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    const root = try ui.column(.{ .padding = layout.Edges.all(10), .gap = 6 });
    try button(&ui, 11, "Run", .{ .active = true, .tone = .primary });
    try toggle(&ui, 12, "Follow", true, true);
    try listRow(&ui, 13, "scheduler-mix", true);
    try textField(&ui, 14, "session.ndjson", false, "path");
    root.end();
    try ui.finish();
    try std.testing.expectEqual(@as(?u32, 11), ui.hitAt(20, 20));
    try std.testing.expect(ui.hitAt(250, 150) == null);
}
