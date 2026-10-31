//! Keyboard focus traversal, activation, and dialog trapping. Kept separate
//! from App so the state machine stays under the line limit.

const std = @import("std");
const xsui = @import("xsui");
const app_mod = @import("app.zig");
const commands = @import("commands.zig");
const mod = @import("state.zig");

const App = app_mod.App;

fn inDialog(id: u32, dialog: mod.Dialog, query: []const u8) bool {
    return switch (dialog) {
        .none => true,
        .palette => id == 742 or id == 743 or (id >= 700 and id < 700 + commands.count(query)),
        .appearance => id == 740 or (id >= 720 and id < 726),
        .help => id == 741,
    };
}

fn validHit(id: u32, app: *const App) bool {
    return inDialog(id, app.state.dialog, app.state.paletteQuery());
}

pub fn step(app: *App, canvas: *xsui.Canvas, backwards: bool) void {
    if (canvas.hits.items.len == 0) return;
    var current_index: ?usize = null;
    if (app.state.focus_id) |id| {
        for (canvas.hits.items, 0..) |hit, i| {
            if (hit.id == id and validHit(id, app)) current_index = i;
        }
    }
    var index = current_index orelse 0;
    var guard: usize = 0;
    while (guard <= canvas.hits.items.len) : (guard += 1) {
        if (backwards) {
            index = if (index == 0) canvas.hits.items.len - 1 else index - 1;
        } else if (current_index == null and guard == 0) {
            index = 0;
        } else {
            index = (index + 1) % canvas.hits.items.len;
        }
        const id = canvas.hits.items[index].id;
        if (validHit(id, app)) {
            app.state.focus_id = id;
            app.state.focus_visible = true;
            return;
        }
        if (current_index == null and guard == 0) {
            // Start at the first valid target, including index zero.
            if (validHit(canvas.hits.items[0].id, app)) {
                app.state.focus_id = canvas.hits.items[0].id;
                app.state.focus_visible = true;
                return;
            }
        }
    }
}

pub fn activate(app: *App, canvas: *xsui.Canvas) void {
    const id = app.state.focus_id orelse return;
    const rect = canvas.hitRect(id) orelse return;
    app.click(canvas, rect.x + rect.w * 0.5, rect.y + rect.h * 0.5);
}

/// Returns true when the key was consumed by focus handling.
pub fn key(app: *App, canvas: *xsui.Canvas, codepoint: u21, shift: bool) bool {
    if (codepoint == 0x09) {
        step(app, canvas, shift);
        return true;
    }
    const text_focus = app.state.focus_id != null and (app.state.focus_id.? == 742 or app.state.focus_id.? == 520);
    if (!text_focus and (codepoint == '\n' or codepoint == '\r' or codepoint == ' ') and app.state.focus_visible and app.state.focus_id != null) {
        activate(app, canvas);
        return true;
    }
    if (app.state.dialog == .none and app.state.focus_visible and app.state.focus_id != null) {
        const id = app.state.focus_id.?;
        if (id >= 100 and id < 105 and (codepoint == 0x11 or codepoint == 0x12 or codepoint == 0x13 or codepoint == 0x14)) {
            const screens = [_]mod.Screen{ .overview, .timeline, .advisor, .events, .capture };
            const delta: i32 = if (codepoint == 0x11) -1 else 1;
            const current: i32 = @intCast(id - 100);
            const next: usize = @intCast(@mod(current + delta, 5));
            app.state.screen = screens[next];
            app.state.scroll_y = 0;
            app.state.focus_id = 100 + @as(u32, @intCast(next));
            return true;
        }
    }
    return false;
}

test "focus traversal cycles valid hits and activates" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    const view_mod = @import("view.zig");
    try view_mod.view(&app.model, &app.state, &canvas);
    _ = key(&app, &canvas, 0x09, false);
    try std.testing.expect(app.state.focus_id != null);
    const first = app.state.focus_id.?;
    _ = key(&app, &canvas, 0x09, false);
    try std.testing.expect(app.state.focus_id != null);
    try std.testing.expect(app.state.focus_id.? != first or canvas.hits.items.len == 1);
}

test "palette focus returns to its trigger" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.handleKey('k', .{ .meta = true });
    try std.testing.expectEqual(mod.Dialog.palette, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, 742), app.state.focus_id);
    app.handleKey(0x1b, .{});
    try std.testing.expectEqual(mod.Dialog.none, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, 200), app.state.focus_id);
}

test "dialog focus traps and returns to the trigger" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    app.handleKey('w', .{});
    try std.testing.expectEqual(mod.Dialog.appearance, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, 201), app.state.focus_return);
    try std.testing.expectEqual(@as(?u32, 720), app.state.focus_id);
    app.handleKey(0x1b, .{});
    try std.testing.expectEqual(mod.Dialog.none, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, 201), app.state.focus_id);
}

test "rail focus arrows change screens" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.state.focus_id = 100;
    app.state.focus_visible = true;
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 320, 200, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    _ = key(&app, &canvas, 0x12, false);
    try std.testing.expectEqual(mod.Screen.timeline, app.state.screen);
    try std.testing.expectEqual(@as(?u32, 101), app.state.focus_id);
}
