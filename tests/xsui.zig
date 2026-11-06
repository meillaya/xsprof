//! Public API and ABI checks for the standalone xsui package. This file only
//! imports the package root, so any missing export breaks the xsprof build.

const std = @import("std");
const xsui = @import("xsui");

test "package identity and draw ABI" {
    try std.testing.expect(xsui.version.len != 0);
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(xsui.Instance));
    try std.testing.expectEqual(@as(usize, 18), @sizeOf(xsui.Instance) / @sizeOf(f32));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(xsui.Instance, "clip"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(xsui.Instance, "uv"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(xsui.Instance, "color"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(xsui.Instance, "mode"));
}

test "theme presets and overrides are part of the public API" {
    try std.testing.expectEqualDeep(xsui.themes.dark, xsui.themes.named("dark").?);
    try std.testing.expectEqualDeep(xsui.themes.light, xsui.themes.named("light").?);
    try std.testing.expectEqualDeep(xsui.themes.high_contrast, xsui.themes.named("high-contrast").?);
    try std.testing.expect(xsui.themes.named("unknown") == null);
    const custom = xsui.themes.derive(xsui.themes.dark, .{
        .bg = .{ .r = 0x11, .g = 0x22, .b = 0x33 },
    });
    try std.testing.expectEqual(@as(u8, 0x11), custom.bg.r);
    try std.testing.expectEqualDeep(xsui.themes.dark.panel, custom.panel);
}

const PaintProbe = struct {
    painted: bool = false,
};

fn probePaint(user: ?*anyopaque, frame: *xsui.Frame, rect: xsui.Rect, clip: [4]f32) anyerror!void {
    const state: *PaintProbe = @ptrCast(@alignCast(user.?));
    state.painted = true;
    try frame.list.rect(rect.x, rect.y, rect.w, rect.h, frame.theme.vm, clip);
}

fn publicView(user: ?*anyopaque, ui: *xsui.Ui) anyerror!void {
    var root = try ui.column(.{ .padding = xsui.Edges.all(8), .bg = ui.theme.panel });
    var chip = try xsui.widgets.chip(ui, "LIVE", ui.theme.live);
    chip.end();
    try xsui.controls.button(ui, 7, "Run", .{ .active = true, .tone = .primary });
    try ui.custom(.{
        .style = .{ .height = 20, .flex = 1 },
        .user = user,
        .paint = probePaint,
    });
    root.end();
}

test "widgets, controls, custom painters, and Tester are callable publicly" {
    var probe_state = PaintProbe{};
    var tester = xsui.Tester.init(std.testing.allocator, 320, 180, xsui.themes.dark);
    tester.click(12, 12);
    const pixels = try tester.renderPixels(&probe_state, publicView);
    defer std.testing.allocator.free(pixels);
    try std.testing.expect(probe_state.painted);
    try std.testing.expectEqual(@as(usize, 320 * 180 * 4), pixels.len);
}

test "frame renders through the public raster path" {
    var frame: xsui.Frame = undefined;
    try frame.init(std.testing.allocator, 64, 48, xsui.themes.high_contrast);
    defer frame.deinit();
    var ui = xsui.Ui.init(&frame);
    defer ui.deinit();
    var root = try ui.column(.{ .bg = ui.theme.bg });
    try ui.text(.{ .text = "xsui", .size = 14, .color = ui.theme.text, .weight = .bold });
    root.end();
    try ui.finish();
    const pixels = try frame.render();
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), pixels.len);
    var non_background: usize = 0;
    for (pixels) |byte| {
        if (byte != 0) non_background += 1;
    }
    try std.testing.expect(non_background > 0);
}

test {
    // Keep the module referenced so a missing package root fails this build.
    _ = xsui;
}
