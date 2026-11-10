//! Keyboard focus traversal, activation, and dialog trapping. Kept separate
//! from App so the state machine stays under the line limit.

const std = @import("std");
const xsui = @import("xsui");
const app_mod = @import("app.zig");
const commands = @import("commands.zig");
const route = @import("route.zig");
const hits = @import("hits.zig");
const mod = @import("state.zig");

const App = app_mod.App;

fn inRange(id: u32, base: u32, span: u32) bool {
    return id >= base and id < base + span;
}

fn inDialog(id: u32, app: *const App) bool {
    const state = &app.state;
    return switch (state.dialog) {
        .none => true,
        .palette => id == hits.palette_input or id == hits.palette_esc or
            (id >= hits.palette_row_base and id < hits.palette_row_base + @as(u32, @intCast(commands.count(state.paletteQuery())))),
        .appearance => id == hits.dialog_close or inRange(id, hits.theme_option_base, 6),
        .help => id == hits.help_close,
        .picker => inRange(id, hits.picker_row_base, @as(u32, @intCast(state.picker.len))) or
            (id >= hits.picker_up and id <= hits.picker_filter),
        .confirm => id == hits.confirm_yes or id == hits.confirm_no,
        .onboarding => inRange(id, hits.onboarding_next, 4),
    };
}

fn validHit(id: u32, app: *const App) bool {
    return inDialog(id, app);
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
        const hit = canvas.hits.items[index];
        // Structural/semantic nodes (route group, headings, status) are in the
        // hit list for AX and pointer clipping but must never take keyboard
        // focus; the tree's focusOrder uses the same predicate.
        if (!hit.flags.focusable or hit.flags.disabled) continue;
        if (validHit(hit.id, app)) {
            app.state.focus_id = hit.id;
            app.state.focus_visible = true;
            return;
        }
        if (current_index == null and guard == 0) {
            const first = canvas.hits.items[0];
            if (first.flags.focusable and !first.flags.disabled and validHit(first.id, app)) {
                app.state.focus_id = first.id;
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
    if (app.state.text_focus != null) return false;
    if ((codepoint == '\n' or codepoint == '\r' or codepoint == ' ') and app.state.focus_visible and app.state.focus_id != null) {
        activate(app, canvas);
        return true;
    }
    if (app.state.dialog == .none and app.state.focus_visible and app.state.focus_id != null) {
        const id = app.state.focus_id.?;
        if (route.fromRailId(id)) |current_route| {
            if (codepoint == 0x11 or codepoint == 0x12 or codepoint == 0x13 or codepoint == 0x14) {
                const current = route.indexInOrder(current_route);
                const delta: i32 = if (codepoint == 0x11 or codepoint == 0x13) -1 else 1;
                const count: i32 = @intCast(route.order.len);
                const next: usize = @intCast(@mod(@as(i32, @intCast(current)) + delta, count));
                app.state.screen = route.order[next];
                app.state.scroll_y = 0;
                app.state.focus_id = route.order[next].railId();
                return true;
            }
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
    try std.testing.expectEqual(@as(?u32, hits.palette_input), app.state.focus_id);
    app.handleKey(0x1b, .{});
    try std.testing.expectEqual(mod.Dialog.none, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, hits.topbar_palette), app.state.focus_id);
}

test "dialog focus traps and returns to the trigger" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    app.handleKey('w', .{});
    try std.testing.expectEqual(mod.Dialog.appearance, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, hits.topbar_theme), app.state.focus_return);
    app.handleKey(0x1b, .{});
    try std.testing.expectEqual(mod.Dialog.none, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, hits.topbar_theme), app.state.focus_id);
}

test "rail focus arrows change screens in display order" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.state.focus_id = hits.railId(0);
    app.state.focus_visible = true;
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 320, 200, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    _ = key(&app, &canvas, 0x12, false);
    // order: home, overview, timeline, ... -> from overview arrows to timeline.
    try std.testing.expectEqual(@as(?u32, hits.railId(1)), app.state.focus_id);
    _ = key(&app, &canvas, 0x12, false);
    try std.testing.expectEqual(@as(?u32, hits.railId(2)), app.state.focus_id);
}

test "focus traversal skips non-focusable semantic nodes" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1280, 720, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    const view_mod = @import("view.zig");
    try view_mod.view(&app.model, &app.state, &canvas);
    // The route group (id 1) is semantic-only and must never take focus.
    try std.testing.expect(canvas.hitIndex(1) != null);
    try std.testing.expect(!canvas.hits.items[canvas.hitIndex(1).?].flags.focusable);
    step(&app, &canvas, false);
    try std.testing.expect(app.state.focus_id != null);
    try std.testing.expect(app.state.focus_id.? != 1);
    const index = canvas.hitIndex(app.state.focus_id.?) orelse return error.TestUnexpectedResult;
    try std.testing.expect(canvas.hits.items[index].flags.focusable);
    try std.testing.expect(!canvas.hits.items[index].flags.disabled);
}
